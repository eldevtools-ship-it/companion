import Foundation
import AppKit

// MARK: - Vercel
// Latest deployments every 30 s. Each token covers its account and every team it can
// see (work and personal); a second token adds another Vercel account. A deployment
// that finishes (ready or failed) lights the pill and peeks the island out.

struct VercelDeployment: Identifiable, Equatable {
    let id: String
    let projectName: String
    let url: String
    let state: String        // BUILDING, QUEUED, INITIALIZING, READY, ERROR, CANCELED
    let createdAt: Date
    let commitMessage: String?
    let branch: String?
    /// Team or account it belongs to, when you follow more than one.
    var account: String? = nil

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
    static let secondTokenKey = "vercel-token-2"

    /// Where to look: the account itself (teamId nil) or one of its teams.
    private struct Scope { let teamId: String?; let name: String }

    private var loop: Task<Void, Never>?
    private var announced: Set<String> = []
    private var primed = false
    private var scopes: [String: [Scope]] = [:]          // token → scopes
    private var scopesFetched: [String: Date] = [:]

    private init() {}

    private var tokens: [String] {
        [Self.tokenKey, Self.secondTokenKey].compactMap { KeychainStore.shared.get($0) }
    }

    var isConfigured: Bool { !tokens.isEmpty }

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
        scopes = [:]
        scopesFetched = [:]
        AppState.shared.vercelDeployments = []
        AppState.shared.vercelError = nil
        start()
    }

    private func refresh() async {
        let state = AppState.shared
        let tokens = self.tokens
        guard !tokens.isEmpty else { return }

        var found: [VercelDeployment] = []
        var failures: [String] = []
        var anyOK = false
        var scopeCount = 0
        for token in tokens {
            let list = await scopes(for: token)
            scopeCount += list.count
            for scope in list {
                switch await deployments(token: token, scope: scope) {
                case .success(let ds):
                    anyOK = true
                    // Team results first, so a deployment seen twice keeps its team's name
                    if scope.teamId == nil { found += ds } else { found.insert(contentsOf: ds, at: 0) }
                case .failure(let msg): failures.append(msg)
                }
            }
        }
        guard anyOK else {
            state.vercelError = failures.first ?? "erreur"
            return
        }
        // Newest first, each deployment once, with its team when there are several
        var seen = Set<String>()
        let merged = found.filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(6)
            .map { d -> VercelDeployment in
                var d = d
                if scopeCount < 2 { d.account = nil }
                return d
            }
        state.vercelDeployments = merged
        state.vercelError = nil
        announce(merged)
    }

    /// The token's own account plus every team it belongs to (refreshed every 10 min).
    private func scopes(for token: String) async -> [Scope] {
        if let cached = scopes[token], let at = scopesFetched[token], Date().timeIntervalSince(at) < 600 {
            return cached
        }
        var list = [Scope(teamId: nil, name: "Perso")]
        if let url = URL(string: "https://api.vercel.com/v2/teams?limit=50") {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let result = try? await URLSession.shared.data(for: req)
            if let result, (result.1 as? HTTPURLResponse)?.statusCode == 200,
               let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] {
                for t in json["teams"] as? [[String: Any]] ?? [] {
                    guard let id = t["id"] as? String else { continue }
                    list.append(Scope(teamId: id, name: (t["name"] as? String) ?? (t["slug"] as? String) ?? "Équipe"))
                }
            }
        }
        scopes[token] = list
        scopesFetched[token] = Date()
        return list
    }

    private enum FetchResult { case success([VercelDeployment]), failure(String) }

    private func deployments(token: String, scope: Scope) async -> FetchResult {
        var comps = URLComponents(string: "https://api.vercel.com/v6/deployments")!
        comps.queryItems = [URLQueryItem(name: "limit", value: "6")]
            + (scope.teamId.map { [URLQueryItem(name: "teamId", value: $0)] } ?? [])
        guard let url = comps.url else { return .failure("URL invalide") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                return .failure(code == 401 || code == 403 ? "jeton invalide" : "erreur \(code)")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let list = (json?["deployments"] as? [[String: Any]] ?? []).compactMap(parse).map { d -> VercelDeployment in
                var d = d
                d.account = scope.name
                return d
            }
            return .success(list)
        } catch {
            return .failure(error.localizedDescription)
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
        if !state.focusMode {
            SoundEngine.shared.play(done.isSuccess ? "finish" : "error")
            if state.mode == .hidden { NotificationCenter.default.post(name: .hookReveal, object: nil) }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
                  state.tasks[i].state == .finished || state.tasks[i].state == .error else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
        }
    }
}
