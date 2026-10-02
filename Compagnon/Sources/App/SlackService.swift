import Foundation
import AppKit

// MARK: - Slack
// Direct messages and @mentions arrive in real time over Socket Mode: a WebSocket
// opened with the app-level token (xapp-…). Names, channels and replies go through
// the Web API with the user token (xoxp-…), so replies are posted as the user.
// Setup: docs/SLACK.md. Nothing is sent to Slack without an explicit click.

struct SlackMessage: Identifiable, Equatable {
    let id: String          // "<channel>:<ts>"
    let channel: String
    let ts: String
    let threadTs: String?
    let isDirect: Bool
    let sender: String
    let place: String       // "Message direct", "Groupe" or "#canal"
    let text: String
    let date: Date

    /// Mentions in a channel are answered in their thread; direct messages in place.
    var replyThreadTs: String? { isDirect ? threadTs : (threadTs ?? ts) }

    var timeAgo: String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60    { return "à l'instant" }
        if diff < 3600  { return "\(Int(diff/60)) min" }
        if diff < 86400 { return "\(Int(diff/3600)) h" }
        return "\(Int(diff/86400)) j"
    }
}

enum SlackStatus: Equatable {
    case notConfigured, connecting, connected
    case error(String)

    var label: String {
        switch self {
        case .notConfigured:    return "Jetons non configurés"
        case .connecting:       return "Connexion…"
        case .connected:        return "Connecté · en écoute"
        case .error(let m):     return "Erreur : \(m)"
        }
    }
}

private enum SlackError: LocalizedError {
    case api(String)
    var errorDescription: String? {
        switch self { case .api(let code): return code }
    }
}

