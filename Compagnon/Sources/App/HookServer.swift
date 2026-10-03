import Foundation
import Darwin
import AppKit
import SwiftUI

// MARK: - HookServer
// Listens on a Unix domain socket for events from compagnon-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compagnon")
    }
    static var socketPath: String {
        return supportDir.appendingPathComponent("compagnon.sock").path
    }
    static var hookScriptPath: String { supportDir.appendingPathComponent(hookScriptName).path }
    static let hookScriptName = "compagnon-hook"

    /// True when a hook command runs our relay. Compagnon's hooks (compagnon-hook) are left alone.
    static func isOwnHook(_ command: String?) -> Bool {
        command?.contains(hookScriptName) == true
    }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private static let maxPayload = 1_048_576          // 1 MB — reject oversized messages
    private static let receiveTimeoutSeconds: Int = 5   // SO_RCVTIMEO on client sockets
    private static let maxConnections = 32              // concurrent connection ceiling

    private var serverFD: Int32 = -1
    private let connectionLock = NSLock()
    private var connectionCount = 0
    private var pendingApprovalFD: Int32 = -1         // held open while user decides
    private var approvalFDSource: (any DispatchSourceRead)? = nil  // monitors pendingApprovalFD
    private var activeSessionId: String? = nil        // current Claude Code session
    private var focusBeforeApproval: String? = nil    // saved focus to restore after approval
    /// Requests that arrived while another was on screen: shown one after the other.
    private struct QueuedApproval {
        let fd: Int32
        let source: any DispatchSourceRead
        let info: ApprovalInfo
        let token: Int
    }
    private var queuedApprovals: [QueuedApproval] = []
    /// Each request gets its own number (a closed fd's number gets reused).
    private var approvalSerial = 0
    private var currentApprovalToken = -1
    private var pendingQuestionFD: Int32 = -1         // held open while you pick an answer
    private var questionFDSource: (any DispatchSourceRead)? = nil

    private init() {}

    // MARK: - Approval fd helpers

    @MainActor
    private func cancelApprovalFDSource() {
        approvalFDSource?.cancel()
        approvalFDSource = nil
    }

    /// Cancels the approval fd source (which closes the fd via its cancel handler), shows a
    /// 3-second note, clears approval state, then collapses the island.
    @MainActor
    private func dismissApprovalCard(note: String) {
        // cancelApprovalFDSource() triggers the cancel handler which closes the fd.
        // Never close the fd here directly — Apple requires it to happen in the cancel handler.
        cancelApprovalFDSource()
        pendingApprovalFD = -1
        if promoteNextApproval() { return }
        let state = AppState.shared
        let pillId = state.pendingApproval?.pillId ?? "integration_claude"
        state.pendingApproval = nil
        state.isPinned = false
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        // Restore focus to the pill that was focused before the approval card appeared.
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        state.noteMessage = note
        state.view = .note
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }

    /// Returns the tool_input serialized as sorted-keys JSON, "" if absent or empty.
    /// Same computation used in processPermissionRequest and processEvent to match PostToolUse.
    private static func approvalInputKey(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    // MARK: - Start

    func start() {
        // Ensure support directory exists (mode 0700 — not world-readable)
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        installHookScript()
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        // sun_path on macOS is 104 bytes including the NUL terminator → max 103 usable bytes
        let maxSunPathBytes = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard path.utf8.count <= maxSunPathBytes else {
            NSLog("HookServer: socket path too long (\(path.utf8.count) bytes, max \(maxSunPathBytes)): \(path)")
            return
        }
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else { close(fd); return }
        // Restrict socket to owner only
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            // Reject connections from other users (same-UID check)
            var euid: uid_t = 0
            var egid: gid_t = 0
            guard getpeereid(clientFD, &euid, &egid) == 0, euid == getuid() else {
                close(clientFD)
                continue
            }
            // Enforce concurrent connection ceiling
            connectionLock.lock()
            let count = connectionCount
            if count < Self.maxConnections { connectionCount += 1 }
            connectionLock.unlock()
            guard count < Self.maxConnections else {
                close(clientFD)
                continue
            }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        defer {
            connectionLock.lock(); connectionCount -= 1; connectionLock.unlock()
        }
        // 5-second receive timeout — unresponsive clients don't hold threads forever
        var tv = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read newline-delimited JSON
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
            if raw.count > Self.maxPayload { break }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(fd: fd, payload: payload) }
        } else if eventName == "AskUserQuestion" {
            // Hold fd open — the relay waits for the answer picked in the island
            Task { @MainActor in self.processQuestion(fd: fd, payload: payload) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }


    // MARK: - Event → AppState
    // Claude Code events route to the permanent "integration_claude" task.
    // Events tagged with a valid compagnon_agent route to a dynamic "integration_<agent>" task.
    // View switches only happen if VS Code (or the agent pill) is currently focused.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        // Determine which pill this event belongs to.
        // compagnon_agent must be lowercase, digits and hyphens, ≤ 24 chars.
        let rawAgent = payload["compagnon_agent"] as? String ?? ""
        let validAgent = Self.validateAgent(rawAgent)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""

        // Routing:
        // • valid compagnon_agent → its own pill (fire-and-forget, no approval card)
        // • every Claude Code session (Claude app, terminal, VS Code, Cursor) → integration_claude
        let agentId: String
        let isExternalAgent: Bool
        if let agent = validAgent {
            agentId = "agent_\(agent)"
            isExternalAgent = true
        } else {
            agentId = "integration_claude"
            isExternalAgent = false
        }
        _ = (termProgram, bundleId)

        let focused = state.focusId == agentId

        // A question answered in Claude itself (or a turn that ended) closes the card.
        if let q = state.pendingQuestion, sessionId == q.sessionId, !isExternalAgent {
            let tool = payload["tool_name"] as? String ?? ""
            let answeredElsewhere = (name == "PostToolUse" || name == "PostToolUseFailure") && tool == "AskUserQuestion"
            if answeredElsewhere || ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd"].contains(name) {
                finishQuestion(answers: nil, note: "Réglé dans Claude.")
            }
        }

        // While a permission request is pending, dismiss when the resolving event arrives,
        // then continue normal processing. Only skip normal processing when unresolved.
        if !isExternalAgent { dropSettledQueuedApprovals(event: name, sessionId: sessionId, payload: payload) }
        if let pending = state.pendingApproval, agentId == pending.pillId {
            let handledNote: String
            handledNote = "Réglé dans Claude."
            var resolved = false
            switch name {
            case "PostToolUse", "PostToolUseFailure":
                // Only dismiss when this exact tool call finished — same session, tool and input.
                // Other parallel tools finishing must not close the card.
                if sessionId == pending.sessionId,
                   (payload["tool_name"] as? String ?? "") == pending.tool,
                   Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:]) == pending.inputKey {
                    dismissApprovalCard(note: handledNote)
                    resolved = true
                }
            case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt":
                // Turn ended or session interrupted — the permission is moot.
                if sessionId == pending.sessionId {
                    dismissApprovalCard(note: handledNote)
                    resolved = true
                }
            default: break
            }
            if !resolved { return }
            // Approval dismissed — fall through so the resolving event updates state normally.
        }

        switch name {

        case "SessionStart":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            nbLog("SessionStart \(isExternalAgent ? agentId : projectName) (\(sessionId.prefix(8)))")
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            state.updateTask(id: agentId, state: .thinking)
            if let i = state.tasks.firstIndex(where: { $0.id == agentId }) {
                state.tasks[i].startedAt = Date()
                state.tasks[i].lastDuration = nil
            }
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: agentId, step: String(prompt.prefix(60)))
            }
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            state.updateTask(id: agentId, state: .working)
            let tool = payload["tool_name"] as? String ?? "Outil"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let step = frenchStep(tool: tool, input: input)
            appendStep(id: agentId, step: step)

        case "PostToolUse":
            state.updateTask(id: agentId, state: .working)

        case "PostToolUseFailure":
            state.updateTask(id: agentId, state: .working)
            appendStep(id: agentId, step: "⚠ échec")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: agentId, state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: agentId, state: .question)
                appendStep(id: agentId, step: message)
            }

        case "Stop":
            state.updateTask(id: agentId, state: .finished)
            if !isExternalAgent, let i = state.tasks.firstIndex(where: { $0.id == agentId }) {
                state.tasks[i].sessionId = sessionId
            }
            DayService.shared.countClaudeSession()
            if let i = state.tasks.firstIndex(where: { $0.id == agentId }), let start = state.tasks[i].startedAt {
                state.tasks[i].lastDuration = Date().timeIntervalSince(start)
                state.tasks[i].startedAt = nil
            }
            if let message = payload["message"] as? String, !message.isEmpty {
                appendStep(id: agentId, step: String(message.prefix(60)))
            }
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: agentId, badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                if isExternalAgent {
                    AppState.shared.removeTask(id: agentId)
                } else {
                    AppState.shared.updateTask(id: agentId, state: .idle)
                    self.clearPillBadge(id: agentId)
                }
            }

        case "StopFailure":
            state.updateTask(id: agentId, state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: agentId, badge: .error)
            }

        case "Interrupt":
            // Codex: user stopped the turn
            activeSessionId = nil
            state.updateTask(id: agentId, state: .idle)
            clearPillBadge(id: agentId)

        case "SessionEnd":
            activeSessionId = nil
            state.removeTask(id: agentId)

        case "SubagentStart":
            appendStep(id: agentId, step: "+ sous-agent")

        case "SubagentStop":
            appendStep(id: agentId, step: "• sous-agent terminé")

        default:
            break
        }
    }

    // MARK: - Agent validation + dynamic pill

    /// Validates a compagnon_agent name: lowercase, digits and hyphens, 1–24 chars.
    /// "claude" is reserved and rejected so it cannot impersonate the Claude Code pill.
    /// Returns the name unchanged if valid, nil otherwise.
    private static func validateAgent(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 24, raw != "claude" else { return nil }
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)  // a-z
                  || (v >= 0x30 && v <= 0x39)   // 0-9
                  || v == 0x2D                   // -
            guard ok else { return nil }
        }
        return raw
    }

    /// Creates a dynamic pill for a third-party agent on first event, then no-ops.
    /// ID format: "agent_<name>" — never collides with "integration_*" pills.
    /// Inserted right after integration_claude so it appears in the visible prefix(4).
    @MainActor
    private func upsertExternalAgent(id: String, name: String) {
        let state = AppState.shared
        guard state.tasks.firstIndex(where: { $0.id == id }) == nil else { return }
        let color = IslandConst.colorForProject(name)
        let task = AgentTask(id: id, name: name, color: color, state: .idle, steps: [], source: .agent)
        if let claudeIdx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) {
            state.tasks.insert(task, at: claudeIdx + 1)
        } else {
            state.tasks.append(task)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    // MARK: - Helpers

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            // Approval always wins; other alerts are blocked while a card is showing
            if view == .approval {
                state.view = view
            } else if isAlert && state.pendingApproval == nil {
                state.view = view
            }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let rawAgent = payload["compagnon_agent"] as? String ?? ""

        // External agents (any compagnon_agent) answer immediately with "ask"
        // so the agent re-asks in its own terminal — they do not get a notch card.
        if Self.validateAgent(rawAgent) != nil {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        // Every Claude Code session (Claude app, terminal, VS Code, Cursor) gets the card.
        let pillId = "integration_claude"

        let tool = payload["tool_name"] as? String ?? "Outil"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let summary = Self.describeTool(tool, input: toolInput, cwd: cwd)
        let command = summary.text
        let inputKey = Self.approvalInputKey(toolInput)
        nbLog("PermissionRequest \(tool) [\(pillId)]")

        let info = ApprovalInfo(sessionId: sessionId, tool: tool,
                                command: command, inputKey: inputKey, pillId: pillId,
                                detail: summary.detail, toolLabel: summary.label,
                                removed: Self.firstLine(toolInput["old_string"]),
                                added: Self.firstLine(toolInput["new_string"] ?? toolInput["content"]),
                                projectName: projectName, cwd: cwd)
        approvalSerial += 1
        let token = approvalSerial
        let source = watchApproval(fd: fd, token: token)

        // 115s safety timeout — cancel without sending a decision. compagnon-hook reads EOF
        // from the cancel handler's close and exits; Claude Code re-asks in its own window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
            self?.approvalClosed(token: token, note: "Toujours en attente dans Claude.")
        }

        if pendingApprovalFD >= 0 {
            // Another request is on screen: this one waits its turn
            queuedApprovals.append(QueuedApproval(fd: fd, source: source, info: info, token: token))
            state.approvalsWaiting = queuedApprovals.count
            return
        }
        SoundEngine.shared.play("approval")
        // Save current focus so we can restore it when the last card is dismissed.
        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        presentApproval(info, fd: fd, source: source, token: token)
    }

    /// Puts a request on screen. Approval always forces the island open.
    @MainActor
    private func presentApproval(_ info: ApprovalInfo, fd: Int32, source: any DispatchSourceRead, token: Int) {
        let state = AppState.shared
        currentApprovalToken = token
        pendingApprovalFD = fd
        approvalFDSource = source
        activeSessionId = info.sessionId
        upsertWorkspaceTask(id: info.pillId, projectName: info.projectName, cwd: info.cwd)
        state.updateTask(id: info.pillId, state: .approval)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { state.pendingApproval = info }
        state.approvalsWaiting = queuedApprovals.count
        state.isPinned = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = info.pillId }
        expandIfNeeded(to: .approval)
    }

    /// The card on screen is settled: show the next waiting request, if any.
    @MainActor
    private func promoteNextApproval() -> Bool {
        guard !queuedApprovals.isEmpty else {
            AppState.shared.approvalsWaiting = 0
            return false
        }
        let next = queuedApprovals.removeFirst()
        presentApproval(next.info, fd: next.fd, source: next.source, token: next.token)
        AppState.shared.view = .approval
        return true
    }

    /// Watches a waiting relay: if Claude settles the request itself, its connection closes.
    /// The cancel handler closes the fd — never close it anywhere else.
    @MainActor
    private func watchApproval(fd: Int32, token: Int) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.approvalClosed(token: token, note: "Réglé dans Claude.") }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    @MainActor
    private func approvalClosed(token: Int, note: String) {
        if pendingApprovalFD >= 0 && currentApprovalToken == token {
            dismissApprovalCard(note: note)
        } else if let i = queuedApprovals.firstIndex(where: { $0.token == token }) {
            queuedApprovals.remove(at: i).source.cancel()
            AppState.shared.approvalsWaiting = queuedApprovals.count
        }
    }

    /// Waiting requests settled in Claude itself (tool ran, turn ended) leave the queue.
    @MainActor
    private func dropSettledQueuedApprovals(event name: String, sessionId: String, payload: [String: Any]) {
        guard !queuedApprovals.isEmpty else { return }
        let tool = payload["tool_name"] as? String ?? ""
        let key = Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:])
        queuedApprovals.removeAll { q in
            guard q.info.sessionId == sessionId else { return false }
            let settled: Bool
            switch name {
            case "PostToolUse", "PostToolUseFailure": settled = q.info.tool == tool && q.info.inputKey == key
            case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt": settled = true
            default: settled = false
            }
            if settled { q.source.cancel() }
            return settled
        }
        AppState.shared.approvalsWaiting = queuedApprovals.count
    }

    // MARK: - Questions (AskUserQuestion, blocking — the relay waits for the answer)

    @MainActor
    private func processQuestion(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let items: [ClaudeQuestion.Item] = (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> ClaudeQuestion.Option? in
                guard let label = o["label"] as? String else { return nil }
                return ClaudeQuestion.Option(label: label, description: o["description"] as? String ?? "")
            }
            return ClaudeQuestion.Item(question: text, header: q["header"] as? String ?? "",
                                       options: options, multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        guard !items.isEmpty else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: "{}")
                close(fd)
            }
            return
        }
        nbLog("AskUserQuestion ×\(items.count) (\(sessionId.prefix(8)))")

        // A new question replaces an unanswered one (that one goes back to Claude)
        if pendingQuestionFD >= 0 { finishQuestion(answers: nil, note: nil) }
        pendingQuestionFD = fd

        let pillId = "integration_claude"
        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd)
        state.updateTask(id: pillId, state: .question)
        state.pendingQuestion = ClaudeQuestion(sessionId: sessionId, items: items)
        state.isPinned = true
        SoundEngine.shared.play("question")
        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        if state.mode == .expanded {
            if state.pendingApproval == nil { state.view = .question }
        } else {
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.question)
        }

        // The relay hanging up means the question was dealt with elsewhere.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.pendingQuestionFD == fd else { return }
            self.finishQuestion(answers: nil, note: "Réglé dans Claude.")
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        questionFDSource = source

        // Just under the relay's 590 s: hand the question back to Claude
        DispatchQueue.main.asyncAfter(deadline: .now() + 585) { [weak self] in
            guard let self, self.pendingQuestionFD == fd else { return }
            self.finishQuestion(answers: nil, note: "Question renvoyée dans Claude.")
        }
    }

    /// Sends the answers (question text → label, [labels] or free text) to the waiting relay,
    /// or nothing so Claude asks the question itself. Then clears the card.
    @MainActor
    func finishQuestion(answers: [String: Any]?, note: String?) {
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        let state = AppState.shared

        var reply = "{}"
        if let answers {
            var obj: [String: Any] = ["answers": answers]
            if state.questionCompatMode { obj["mode"] = "deny" }
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: data, encoding: .utf8) { reply = str }
        }
        if fd >= 0 {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: reply)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }

        let pillId = "integration_claude"
        state.pendingQuestion = nil
        state.isPinned = state.pendingApproval != nil
        state.updateTask(id: pillId, state: answers == nil ? .idle : .working)
        clearPillBadge(id: pillId)
        if let prev = focusBeforeApproval, state.pendingApproval == nil {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        guard state.view == .question else { return }
        if let note {
            state.noteMessage = note
            state.view = .note
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            }
        } else {
            state.view = .overview
            if answers != nil {
                SoundEngine.shared.play("send")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NotificationCenter.default.post(name: .islandCollapse, object: nil)
                }
            }
        }
    }

    /// Called by ApprovalView buttons. Writes the decision to the waiting compagnon-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        let fd = pendingApprovalFD
        pendingApprovalFD = -1
        // Capture source before nulling — we send the decision first, then cancel the source.
        // The cancel handler closes the fd; never close it directly.
        let source = approvalFDSource
        approvalFDSource = nil

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }

        if fd >= 0 {
            Task.detached { [weak self] in
                // Write decision while fd is still valid, then cancel source → cancel handler closes fd
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }

        if promoteNextApproval() { return }
        let state = AppState.shared
        let pillId = state.pendingApproval?.pillId ?? "integration_claude"
        state.pendingApproval = nil
        state.isPinned = false
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        // Restore focus to the pill that was focused before the approval card appeared.
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    /// First non-blank line of a text argument, trimmed ("" if none).
    static func firstLine(_ value: Any?) -> String {
        guard let text = value as? String else { return "" }
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(160))
    }

    /// What an approval card shows for a tool call: the command, the file, the URL…
    /// rather than just the tool's name ("Edit" alone says nothing).
    static func describeTool(_ tool: String, input: [String: Any], cwd: String)
        -> (label: String, text: String, detail: String) {
        func str(_ k: String) -> String { (input[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        // Paths inside the project are shown relative to it, the home folder as ~
        func path(_ p: String) -> String {
            if !cwd.isEmpty, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
            let home = NSHomeDirectory()
            if p.hasPrefix(home + "/") { return "~/" + p.dropFirst(home.count + 1) }
            return p
        }
        switch tool {
        case "Bash":
            return ("Terminal", str("command").isEmpty ? tool : str("command"), str("description"))
        case "Edit", "MultiEdit":
            return ("Modifier", path(str("file_path")), "")
        case "Write":
            return ("Créer", path(str("file_path")), "")
        case "Read":
            return ("Lire", path(str("file_path")), "")
        case "NotebookEdit":
            return ("Modifier", path(str("notebook_path")), "")
        case "WebFetch":
            return ("Web", str("url"), str("prompt"))
        case "WebSearch":
            return ("Recherche", str("query"), "")
        case "Glob", "Grep":
            return ("Chercher", str("pattern") + (str("path").isEmpty ? "" : "  dans " + path(str("path"))), "")
        case "Task", "Agent":
            return ("Agent", str("description").isEmpty ? str("prompt") : str("description"), "")
        default:
            // MCP tools: mcp__server__tool → "server · tool", plus their first text argument
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                let name = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : parts.first ?? tool
                let server = (parts.first ?? "").replacingOccurrences(of: "_", with: " ")
                let arg = input.keys.sorted().compactMap { input[$0] as? String }.first { !$0.isEmpty } ?? ""
                return (server, name.replacingOccurrences(of: "_", with: " "),
                        String(arg.prefix(200)))
            }
            let arg = input.keys.sorted().compactMap { input[$0] as? String }.first { !$0.isEmpty } ?? ""
            return (tool, arg.isEmpty ? tool : arg, "")
        }
    }

    /// Updates or transiently creates a workspace pill (VS Code or Cursor) task.
    /// If the task already exists (persistent), just updates name/cwd.
    /// If missing (transient), creates it and inserts after the main pill.
    @MainActor
    private func upsertWorkspaceTask(id: String, projectName: String, cwd: String = "") {
        let state = AppState.shared
        if let idx = state.tasks.firstIndex(where: { $0.id == id }) {
            state.tasks[idx].name = projectName
            if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
            return
        }
        // Transient: create and insert after the main pill
        let def = PillCatalog.definition(for: id)
        let color = def?.color ?? "#C0C4CC"
        let source = def?.source ?? .agent
        let task = AgentTask(id: id, name: projectName, color: color,
                             state: .idle, steps: [], source: source, isIntegration: true)
        if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.insert(task, at: 0)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "compagnon":    "Compagnon",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - French step labels

    private func frenchStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":        "Exécute",
            "Read":        "Lit",
            "Write":       "Écrit",
            "Edit":        "Modifie",
            "Glob":        "Cherche",
            "Grep":        "Recherche",
            "WebSearch":   "Recherche web",
            "WebFetch":    "Récupère",
            "TodoWrite":   "Tâches",
            "Task":        "Agent",
            "LS":          "Liste",
            "MultiEdit":   "Modifie",
            "NotebookEdit": "Notebook",
            // Codex tools
            "apply_patch": "Modifie",
            "update_plan": "Tâches",
            "spawn_agent": "Agent",
        ]
        var label = labels[tool] ?? tool

        // Codex MCP tools arrive as mcp__server__tool — show "server · tool"
        if tool.hasPrefix("mcp__") {
            let rest = String(tool.dropFirst(5))
            let parts = rest.components(separatedBy: "__")
            label = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : rest
        }

        // Bash: infer a more precise verb from the command
        if tool == "Bash", let cmd = input["command"] as? String {
            return "\(bashVerb(cmd)) · \(oneLine(cmd))"
        }

        // apply_patch: extract the first file name from the patch
        if tool == "apply_patch", let patch = input["command"] as? String {
            for line in patch.split(separator: "\n") {
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
                    if line.hasPrefix(prefix) {
                        let path = String(line.dropFirst(prefix.count))
                        return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
                    }
                }
            }
            return label
        }

        if let cmd = input["command"] as? String {
            return "\(label) · \(oneLine(cmd))"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(oneLine(query))"
        }
        return label
    }

    /// Infers a French verb from a shell command's first word.
    private func bashVerb(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl": return "Lit"
        case "rg", "grep", "find", "fd", "ls", "tree", "wc":    return "Cherche"
        default: break
        }
        let testRunners = ["pytest", "vitest", "jest", "npm test", "npm run test",
                           "cargo test", "go test", "swift test", "make test",
                           "xcodebuild test", "unittest"]
        if testRunners.contains(where: { command.contains($0) }) { return "Teste" }
        return "Exécute"
    }

    /// Collapses whitespace so a multi-line command stays one ticker row.
    private func oneLine(_ text: String, limit: Int = 60) -> String {
        let collapsed = text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
                            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        appendAppLog("nb.log", message)
    }

    private func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - compagnon-hook script installation

    func installHookScript() {
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        // compagnon-hook: shell wrapper (always exits 0, calls compagnon-hook.py via python3)
        let wrapperURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? hookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        // compagnon-hook.py: Python relay
        let pyURL = wrapperURL.deletingLastPathComponent().appendingPathComponent("compagnon-hook.py")
        try? hookPython.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Compagnon PermissionRequest hook with timeout < 120s.
    /// True when ~/.claude/settings.json runs our relay on SessionStart.
    static func claudeHooksInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let ss = hooks["SessionStart"] as? [[String: Any]] else { return false }
        return ss.contains { ($0["hooks"] as? [[String: Any]])?.contains { isOwnHook($0["command"] as? String) } ?? false }
    }

    static func hooksNeedUpdate() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any],
              let permReqHooks = hooks["PermissionRequest"] as? [[String: Any]] else {
            return false
        }
        // Installed before questions were supported: no AskUserQuestion entry yet
        let preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let hasAskEntry = preToolUse.contains { entry in
            (entry["matcher"] as? String) == "AskUserQuestion"
                && ((entry["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String).map { isOwnHook($0) && $0.contains("--ask") } ?? false
                } ?? false)
        }
        if claudeHooksInstalled() && !hasAskEntry { return true }
        for matcher in permReqHooks {
            if let hookList = matcher["hooks"] as? [[String: Any]] {
                for hook in hookList {
                    if let cmd = hook["command"] as? String,
                       Self.isOwnHook(cmd),
                       let timeout = hook["timeout"] as? Int,
                       timeout < 120 {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let data = try buildHooksData()
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Backup first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    private func buildHooksData() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        let quotedCmd = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { Self.isOwnHook($0["command"] as? String) } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            if event == "PreToolUse" {
                // Claude's multiple-choice questions: wait (up to 10 min) for the answer in the island
                existing.append(["matcher": "AskUserQuestion",
                                 "hooks": [["type": "command", "command": quotedCmd + " --ask", "timeout": 600]]])
            }
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        Self.isOwnHook($0["command"] as? String)
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("compagnon.hookExpand")
}

// MARK: - compagnon-hook shell wrapper 
// Invoked by Claude Code via /bin/sh or directly via shebang.
// Always exits 0 — never blocks Claude Code.
// Checks xcode-select before running python3 to avoid triggering the
// "install developer tools" dialog on machines without Xcode CLI tools.

private let hookShellWrapper = """
#!/bin/sh
# Compagnon hook relay — always exits 0, never blocks Claude Code
HOOK_DIR="$(dirname "$0")"
# Compagnon's own chat runs Claude Code too: stay out of the island for it
if [ -n "$COMPAGNON_CHAT" ]; then cat >/dev/null; exit 0; fi
if xcode-select -p >/dev/null 2>&1; then
    out=$(/usr/bin/python3 "$HOOK_DIR/compagnon-hook.py" "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        printf '%s\\n' "$out"
    fi
fi
exit 0
"""

// MARK: - compagnon-hook Python relay

private let hookPython = """
#!/usr/bin/env python3
# compagnon-hook.py — Compagnon hook relay for Claude Code and third-party agents
# Reads JSON from stdin, forwards to Compagnon via Unix socket, translates response.
import sys, json, os, socket

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' in payload:
        return
    tool = payload.get('toolCall')
    if not isinstance(tool, dict):
        tool = {}
    name = tool.get('name') or payload.get('tool', '')
    if name:
        payload['tool_name'] = name
    if 'tool_input' not in payload and isinstance(tool.get('args'), dict):
        flat = dict(tool['args'])
        for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                         ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
            if src in flat:
                flat[dst] = flat[src]
        payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid

def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with compagnon_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    ask_mode = False
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        elif args[i] == '--ask':
            ask_mode = True
            i += 1
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('compagnon_agent', agent)

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Application Support/Compagnon/compagnon.sock'
    )

    # Claude asks a multiple-choice question (dedicated PreToolUse entry, matcher
    # AskUserQuestion): wait for the answer picked in Compagnon. No answer, or
    # 'Répondre dans Claude' → print nothing and Claude shows its own question.
    if ask_mode:
        if payload.get('tool_name') != 'AskUserQuestion':
            return
        payload['hook_event_name'] = 'AskUserQuestion'
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(590)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            resp = json.loads(b''.join(chunks).decode().strip() or '{}')
        except Exception:
            return
        answers = resp.get('answers')
        if not answers:
            return
        tool_input = payload.get('tool_input') or {}
        if resp.get('mode') == 'deny':
            # Compatibility mode: hand the answers to Claude as text
            lines = ['- ' + q + ' → ' + (', '.join(a) if isinstance(a, list) else str(a)) for q, a in answers.items()]
            reason = "L'utilisateur a répondu depuis Compagnon :\\n" + '\\n'.join(lines) + "\\nContinue avec ces réponses, sans reposer la question."
            out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny', 'permissionDecisionReason': reason}}
        else:
            out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow',
                   'updatedInput': {'questions': tool_input.get('questions', []), 'answers': answers}}}
        sys.stdout.write(json.dumps(out) + '\\n')
        sys.stdout.flush()
        sys.exit(0)

    if event == 'PermissionRequest':
        # Block and wait for Compagnon's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always' and agent != 'codex':
                    # Let Claude Code persist the rule via updatedPermissions
                    suggestions = payload.get('permission_suggestions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Codex rejects updatedPermissions — answer a plain allow instead
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Refusé depuis Compagnon'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → agent re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Claude Code / Codex will handle the absence of output (re-ask or default behaviour)
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Gemini CLI and Antigravity expect a JSON response on stdout (empty = no decision)
    if agent in ('gemini', 'antigravity'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

main()
sys.exit(0)
"""
