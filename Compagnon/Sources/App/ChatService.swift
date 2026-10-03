import Foundation
import AppKit

// MARK: - Chat with Claude
// A quick chat in the island, through the Claude Code CLI already installed and
// signed in on this Mac (`claude -p`): it uses your Claude plan, no API key.
// Claude Sonnet. The last conversations are kept (‹ › to go back to one and carry on).
// Runs in its own folder with COMPAGNON_CHAT set, so our hooks ignore it.

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    var text: String
    var failed = false
}

struct ChatConversation: Identifiable, Codable {
    var id = UUID()
    var sessionId: String?
    var messages: [ChatMessage] = []
    var updated = Date()
}

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    /// Newest first; `index` is the one on screen. Kept in chats.json (last 10).
    @Published private(set) var conversations: [ChatConversation] = [ChatConversation()]
    @Published private(set) var index = 0
    @Published private(set) var busy = false

    var messages: [ChatMessage] { conversations[index].messages }
    var canGoOlder: Bool { index + 1 < conversations.count }
    var canGoNewer: Bool { index > 0 }
    /// What you're typing, kept while you visit other views.
    @Published var draft = ""
    /// Sonnet: quick enough for chat, good at rewriting text.
    private let model = "claude-sonnet-5-5"

    /// The conversation an answer is streaming into (you may browse others meanwhile).
    private var activeID: UUID?
    private var process: Process?
    private var buffer = Data()
    private var gotDeltas = false
    private static var claudePath: String?

    private static let systemPrompt = """
    Tu réponds dans une toute petite fenêtre, sous l'encoche d'un Mac. Sois bref et direct, \
    en français sauf si on t'écrit dans une autre langue. Pas de titres ni de longues listes. \
    Quand on te demande de corriger, traduire ou reformuler un texte, renvoie seulement le texte final, \
    sans commentaire.
    """

    private static var fileURL: URL { HookServer.supportDir.appendingPathComponent("chats.json") }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? decoder.decode([ChatConversation].self, from: data), !saved.isEmpty {
            // Open on a fresh conversation, the saved ones one ‹ away
            conversations = [ChatConversation()] + saved.filter { !$0.messages.isEmpty }
        }
    }

    private func save() {
        let keep = conversations.filter { !$0.messages.isEmpty }.prefix(10)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(keep)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func mutate(_ id: UUID?, _ change: (inout ChatConversation) -> Void) {
        guard let id, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[i])
    }

    // MARK: Sending

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !busy else { return }
        let id = conversations[index].id
        activeID = id
        mutate(id) {
            $0.messages.append(ChatMessage(role: .user, text: prompt))
            $0.messages.append(ChatMessage(role: .assistant, text: ""))
            $0.updated = Date()
        }
        busy = true
        gotDeltas = false
        Task { @MainActor in
            guard let claude = await Self.findClaude() else {
                finish(error: "Claude Code est introuvable sur ce Mac. Installe-le (npm install -g @anthropic-ai/claude-code), connecte-toi une fois dans le terminal, puis réessaie.")
                return
            }
            run(claude: claude, prompt: prompt)
        }
    }

    func stop() {
        process?.terminate()
    }

    func newConversation() {
        if conversations[index].messages.isEmpty { return }
        conversations.removeAll { $0.messages.isEmpty }
        conversations.insert(ChatConversation(), at: 0)
        index = 0
    }

    func older() { if canGoOlder { index += 1 } }
    func newer() { if canGoNewer { index -= 1 } }

    func copy(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    // MARK: Process

    private func run(claude: String, prompt: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        var args = ["-p", prompt, "--model", model,
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--append-system-prompt", Self.systemPrompt]
        if let sid = conversations.first(where: { $0.id == activeID })?.sessionId { args += ["--resume", sid] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["COMPAGNON_CHAT"] = "1"
        p.environment = env
        let dir = HookServer.supportDir.appendingPathComponent("chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = dir

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        buffer = Data()

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in ChatService.shared.consume(data) }
        }
        let errHandle = err.fileHandleForReading
        p.terminationHandler = { proc in
            let errText = String(data: errHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in
                ChatService.shared.processEnded(status: status, uncaught: reason == .uncaughtSignal, stderr: errText)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            finish(error: "Impossible de lancer Claude Code : \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = json["type"] as? String else { return }
        if let sid = json["session_id"] as? String { mutate(activeID) { $0.sessionId = sid } }
        switch type {
        case "stream_event":
            // Text arriving word by word
            if let event = json["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                gotDeltas = true
                appendToReply(text)
            }
        case "assistant":
            // Whole message (older CLIs without partial messages)
            guard !gotDeltas, let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.isEmpty { appendToReply(text) }
        case "result":
            if json["is_error"] as? Bool == true {
                let msg = (json["result"] as? String) ?? "Claude n'a pas pu répondre."
                markReplyFailed(msg)
            } else if let result = json["result"] as? String,
                      conversations.first(where: { $0.id == activeID })?.messages.last?.text.isEmpty == true {
                appendToReply(result)
            }
        default:
            break
        }
    }

    private func appendToReply(_ text: String) {
        mutate(activeID) { c in
            guard let i = c.messages.indices.last, c.messages[i].role == .assistant else { return }
            c.messages[i].text += text
        }
    }

    private func markReplyFailed(_ text: String) {
        mutate(activeID) { c in
            guard let i = c.messages.indices.last, c.messages[i].role == .assistant else { return }
            c.messages[i].text = text
            c.messages[i].failed = true
        }
    }

    private func processEnded(status: Int32, uncaught: Bool, stderr: String) {
        process = nil
        let reply = conversations.first(where: { $0.id == activeID })?.messages.last
        if let last = reply, last.role == .assistant, last.text.isEmpty {
            if uncaught {
                markReplyFailed("Arrêté.")
            } else {
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                markReplyFailed(detail.isEmpty ? "Claude n'a pas répondu (code \(status)). Vérifie que tu es connecté : lance « claude » une fois dans le terminal."
                                               : String(detail.suffix(240)))
            }
        }
        busy = false
        save()
        // Answer ready while the island is folded: peek out
        let state = AppState.shared
        if !(state.mode == .expanded && state.view == .chat) {
            SoundEngine.shared.play("finish")
            if state.mode == .hidden { NotificationCenter.default.post(name: .hookReveal, object: nil) }
        }
    }

    private func finish(error: String) {
        markReplyFailed(error)
        busy = false
    }

    // MARK: Health check (Settings → Claude Code)

    /// Is the CLI there, which version, and is someone signed in? Costs no tokens.
    static func diagnose() async -> (ok: Bool, text: String) {
        guard let path = await findClaude() else {
            return (false, "Claude Code introuvable. Installe-le : npm install -g @anthropic-ai/claude-code")
        }
        let version: String = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--version"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
        // Signed in = ~/.claude.json carries the account
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        let json = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let account = json?["oauthAccount"] as? [String: Any]
        let name = version.isEmpty ? "Claude Code" : "Claude Code \(version.split(separator: " ").first ?? "")"
        guard let account else {
            return (false, "\(name) trouvé, mais personne n'est connecté : lance « claude » une fois dans le terminal.")
        }
        let email = account["emailAddress"] as? String
        return (true, "\(name) prêt\(email.map { " · \($0)" } ?? "")")
    }

    // MARK: Finding the CLI

    /// Asks a login shell (so your PATH from .zshrc applies), then common install spots.
    private static func findClaude() async -> String? {
        if let claudePath { return claudePath }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found: String? = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lic", "command -v claude"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
            if let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
            let candidates = ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                              "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }.value
        claudePath = found
        return found
    }
}
