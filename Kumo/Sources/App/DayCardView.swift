import SwiftUI

// MARK: - Good morning / evening summary card

struct DayCardView: View {
    @ObservedObject var state: AppState
    @State private var busy = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            switch state.dayCard ?? .morning {
            case .morning: morning
            case .evening: evening
            }
        }
    }

    // "Bonjour !" · first meeting · relaunch yesterday's task
    private var morning: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: PillColor.calendar, title: "Bonjour !",
                       subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))))
            Text(meetingLine)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1)
                .padding(.top, CardLayout.secondLineTop)
                .padding(.leading, CardLayout.contentLeading)
                .padding(.trailing, 14)
            InsetBox {
                HStack(spacing: 14) {
                    if let last = state.harvestLast, state.harvestRunning == nil {
                        CardLink(title: "Relancer \(last.label)", icon: "play.fill", color: PillColor.harvest) {
                            busy = true
                            Task { @MainActor in
                                await HarvestService.shared.start(projectId: last.projectId, taskId: last.taskId, notes: last.notes)
                                busy = false
                                state.view = .overview
                            }
                        }
                        .disabled(busy)
                    }
                    if !NotesStore.shared.notes.isEmpty {
                        CardLink(title: "Mes notes (\(NotesStore.shared.notes.count))", icon: "note.text", color: "#C5C8CD") {
                            state.view = .notes
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var meetingLine: String {
        guard let m = state.nextMeeting, Calendar.current.isDateInToday(m.start) else {
            return "Aucune réunion aujourd'hui."
        }
        return "Première réunion : \(m.title) à \(TimeFormat.hourMinute.string(from: m.start))"
    }

    // "Ta journée" · Harvest / Claude / Slack
    private var evening: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: "#A78BFA", title: "Ta journée", subtitle: "Bonne soirée")
            HStack(spacing: 18) {
                stat(value: Self.hours(DayService.shared.harvestToday), label: "Harvest", color: PillColor.harvest)
                stat(value: "\(DayService.shared.claudeSessionsToday)", label: "sessions Claude", color: PillColor.claude)
                stat(value: "\(DayService.shared.slackMessagesToday)", label: "messages Slack", color: PillColor.slack)
            }
            .padding(.top, CardLayout.secondLineTop + 2)
            .padding(.leading, CardLayout.contentLeading)
            if state.harvestRunning != nil {
                InsetBox(tint: Color(hex: PillColor.harvest)) {
                    HStack(spacing: 10) {
                        Text("Le timer Harvest tourne encore.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#C5C8CD"))
                        Spacer(minLength: 4)
                        CardLink(title: "Arrêter", icon: "stop.fill", color: PillColor.harvest) {
                            busy = true
                            Task { @MainActor in await HarvestService.shared.stop(); busy = false }
                        }
                        .disabled(busy)
                    }
                }
            }
        }
    }

    /// "6 h 12", "45 min"
    static func hours(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(m) min" : String(format: "%d h %02d", m / 60, m % 60)
    }

    private func stat(value: String, label: String, color: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Color(hex: "#F5F6F8"))
            HStack(spacing: 4) {
                Circle().fill(Color(hex: color)).frame(width: 5, height: 5)
                Text(label).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
            }
        }
    }
}
