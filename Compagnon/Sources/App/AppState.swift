import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Island state
    @Published var mode: IslandMode = .hidden
    @Published var view: IslandView = .overview

    // Tasks (one per pill)
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil

    // Bot state override
    @Published var stateOverride: BotState? = nil

    // Real notch dimensions (set by IslandWindowController on launch)
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight
    var hasNotch = true

    // Mouse tracking
    var mousePosition: CGPoint = .zero
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    // The always-on pill
    let mainPillId: String = PillCatalog.defaultMainPillId

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Pending approval request from Claude Code hook
    @Published var pendingApproval: ApprovalInfo? = nil

    // True while you type in the island (Slack reply): keeps it open
    @Published var isEditingText: Bool = false

    // MARK: Settings (persisted)

    @Published var soundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Sound volume (0–0.2), synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    var absenceInterval: TimeInterval = 3 * 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // How long hidden before greeting on reappear (default 2 min)
    var greetThresholdSeconds: TimeInterval = 120 {
        didSet { UserDefaults.standard.set(greetThresholdSeconds, forKey: "greetThreshold") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    @Published var autoUpdate: Bool = true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }

    @Published var harvestReminder: Bool = true {
        didSet { UserDefaults.standard.set(harvestReminder, forKey: "harvestReminder") }
    }

    // MARK: Services

    // GitHub (GithubPoller)
    @Published var githubStats: GitHubStats? = nil

    // Slack (SlackService)
    @Published var slackMessages: [SlackMessage] = []
    @Published var slackUnread: Int = 0
    @Published var slackStatus: SlackStatus = .notConfigured

    // Harvest (HarvestService)
    @Published var harvestRunning: HarvestEntry? = nil
    @Published var harvestLast: HarvestEntry? = nil
    @Published var harvestProjects: [HarvestProject] = []
    @Published var harvestLoaded: Bool = false
    @Published var harvestError: String? = nil

    // Self-update (UpdateService)
    @Published var updateStatus: UpdateStatus = .idle

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = UserDefaults.standard
        if let v = ud.object(forKey: "soundEnabled") as? Bool      { soundEnabled = v }
        if let v = ud.object(forKey: "soundVolume") as? Double     { soundVolume = v }
        if let v = ud.object(forKey: "autoCloseInterval") as? Double { autoCloseInterval = v }
        if let v = ud.object(forKey: "absenceInterval") as? Double { absenceInterval = v }
        if let v = ud.object(forKey: "greetThreshold") as? Double  { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool     { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags") as? Int        { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode") as? Int         { hotkeyCode = UInt16(v) }
        if let v = ud.object(forKey: "autoUpdate") as? Bool        { autoUpdate = v }
        if let v = ud.object(forKey: "harvestReminder") as? Bool   { harvestReminder = v }

        SoundEngine.shared.volume = Float(soundVolume)
        refreshPills()
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    var effectiveState: BotState {
        stateOverride ?? focusTask?.state ?? .idle
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        sortTasksByCatalog()
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        // Catalog pills are reset to idle, never removed
        if let def = PillCatalog.definition(for: id), def.isConfigured() {
            if let idx = tasks.firstIndex(where: { $0.id == id }) {
                tasks[idx].state      = .idle
                tasks[idx].steps      = []
                tasks[idx].stepIndex  = 0
                tasks[idx].pillBadge  = nil
                tasks[idx].name       = def.name
            }
            return
        }
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = mainPillId }
        syncMode()
        syncView()
    }

    func updateTask(id: String, state: BotState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
    }

    func setFocus(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        focusId = id
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
    }

    func syncMode() {
        if tasks.isEmpty && mode == .compact {
            mode = .hidden
        } else if !tasks.isEmpty && mode == .hidden && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// Shows Claude Code, plus every service whose keys are set. Call after Settings change keys.
    func refreshPills() {
        for def in PillCatalog.all {
            let shouldShow = def.isConfigured()
            let shown = tasks.contains { $0.id == def.id }
            if shouldShow && !shown {
                tasks.append(AgentTask(id: def.id, name: def.name, color: def.color,
                                       state: .idle, steps: [], source: def.source, isIntegration: true))
            } else if !shouldShow && shown {
                tasks.removeAll { $0.id == def.id }
                if focusId == def.id { focusId = mainPillId }
            }
        }
        sortTasksByCatalog()
        if focusId == nil { focusId = mainPillId }
        syncMode()
    }

    /// Catalog order, with live agent sessions right after Claude Code.
    private func sortTasksByCatalog() {
        let order = PillCatalog.all.enumerated()
            .reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        let catalogPills    = tasks.filter { order[$0.id] != nil }
            .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        let otherPills      = tasks.filter { order[$0.id] == nil }
        if let first = catalogPills.first, first.id == mainPillId {
            tasks = [first] + otherPills + catalogPills.dropFirst()
        } else {
            tasks = otherPills + catalogPills
        }
    }
}

// MARK: - GitHub

struct GitHubStats {
    let totalRepos: Int
    let totalStars: Int
}