@MainActor
final class SlackService {
    static let shared = SlackService()
    static let pillId = "integration_slack"
    static let userTokenKey = "slack-user-token"
    static let appTokenKey = "slack-app-token"

    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var myUserId: String?
    private var teamId: String?
    private var userNames: [String: String] = [:]
    private var channelNames: [String: String] = [:]
    private var seen: [String] = []
    private var idleReset: Task<Void, Never>?

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Reconnects with the tokens currently in the Keychain (after Settings change them).
    func restart() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        myUserId = nil
        teamId = nil
        start()
    }

    private func run() async {
        var delay: UInt64 = 2
        while !Task.isCancelled {
            guard let userToken = KeychainStore.shared.get(Self.userTokenKey),
                  let appToken = KeychainStore.shared.get(Self.appTokenKey) else {
                AppState.shared.slackStatus = .notConfigured
                loop = nil
                return
            }
            do {
                AppState.shared.slackStatus = .connecting
                if myUserId == nil { try await identify(token: userToken) }
                let url = try await openConnection(token: appToken)
                try await listen(url: url)
                delay = 2   // Slack asked us to reconnect: do it right away
                continue
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                AppState.shared.slackStatus = .error(Self.describe(error))
                appendAppLog("slack.log", "connection: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 120)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error.localizedDescription {
        case "invalid_auth", "not_authed":  return "jeton invalide"
        case "token_revoked":               return "jeton révoqué"
        case "missing_scope":               return "droits manquants (voir le manifeste)"
        case "not_allowed_token_type":      return "mauvais type de jeton"
        default:                            return error.localizedDescription
        }
    }

    // MARK: Web API

    private func api(_ method: String, token: String,
                     query: [String: String] = [:], body: [String: Any]? = nil,
                     post: Bool = false) async throws -> [String: Any] {
        guard var comps = URLComponents(string: "https://slack.com/api/\(method)") else {
            throw SlackError.api("URL invalide")
        }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw SlackError.api("URL invalide") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if post {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SlackError.api("réponse illisible")
        }
        guard json["ok"] as? Bool == true else {
            throw SlackError.api(json["error"] as? String ?? "erreur inconnue")
        }
        return json
    }

    private func identify(token: String) async throws {
        let json = try await api("auth.test", token: token)
        myUserId = json["user_id"] as? String
        teamId = json["team_id"] as? String
    }

    private func openConnection(token: String) async throws -> URL {
        let json = try await api("apps.connections.open", token: token, post: true)
        guard let s = json["url"] as? String, let url = URL(string: s) else {
            throw SlackError.api("pas d'URL de connexion")
        }
        return url
    }

    private func userName(_ id: String, token: String) async -> String {
        if id == myUserId { return "toi" }
        if let cached = userNames[id] { return cached }
        guard let json = try? await api("users.info", token: token, query: ["user": id]),
              let user = json["user"] as? [String: Any] else { return "Quelqu'un" }
        let profile = user["profile"] as? [String: Any]
        let candidates = [profile?["display_name"] as? String, profile?["real_name"] as? String,
                          user["real_name"] as? String, user["name"] as? String]
        let name = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? "Quelqu'un"
        userNames[id] = name
        return name
    }

    private func channelName(_ id: String, token: String) async -> String {
        if let cached = channelNames[id] { return cached }
        guard let json = try? await api("conversations.info", token: token, query: ["channel": id]),
              let channel = json["channel"] as? [String: Any],
              let name = channel["name"] as? String else { return "canal" }
        channelNames[id] = name
        return name
    }

    // MARK: Socket Mode

    private func listen(url: URL) async throws {
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            if socket === task { socket = nil }
        }
        while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data(let d):   data = d
            @unknown default:    continue
            }
            guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            // Every envelope must be acknowledged, or Slack sends it again.
            if let envelopeId = envelope["envelope_id"] as? String {
                try await task.send(.string("{\"envelope_id\":\"\(envelopeId)\"}"))
            }
            switch envelope["type"] as? String {
            case "hello":
                AppState.shared.slackStatus = .connected
            case "disconnect":
                return
            case "events_api":
                if let payload = envelope["payload"] as? [String: Any],
                   let event = payload["event"] as? [String: Any] {
                    await handle(event)
                }
            default:
                break
            }
        }
    }

    private func handle(_ event: [String: Any]) async {
        guard event["type"] as? String == "message",
              let user = event["user"] as? String, user != myUserId,
              let channel = event["channel"] as? String,
              let ts = event["ts"] as? String else { return }
        let subtype = event["subtype"] as? String
        guard subtype == nil || subtype == "thread_broadcast" || subtype == "file_share" else { return }

        let raw = event["text"] as? String ?? ""
        let channelType = event["channel_type"] as? String ?? ""
        let isDirect = channelType == "im" || channelType == "mpim"
        let mentionsMe = myUserId.map { raw.contains("<@\($0)") } ?? false
        guard isDirect || mentionsMe else { return }

        let id = "\(channel):\(ts)"
        guard !seen.contains(id) else { return }
        seen.append(id)
        if seen.count > 200 { seen.removeFirst(seen.count - 200) }

        guard let token = KeychainStore.shared.get(Self.userTokenKey) else { return }
        let sender = await userName(user, token: token)
        let place: String
        if isDirect {
            place = channelType == "mpim" ? "Groupe" : "Message direct"
        } else {
            let name = await channelName(channel, token: token)
            place = "#\(name)"
        }
        var text = await readable(raw, token: token)
        if text.isEmpty { text = subtype == "file_share" ? "📎 Fichier partagé" : "…" }

        let message = SlackMessage(id: id, channel: channel, ts: ts,
                                   threadTs: event["thread_ts"] as? String,
                                   isDirect: isDirect, sender: sender, place: place, text: text,
                                   date: Date(timeIntervalSince1970: Double(ts) ?? Date().timeIntervalSince1970))
        notify(message)
    }

    /// Turns Slack markup (<@U…>, <#C…|name>, <url|label>, &amp;…) into plain text.
    private func readable(_ raw: String, token: String) async -> String {
        guard let regex = try? NSRegularExpression(pattern: "<([^>]+)>") else { return raw }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        // Resolve user names first (async), then rebuild the string.
        var names: [String: String] = [:]
        for m in matches {
            let inner = ns.substring(with: m.range(at: 1))
            if inner.hasPrefix("@") {
                let uid = String(inner.dropFirst().split(separator: "|").first ?? "")
                if names[uid] == nil { names[uid] = await userName(uid, token: token) }
            }
        }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let inner = ns.substring(with: m.range(at: 1))
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            if inner.hasPrefix("@") {
                let uid = String(parts[0].dropFirst())
                out += "@" + (names[uid] ?? "quelqu'un")
            } else if inner.hasPrefix("#") {
                out += "#" + (parts.count > 1 ? parts[1] : "canal")
            } else if inner.hasPrefix("!") {
                out += "@" + (parts.count > 1 ? parts[1] : String(parts[0].dropFirst()))
            } else {
                out += parts.count > 1 ? parts[1] : parts[0]
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Island

    private func notify(_ message: SlackMessage) {
        let state = AppState.shared
        state.slackMessages = Array(([message] + state.slackMessages).prefix(10))
        state.slackUnread += 1

        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[idx].state = .question
        state.tasks[idx].steps = ["\(message.sender) : \(message.text)"]
        let alreadyShown = state.mode == .expanded && state.focusId == Self.pillId && state.view == .overview
        if !alreadyShown { state.tasks[idx].pillBadge = .message }
        if !state.focusMode { SoundEngine.shared.play("pop") }

        // Open on the Slack card, unless you're concentrating, Claude is waiting
        // for an answer or another card is in use.
        let busy = state.focusMode || state.pendingApproval != nil
            || (state.mode == .expanded && state.view != .overview)
        if !busy {
            state.focusId = Self.pillId
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
        }

        // Back to idle after a minute without new messages (the list stays).
        idleReset?.cancel()
        idleReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled,
                  let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
        }
    }

    /// Called when the Slack card is on screen.
    func markRead() {
        let state = AppState.shared
        state.slackUnread = 0
        if let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            state.tasks[i].pillBadge = nil
        }
    }

    // MARK: Actions

    /// Posts `text` as the user, in the message's thread for channel mentions.
    func reply(to message: SlackMessage, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let token = KeychainStore.shared.get(Self.userTokenKey) else { return false }
        var body: [String: Any] = ["channel": message.channel, "text": trimmed]
        if let thread = message.replyThreadTs { body["thread_ts"] = thread }
        do {
            _ = try await api("chat.postMessage", token: token, body: body)
            SoundEngine.shared.play("send")
            return true
        } catch {
            appendAppLog("slack.log", "reply: \(error.localizedDescription)")
            return false
        }
    }

    /// Opens the conversation in the Slack app (or the browser if it isn't installed).
    func open(_ message: SlackMessage?) {
        let team = teamId ?? ""
        if let message,
           let app = URL(string: "slack://channel?team=\(team)&id=\(message.channel)"),
           NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else if let message, !team.isEmpty,
                  let web = URL(string: "https://app.slack.com/client/\(team)/\(message.channel)") {
            NSWorkspace.shared.open(web)
        } else if let slack = URL(string: "slack://open") {
            NSWorkspace.shared.open(slack)
        }
    }

    // MARK: Setup

    /// Slack app manifest: paste it in api.slack.com/apps → Create New App → From a manifest.
    static let manifest = """
    {
      "display_information": {
        "name": "Compagnon",
        "description": "Messages directs et mentions dans l'encoche du Mac",
        "background_color": "#14213d"
      },
      "oauth_config": {
        "scopes": {
          "user": [
            "channels:history", "groups:history", "im:history", "mpim:history",
            "channels:read", "groups:read", "im:read", "mpim:read",
            "users:read", "chat:write"
          ]
        }
      },
      "settings": {
        "event_subscriptions": {
          "user_events": ["message.channels", "message.groups", "message.im", "message.mpim"]
        },
        "interactivity": { "is_enabled": false },
        "org_deploy_enabled": false,
        "socket_mode_enabled": true,
        "token_rotation_enabled": false
      }
    }
    """
}
