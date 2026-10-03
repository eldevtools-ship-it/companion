import Foundation
import AppKit

// MARK: - Chat with Claude
// A quick chat in the island, through the Claude Code CLI already installed and
// signed in on this Mac (`claude -p`): it uses your Claude plan, no API key.
// Small, fast model by default; one conversation that continues until you start
// a new one. Runs in its own folder with COMPAGNON_CHAT set, so our hooks ignore it.

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var failed = false
}

enum ChatModel: String, CaseIterable {
    case haiku = "claude-haiku-4-5"
    case sonnet = "claude-sonnet-5-5"

    var label: String { self == .haiku ? "Haiku · rapide" : "Sonnet" }
}

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var busy = false
    /// What you're typing, kept while you visit other views.
    @Published var draft = ""
    @Published var model: ChatModel = .haiku {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "chatModel") }
    }

    private var sessionId: String?
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

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "chatModel"), let m = ChatModel(rawValue: raw) { model = m }
    }

    // MARK: Sending

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !busy else { return }
        messages.append(ChatMessage(role: .user, text: prompt))
        messages.append(ChatMessage(role: .assistant, text: ""))
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

    /// Clipboard shortcuts: correct, translate or shorten what you copied.
    func sendWithClipboard(_ instruction: String) {
        guard let copied = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !copied.isEmpty else {
            messages.append(ChatMessage(role: .assistant, text: "Copie d'abord un texte (⌘C), puis clique à nouveau.", failed: true))
            return
        }
        send("\(instruction)\n\n\(copied)")
    }

    func stop() {
        process?.terminate()
    }

    func newConversation() {
        stop()
        sessionId = nil
        messages = []
    }

    func copy(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    // MARK: Process

    private func run(claude: String, prompt: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        var args = ["-p", prompt, "--model", model.rawValue,
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--append-system-prompt", Self.systemPrompt]
        if let sessionId { args += ["--resume", sessionId] }
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
        if let sid = json["session_id"] as? String { sessionId = sid }
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
            } else if let result = json["result"] as? String, messages.last?.text.isEmpty == true {
                appendToReply(result)
            }
        default:
            break
        }
    }

    private func appendToReply(_ text: String) {
        guard let i = messages.indices.last, messages[i].role == .assistant else { return }
        messages[i].text += text
    }

    private func markReplyFailed(_ text: String) {
        guard let i = messages.indices.last, messages[i].role == .assistant else { return }
        messages[i].text = text
        messages[i].failed = true
    }

    private func processEnded(status: Int32, uncaught: Bool, stderr: String) {
        process = nil
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            if uncaught {
                markReplyFailed("Arrêté.")
            } else {
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                markReplyFailed(detail.isEmpty ? "Claude n'a pas répondu (code \(status)). Vérifie que tu es connecté : lance « claude » une fois dans le terminal."
                                               : String(detail.suffix(240)))
            }
        }
        busy = false
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
