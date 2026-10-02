import Foundation
import CoreGraphics

// MARK: - Harvest
// Running timer, start / stop, and a gentle reminder when you're working with no
// timer running. Personal access token + account ID from id.getharvest.com/developers.

struct HarvestEntry: Identifiable, Equatable {
    let id: Int
    let projectId: Int
    let projectName: String
    let clientName: String?
    let taskId: Int
    let taskName: String
    let notes: String?
    let hours: Double           // at fetch time
    let isRunning: Bool
    let spentDate: String       // YYYY-MM-DD
    let fetchedAt: Date

    /// Seconds tracked, counting live while the timer runs.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        hours * 3600 + (isRunning ? now.timeIntervalSince(fetchedAt) : 0)
    }

    var label: String { "\(projectName) · \(taskName)" }
}

/// A project + task pair you can start a timer on.
struct HarvestShortcut: Identifiable, Hashable {
    let projectId: Int
    let projectName: String
    let taskId: Int
    let taskName: String
    var id: String { "\(projectId)-\(taskId)" }
    var label: String { "\(projectName) · \(taskName)" }
}

@MainActor
final class HarvestService {
    static let shared = HarvestService()
    static let pillId = "integration_harvest"
    static let tokenKey = "harvest-token"
    static let accountKey = "harvest-account-id"

    private var loop: Task<Void, Never>?
    private var userId: Int?
    private var noTimerSince: Date?
    private var lastReminder: Date?

    private init() {}

    var isConfigured: Bool {
        KeychainStore.shared.get(Self.tokenKey) != nil && KeychainStore.shared.get(Self.accountKey) != nil
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func restart() {
        loop?.cancel()
        loop = nil
        userId = nil
        AppState.shared.harvestRunning = nil
        AppState.shared.harvestShortcuts = []
        AppState.shared.harvestError = nil
        start()
    }

    // MARK: API

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let token = KeychainStore.shared.get(Self.tokenKey),
              let account = KeychainStore.shared.get(Self.accountKey),
              let url = URL(string: "https://api.harvestapp.com/v2/\(path)") else {
            throw URLError(.userAuthenticationRequired)
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(account, forHTTPHeaderField: "Harvest-Account-Id")
        req.setValue("Compagnon (macOS)", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            switch code {
            case 401: throw HarvestError.message("jeton invalide")
            case 403: throw HarvestError.message("accès refusé")
            case 404: throw HarvestError.message("compte introuvable")
            case 429: throw HarvestError.message("trop de requêtes")
            default:  throw HarvestError.message("erreur \(code)")
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private enum HarvestError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private func parse(_ d: [String: Any], at now: Date) -> HarvestEntry? {
        guard let id = d["id"] as? Int,
              let project = d["project"] as? [String: Any], let projectId = project["id"] as? Int,
              let task = d["task"] as? [String: Any], let taskId = task["id"] as? Int else { return nil }
        return HarvestEntry(id: id, projectId: projectId,
                            projectName: project["name"] as? String ?? "Projet",
                            clientName: (d["client"] as? [String: Any])?["name"] as? String,
                            taskId: taskId, taskName: task["name"] as? String ?? "Tâche",
                            notes: d["notes"] as? String,
                            hours: (d["hours"] as? Double) ?? Double(d["hours"] as? Int ?? 0),
                            isRunning: d["is_running"] as? Bool ?? false,
                            spentDate: d["spent_date"] as? String ?? "",
                            fetchedAt: now)
    }

    // MARK: Refresh

    func refresh() async {
        let state = AppState.shared
        guard isConfigured else { state.harvestLoaded = false; return }
        do {
            if userId == nil {
                let me = try await request("users/me")
                userId = me["id"] as? Int
            }
            guard let userId else { return }
            let now = Date()
            let json = try await request("time_entries?user_id=\(userId)&per_page=50")
            let entries = (json["time_entries"] as? [[String: Any]] ?? []).compactMap { parse($0, at: now) }

            state.harvestRunning = entries.first { $0.isRunning }
            state.harvestLast = entries.first { !$0.isRunning }
            var seen = Set<String>()
            state.harvestShortcuts = entries.compactMap { e -> HarvestShortcut? in
                let s = HarvestShortcut(projectId: e.projectId, projectName: e.projectName,
                                        taskId: e.taskId, taskName: e.taskName)
                return seen.insert(s.id).inserted ? s : nil
            }.prefix(8).map { $0 }
            state.harvestToday = entries.filter { $0.spentDate == Self.today() }.reduce(0) { $0 + $1.elapsed(at: now) }
            state.harvestError = nil
            state.harvestLoaded = true
            syncPill()
            checkReminder()
        } catch {
            state.harvestError = error.localizedDescription
            state.harvestLoaded = true
            appendAppLog("harvest.log", "refresh: \(error.localizedDescription)")
        }
    }

    // MARK: Actions

    func stop() async {
        guard let running = AppState.shared.harvestRunning else { return }
        do {
            _ = try await request("time_entries/\(running.id)/stop", method: "PATCH")
            SoundEngine.shared.play("close")
        } catch {
            AppState.shared.harvestError = error.localizedDescription
        }
        await refresh()
    }

    /// Starts a timer on `shortcut` (Harvest stops any other running timer).
    func start(_ shortcut: HarvestShortcut) async {
        do {
            if let last = AppState.shared.harvestLast,
               last.projectId == shortcut.projectId, last.taskId == shortcut.taskId,
               last.spentDate == Self.today() {
                // Same task today: keep counting on the same line
                _ = try await request("time_entries/\(last.id)/restart", method: "PATCH")
            } else {
                _ = try await request("time_entries", method: "POST", body: [
                    "project_id": shortcut.projectId,
                    "task_id": shortcut.taskId,
                    "spent_date": Self.today(),
                ])
            }
            SoundEngine.shared.play("approve")
            noTimerSince = nil
        } catch {
            AppState.shared.harvestError = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Island

    private func syncPill() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        if let running = state.harvestRunning {
            state.tasks[idx].state = .working
            state.tasks[idx].steps = [running.label]
            if state.tasks[idx].pillBadge == .approval { state.tasks[idx].pillBadge = nil }
        } else if state.tasks[idx].state == .working {
            state.tasks[idx].state = .idle
            state.tasks[idx].steps = []
        }
    }

    /// Reminds at most every 30 min when you've been at the Mac for 10 min,
    /// on a weekday during work hours, with no timer running.
    private func checkReminder() {
        let state = AppState.shared
        guard state.harvestReminder, state.harvestRunning == nil else { noTimerSince = nil; return }
        let now = Date()
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)       // 1 = Sunday
        let hour = cal.component(.hour, from: now)
        guard (2...6).contains(weekday), hour >= 9, hour < 19 else { noTimerSince = nil; return }
        // Idle for more than 5 minutes: you're away, no reminder
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 300 else { noTimerSince = nil; return }

        if noTimerSince == nil { noTimerSince = now }
        guard let since = noTimerSince, now.timeIntervalSince(since) >= 600 else { return }
        if let last = lastReminder, now.timeIntervalSince(last) < 1800 { return }
        lastReminder = now

        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[idx].state = .question
        state.tasks[idx].steps = ["Pas de timer en cours"]
        state.tasks[idx].pillBadge = .approval
        SoundEngine.shared.play("question")
        if state.mode == .hidden {
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
    }

    /// Called when the Harvest card is on screen.
    func markSeen() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[idx].pillBadge = nil
        if state.tasks[idx].state == .question {
            state.tasks[idx].state = .idle
            state.tasks[idx].steps = []
        }
    }

    static func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }
}
