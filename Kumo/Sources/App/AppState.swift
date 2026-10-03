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
    /// Last keystroke in the chat / notes, and last chunk of Claude's chat answer (the cloud reacts)
    var typingAt: Date = .distantPast
    var claudeTalkingAt: Date = .distantPast
    var isPresent: Bool = true
    /// Screens asleep or session locked: pollers skip their network calls.
    var macAsleep: Bool = false

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    // The always-on pill
    let mainPillId: String = PillCatalog.defaultMainPillId

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Pending approval request from Claude Code hook
    @Published var pendingApproval: ApprovalInfo? = nil

    // Pending multiple-choice question from Claude (AskUserQuestion)
    @Published var pendingQuestion: ClaudeQuestion? = nil

    // True while you type in the island (Slack reply): keeps it open
    @Published var isEditingText: Bool = false

    // Measured content of the chat / notes: the island grows with it (up to a cap)
    @Published var chatContentHeight: CGFloat = 0
    @Published var notesContentHeight: CGFloat = 0
    /// Measured content of an approval / question card: a long command or a question
    /// with explained options grows the island so nothing is hidden.
    @Published var promptContentHeight: CGFloat = 0
    /// Permission requests waiting behind the one on screen (⏎ ⏎ to go through them).
    @Published var approvalsWaiting: Int = 0

    // Harvest picker: the project / task list is open (the island grows to show it)
    @Published var harvestListOpen: Bool = false

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

    /// Seconds before the open island folds once the pointer has left it.
    @Published var autoCloseDelay: TimeInterval = 3 {
        didSet { UserDefaults.standard.set(autoCloseDelay, forKey: "autoCloseDelay") }
    }

    var absenceInterval: TimeInterval = 3 * 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled"); hotkeyChanged() }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags"); hotkeyChanged() }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode"); hotkeyChanged() }
    }

    @Published var autoUpdate: Bool = true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }

    // Questions: hand the answers to Claude as text instead of filling the tool's answers
    @Published var questionCompatMode: Bool = false {
        didSet { UserDefaults.standard.set(questionCompatMode, forKey: "questionCompatMode") }
    }

    /// Concentration: Slack, Vercel and the Harvest reminder stay silent and never open
    /// the island (badges still show). Claude and meetings still come through.
    @Published var focusMode: Bool = false {
        didSet { UserDefaults.standard.set(focusMode, forKey: "focusMode") }
    }

    /// Concentration switched on by a meeting (camera in use or calendar), not by you.
    @Published var autoFocusActive: Bool = false
    @Published var autoFocusMeetings: Bool = true {
        didSet { UserDefaults.standard.set(autoFocusMeetings, forKey: "autoFocusMeetings") }
    }

    // The day around you (DayService)
    @Published var dayCard: DayCard? = nil
    @Published var morningGreeting: Bool = true {
        didSet { UserDefaults.standard.set(morningGreeting, forKey: "morningGreeting") }
    }
    @Published var eveningSummary: Bool = true {
        didSet { UserDefaults.standard.set(eveningSummary, forKey: "eveningSummary") }
    }
    @Published var eveningHour: Int = 18 {
        didSet { UserDefaults.standard.set(eveningHour, forKey: "eveningHour") }
    }

    @Published var harvestReminder: Bool = true {
        didSet { UserDefaults.standard.set(harvestReminder, forKey: "harvestReminder") }
    }

    // MARK: Services

    // GitHub (GithubPoller)
    @Published var githubStats: GitHubStats? = nil

    // Agenda (CalendarService)
    @Published var nextMeeting: Meeting? = nil
    @Published var calendarEnabled: Bool = true {
        didSet { UserDefaults.standard.set(calendarEnabled, forKey: "calendarEnabled") }
    }
    @Published var calendarLeadMinutes: Int = 5 {
        didSet { UserDefaults.standard.set(calendarLeadMinutes, forKey: "calendarLeadMinutes") }
    }

    // Vercel (VercelService)
    @Published var vercelDeployments: [VercelDeployment] = []
    @Published var vercelError: String? = nil

    // Slack (SlackService)
    @Published var slackMessages: [SlackMessage] = []
    @Published var slackUnread: Int = 0
    @Published var slackStatus: SlackStatus = .notConfigured

    // Harvest (HarvestService)
    @Published var harvestRunning: HarvestEntry? = nil
    /// Hours logged today on finished entries (the running one is added live).
    @Published var harvestTodayDone: TimeInterval = 0
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
        if let v = ud.object(forKey: "autoCloseDelay") as? Double  { autoCloseDelay = v }
        if let v = ud.object(forKey: "absenceInterval") as? Double { absenceInterval = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool     { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags") as? Int        { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode") as? Int         { hotkeyCode = UInt16(v) }
        if let v = ud.object(forKey: "autoUpdate") as? Bool        { autoUpdate = v }
        if let v = ud.object(forKey: "harvestReminder") as? Bool   { harvestReminder = v }
        if let v = ud.object(forKey: "focusMode") as? Bool         { focusMode = v }
        if let v = ud.object(forKey: "autoFocusMeetings") as? Bool { autoFocusMeetings = v }
        if let v = ud.object(forKey: "morningGreeting") as? Bool   { morningGreeting = v }
        if let v = ud.object(forKey: "eveningSummary") as? Bool    { eveningSummary = v }
        if let v = ud.object(forKey: "eveningHour") as? Int        { eveningHour = v }
        if let v = ud.object(forKey: "questionCompatMode") as? Bool { questionCompatMode = v }
        if let v = ud.object(forKey: "calendarEnabled") as? Bool   { calendarEnabled = v }
        if let v = ud.object(forKey: "calendarLeadMinutes") as? Int { calendarLeadMinutes = v }

        SoundEngine.shared.volume = Float(soundVolume)
        refreshPills()
        loaded = true
    }

    /// True once init has read the saved settings. An @Published property's didSet runs even
    /// when init assigns it, and must not reach AppState.shared then (it's still being built:
    /// that re-entry crashed the app at launch).
    private var loaded = false

    /// The Settings shortcut changed: register it again (AppDelegate does it at launch).
    private func hotkeyChanged() {
        guard loaded else { return }
        NotesHotKey.updateIslandHotKey(enabled: hotkeyEnabled, flags: hotkeyFlags, code: hotkeyCode)
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    var effectiveState: BotState {
        stateOverride ?? focusTask?.state ?? .idle
    }

    // MARK: - Task management

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
