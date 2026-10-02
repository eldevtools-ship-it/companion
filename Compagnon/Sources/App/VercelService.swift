import Foundation
import AppKit

// MARK: - Vercel
// Latest deployments every 30 s with a personal token. A deployment that finishes
// (ready or failed) lights the pill and peeks the island out, without opening it.

struct VercelDeployment: Identifiable, Equatable {
    let id: String
    let projectName: String
    let url: String
    let state: String        // BUILDING, QUEUED, INITIALIZING, READY, ERROR, CANCELED
    let createdAt: Date
    let commitMessage: String?
    let branch: String?

    var isSuccess: Bool { state == "READY" }
    var isFinished: Bool { ["READY", "ERROR", "CANCELED"].contains(state) }
    var statusLabel: String {
        switch state {
        case "READY":    return "En ligne"
        case "ERROR":    return "Échec"
        case "CANCELED": return "Annulé"
        default:         return "En cours"
        }
    }
    var statusColor: String {
        switch state {
        case "READY":    return "#22C55E"
        case "ERROR":    return "#F4505E"
        case "CANCELED": return "#8E939C"
        default:         return "#3B9EFF"
        }
    }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "à l'instant" }
        if diff < 3600  { return "\(Int(diff/60)) min" }
        if diff < 86400 { return "\(Int(diff/3600)) h" }
        return "\(Int(diff/86400)) j"
    }
}

@MainActor
final class VercelService {
    static let shared = VercelService()
    static let pillId = "integration_vercel"
    static let tokenKey = "vercel-token"

    private var loop: Task<Void, Never>?
    private var announced: Set<String> = []
    private var primed = false

    private init() {}

    var isConfigured: Bool { KeychainStore.shared.get(Self.tokenKey) != nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func restart() {
        loop?.cancel()
        loop = nil
        primed = false
        announced = []
        AppState.shared.vercelDeployments = []
        AppState.shared.vercelError = nil
        start()
    }

    private func refresh() async {
        let state = AppState.shared
        guard let token = KeychainStore.shared.get(Self.tokenKey),
              let url = URL(string: "https://api.vercel.com/v6/deployments?limit=6") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                state.vercelError = code == 401 || code == 403 ? "jeton invalide" : "erreur \(code)"
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let list = (json?["deployments"] as? [[String: Any]] ?? []).compactMap(parse)
            state.vercelDeployments = list
            state.vercelError = nil
            announce(list)
        } catch {
            state.vercelError = error.localizedDescription
        }
    }

    private func parse(_ d: [String: Any]) -> VercelDeployment? {
        guard let uid = d["uid"] as? String, let name = d["name"] as? String else { return nil }
        let meta = d["meta"] as? [String: Any]
        return VercelDeployment(
            id: uid, projectName: name,
            url: (d["url"] as? String).map { "https://\($0)" } ?? "",
            state: (d["state"] as? String) ?? (d["readyState"] as? String) ?? "",
            createdAt: Date(timeIntervalSince1970: ((d["createdAt"] as? Double) ?? 0) / 1000),
            commitMessage: meta?["githubCommitMessage"] as? String ?? meta?["gitlabCommitMessage"] as? String,
            branch: meta?["githubCommitRef"] as? String ?? meta?["gitlabCommitRef"] as? String)
    }

    /// Pill shows what's happening; a finished deployment is announced once.
    private func announce(_ list: [VercelDeployment]) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        // First load: remember what's already done, announce nothing
        if !primed {
            announced = Set(list.filter(\.isFinished).map(\.id))
            primed = true
        }
        if let building = list.first(where: { !$0.isFinished }) {
            state.tasks[idx].state = .working
            state.tasks[idx].steps = ["\(building.projectName) · en cours"]
        } else if state.tasks[idx].state == .working {
            state.tasks[idx].state = .idle
            state.tasks[idx].steps = []
        }
        guard let done = list.first(where: { $0.isFinished && !announced.contains($0.id) }) else { return }
        announced.insert(done.id)
        state.tasks[idx].state = done.isSuccess ? .finished : .error
        state.tasks[idx].steps = ["\(done.projectName) · \(done.statusLabel)"]
        if state.focusId != Self.pillId || state.mode != .expanded {
            state.tasks[idx].pillBadge = done.isSuccess ? .finished : .error
        }
        SoundEngine.shared.play(done.isSuccess ? "finish" : "error")
        if state.mode == .hidden { NotificationCenter.default.post(name: .hookReveal, object: nil) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
                  state.tasks[i].state == .finished || state.tasks[i].state == .error else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
        }
    }
}
