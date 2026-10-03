import Foundation
import CoreMediaIO

// MARK: - The day around you
// - Good morning: the first time you're at the Mac before noon, the island says
//   hello with your first meeting and the last Harvest task, ready to relaunch.
// - Evening summary: after `eveningHour`, one line on your day (Harvest time,
//   Claude sessions finished, Slack messages).
// - Concentration in meetings: on while your camera is in use or a calendar
//   meeting is going on, off again afterwards (unless you switched it yourself).

enum DayCard: Equatable { case morning, evening }

@MainActor
final class DayService {
    static let shared = DayService()

    private var loop: Task<Void, Never>?
    private var focusLoop: Task<Void, Never>?
    /// You turned concentration off during a meeting: leave it off until the meeting ends.
    private var userOverrodeMeeting = false
    private var wasInMeeting = false

    private init() {}

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.tick()
            }
        }
        focusLoop = Task { [weak self] in
            while !Task.isCancelled {
                if !AppState.shared.macAsleep { self?.checkMeeting() }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    // MARK: Counters (reset every day)

    private struct Stats: Codable { var day: String; var claude = 0; var slack = 0 }

    private var stats: Stats {
        get {
            let today = HarvestService.today()
            if let data = UserDefaults.standard.data(forKey: "dayStats"),
               let s = try? JSONDecoder().decode(Stats.self, from: data), s.day == today { return s }
            return Stats(day: today)
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "dayStats") }
    }

    func countClaudeSession() { var s = stats; s.claude += 1; stats = s }
    func countSlackMessage()  { var s = stats; s.slack += 1; stats = s }
    var claudeSessionsToday: Int { stats.claude }
    var slackMessagesToday: Int { stats.slack }

    /// Harvest time logged today, including the running timer.
    var harvestToday: TimeInterval {
        let state = AppState.shared
        return state.harvestTodayDone + (state.harvestRunning?.elapsed(at: Date()) ?? 0)
    }

    // MARK: Morning / evening

    private func tick() {
        let state = AppState.shared
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let today = HarvestService.today()
        let active = now.timeIntervalSince(state.lastMouseMove) < 120 && state.isPresent
        let busy = state.pendingApproval != nil || state.pendingQuestion != nil || state.isEditingText
            || (state.mode == .expanded && state.view != .overview && state.view != .empty)
        guard active, !busy else { return }

        let ud = UserDefaults.standard
        if state.morningGreeting, (5..<12).contains(hour), ud.string(forKey: "morningShown") != today {
            ud.set(today, forKey: "morningShown")
            show(.morning)
        } else if state.eveningSummary, hour >= state.eveningHour, ud.string(forKey: "eveningShown") != today {
            ud.set(today, forKey: "eveningShown")
            show(.evening)
        }
    }

    func show(_ card: DayCard) {
        AppState.shared.dayCard = card
        SoundEngine.shared.play("peek")
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.day)
    }

    // MARK: Concentration in meetings

    private func checkMeeting() {
        let state = AppState.shared
        guard state.autoFocusMeetings else {
            if state.autoFocusActive { state.autoFocusActive = false; state.focusMode = false }
            return
        }
        let calendarMeeting: Bool = {
            guard let m = state.nextMeeting else { return false }
            let now = Date()
            return m.start <= now && now < m.end
        }()
        let inMeeting = Self.cameraInUse() || calendarMeeting

        if inMeeting && !wasInMeeting { userOverrodeMeeting = false }
        wasInMeeting = inMeeting

        if inMeeting {
            if state.autoFocusActive && !state.focusMode { userOverrodeMeeting = true; state.autoFocusActive = false }
            if !state.focusMode && !userOverrodeMeeting {
                state.focusMode = true
                state.autoFocusActive = true
            }
        } else if state.autoFocusActive {
            state.autoFocusActive = false
            state.focusMode = false
        }
    }

    /// True while any camera is in use by some app (a video call), no permission needed.
    nonisolated static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == noErr else { return false }
        for device in devices {
            var running: UInt32 = 0
            var runAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }
}
