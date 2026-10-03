import Foundation
import EventKit
import AppKit

// MARK: - Agenda
// Reads the Mac's Calendar app (every account it syncs, Google included) — no token.
// A few minutes before a meeting the island opens on it, with a "Rejoindre" button
// when the event carries a Meet / Zoom / Teams link.

struct Meeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let joinURL: URL?
    let calendarColor: String

    func timing(at now: Date = Date()) -> String {
        let f = TimeFormat.hourMinute
        let range = "\(f.string(from: start))–\(f.string(from: end))"
        if now >= start { return "En cours · jusqu'à \(f.string(from: end))" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "Dans \(minutes) min · \(range)" }
        if Calendar.current.isDateInToday(start) { return "Aujourd'hui · \(range)" }
        if Calendar.current.isDateInTomorrow(start) { return "Demain · \(range)" }
        f.dateFormat = "EEEE HH:mm"
        return f.string(from: start).capitalized
    }
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    static let pillId = "integration_calendar"

    private let store = EKEventStore()
    private var loop: Task<Void, Never>?
    private var reminded: Set<String> = []

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.refresh() }
        }
    }

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var isConfigured: Bool { hasAccess && AppState.shared.calendarEnabled }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if !AppState.shared.macAsleep { self?.refresh() }
                // Calendar changes arrive by notification; this only moves the reminder along
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    /// Asks macOS for calendar access (shows the system prompt the first time).
    func requestAccess() async -> Bool {
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestFullAccessToEvents { ok, _ in cont.resume(returning: ok) }
        }
        if granted {
            store.refreshSourcesIfNecessary()
            refresh()
        }
        AppState.shared.refreshPills()
        return granted
    }

    func refresh() {
        let state = AppState.shared
        guard isConfigured else { state.nextMeeting = nil; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600),
                                                 end: now.addingTimeInterval(36 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && $0.endDate > now && !declined($0) }
            .sorted { $0.startDate < $1.startDate }
        state.nextMeeting = events.first.map(meeting)
        remindIfNeeded()
    }

    private func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    private func meeting(_ e: EKEvent) -> Meeting {
        let color = e.calendar.flatMap { NSColor(cgColor: $0.cgColor) }?.hexString ?? PillColor.calendar
        let title = e.title ?? ""
        return Meeting(id: e.calendarItemIdentifier + "@\(e.startDate.timeIntervalSince1970)",
                       title: title.isEmpty ? "Sans titre" : title,
                       start: e.startDate, end: e.endDate,
                       location: e.location?.isEmpty == false ? e.location : nil,
                       joinURL: Self.joinURL(in: [e.url?.absoluteString, e.location, e.notes]),
                       calendarColor: color)
    }

    private static let joinRegex = try? NSRegularExpression(
        pattern: #"https://[^\s<>"]*(meet\.google\.com|zoom\.us/(j|my|w)/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|whereby\.com|webex\.com|around\.co)[^\s<>"]*"#,
        options: .caseInsensitive)

    /// First video-call link found in the event's URL, location or notes.
    static func joinURL(in fields: [String?]) -> URL? {
        guard let regex = joinRegex else { return nil }
        for field in fields.compactMap({ $0 }) {
            let range = NSRange(field.startIndex..., in: field)
            if let m = regex.firstMatch(in: field, range: range), let r = Range(m.range, in: field) {
                return URL(string: String(field[r]))
            }
        }
        return nil
    }

    // MARK: Island

    private func remindIfNeeded() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        guard let m = state.nextMeeting else {
            if state.tasks[idx].state != .idle { state.tasks[idx].state = .idle; state.tasks[idx].steps = [] }
            return
        }
        let now = Date()
        let lead = TimeInterval(state.calendarLeadMinutes * 60)
        let upcoming = m.start > now && m.start.timeIntervalSince(now) <= lead
        let ongoing = m.start <= now && now < m.end

        if upcoming || ongoing {
            state.tasks[idx].state = upcoming ? .question : .working
            state.tasks[idx].steps = [m.title]
        } else if state.tasks[idx].state != .idle {
            state.tasks[idx].state = .idle
            state.tasks[idx].steps = []
        }

        guard upcoming, !reminded.contains(m.id) else { return }
        reminded.insert(m.id)
        if state.focusId != Self.pillId || state.mode != .expanded { state.tasks[idx].pillBadge = .approval }
        SoundEngine.shared.play("approval")
        let busy = state.pendingApproval != nil || state.pendingQuestion != nil
            || (state.mode == .expanded && state.view != .overview)
        if !busy {
            state.focusId = Self.pillId
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
        }
    }

    func join(_ m: Meeting) {
        if let url = m.joinURL { NSWorkspace.shared.open(url) }
    }

    func openCalendar() {
        if let url = URL(string: "ical://") { NSWorkspace.shared.open(url) }
    }
}

private extension NSColor {
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// "14:30", built once (formatters are costly to create).
enum TimeFormat {
    nonisolated(unsafe) static let hourMinute: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()
}
