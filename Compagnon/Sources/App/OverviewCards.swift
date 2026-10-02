import SwiftUI
import AppKit

// MARK: - Layout
// The overview is two cards side by side. The character sits on the left of the
// left card, so card content starts at `contentLeading`. Boxes inside a card keep
// `IslandConst.cardInset` from its edges and use `IslandConst.innerRadius`, so every
// corner is concentric with the one around it.

enum CardLayout {
    static let leftCardWidth: CGFloat = 322
    static let contentLeading: CGFloat = 104
    static let headerTop: CGFloat = 10
}

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: IslandConst.contentInset) {
            ZStack(alignment: .topLeading) {
                CardBackground(wash: nil)
                if let task = state.focusTask {
                    FocusCard(task: task, state: state)
                }
                OpenButton { openTarget(state.focusTask) }
                    .padding(.top, 8)
                    .padding(.trailing, IslandConst.cardInset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: CardLayout.leftCardWidth)

            CardBackground(wash: nil) {
                AgentPillsView(state: state)
            }
        }
    }
}

/// What the left card shows for the focused pill.
private struct FocusCard: View {
    let task: AgentTask
    @ObservedObject var state: AppState

    var body: some View {
        switch task.id {
        case SlackService.pillId:   SlackCard(state: state)
        case HarvestService.pillId: HarvestCard(state: state)
        case "integration_github":  GitHubCard(state: state)
        case VercelService.pillId:  VercelCard(state: state)
        case CalendarService.pillId: MeetingCard(state: state)
        default:
            if task.state != .idle || !task.steps.isEmpty {
                SessionCard(task: task)
            } else {
                ClaudeIdleCard(task: task)
            }
        }
    }
}

// MARK: - Shared pieces

struct CardHeader: View {
    let color: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, CardLayout.headerTop)
        .padding(.leading, CardLayout.contentLeading)
        .padding(.trailing, 34)
    }
}

/// A box pinned to the bottom of the card, concentric with the card's corner.
struct InsetBox<Content: View>: View {
    var tint: Color = .white
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                    .fill(tint.opacity(0.07))
            )
            .padding(.leading, CardLayout.contentLeading - 10)
            .padding(.trailing, IslandConst.cardInset)
            .padding(.bottom, IslandConst.cardInset)
            .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

struct OpenButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(Color(hex: "#5F646D"))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.07))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Ouvrir")
    }
}

/// Small text button used inside cards.
struct CardLink: View {
    let title: String
    var icon: String? = nil
    var color: String = "#C5C8CD"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color(hex: color))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Claude Code

private struct SessionCard: View {
    let task: AgentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: task.color)).frame(width: 7, height: 7)
                Text(task.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Text(task.source == .agent ? "Agent" : "Claude Code")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if task.steps.count > 1 {
                    Text("\(min(task.stepIndex + 1, task.steps.count))/\(task.steps.count)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .fixedSize()
                }
            }
            .padding(.top, CardLayout.headerTop)
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, 34)

            TickerView(task: task)
                .frame(height: 44)
                .padding(.top, 6)
                .padding(.leading, CardLayout.contentLeading)
                .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ClaudeIdleCard: View {
    let task: AgentTask
    private var installed: Bool { HookServer.claudeHooksInstalled() }
    private var outdated: Bool { installed && HookServer.hooksNeedUpdate() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: "#D97757", title: "Claude Code",
                       subtitle: !installed ? "Hooks non installés" : (outdated ? "Hooks à mettre à jour" : "En attente"))
            InsetBox {
                HStack(spacing: 12) {
                    if outdated {
                        CardLink(title: "Mettre à jour les hooks…", color: "#F5A524") {
                            NotificationCenter.default.post(name: .openFullSettings, object: "claude")
                        }
                        Spacer(minLength: 0)
                    } else if installed {
                        Text("Rien en cours")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                        Spacer(minLength: 4)
                        CardLink(title: "Ouvrir Claude", icon: "arrow.up.right") { openClaude() }
                    } else {
                        CardLink(title: "Installer les hooks…", color: "#F5A524") {
                            NotificationCenter.default.post(name: .openFullSettings, object: "claude")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Slack

private struct SlackCard: View {
    @ObservedObject var state: AppState
    @State private var replying = false
    @State private var draft = ""
    @State private var sending = false
    @State private var note: String? = nil
    @FocusState private var fieldFocused: Bool

    private var latest: SlackMessage? { state.slackMessages.first }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: state.slackStatus == .connected ? "#E01E5A" : "#F5A524",
                       title: latest?.sender ?? "Slack",
                       subtitle: latest.map { "\($0.place) · \($0.timeAgo)" }
                                 ?? (state.slackStatus == .connected ? "En écoute" : state.slackStatus.label))

            if let msg = latest {
                Text(msg.text)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.top, CardLayout.headerTop + 20)
                    .padding(.leading, CardLayout.contentLeading)
                    .padding(.trailing, 14)
                    .opacity(replying ? 0 : 1)

                InsetBox(tint: replying ? .white : .clear) {
                    HStack(spacing: 8) {
                        if replying {
                            TextField("Répondre à \(msg.sender)…", text: $draft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(hex: "#F5F6F8"))
                                .focused($fieldFocused)
                                .onSubmit { send(to: msg) }
                                .onExitCommand { replying = false; draft = ""; state.isEditingText = false }
                            Button { send(to: msg) } label: {
                                Image(systemName: sending ? "ellipsis" : "paperplane.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(hex: "#36C5F0"))
                            }
                            .buttonStyle(.plain)
                            .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        } else {
                            CardLink(title: "Répondre", icon: "arrowshape.turn.up.left.fill", color: "#36C5F0") {
                                replying = true
                                state.isEditingText = true
                                NotificationCenter.default.post(name: .islandNeedsKeyboard, object: nil)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
                            }
                            CardLink(title: "Ouvrir dans Slack", color: "#8E939C") { SlackService.shared.open(msg) }
                            Spacer(minLength: 0)
                            if let note {
                                Text(note)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(Color(hex: "#22C55E"))
                            } else if state.slackMessages.count > 1 {
                                Text("+\(state.slackMessages.count - 1)")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(Color(hex: "#6B7079"))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                Text("Tes messages directs et tes mentions apparaîtront ici.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(2)
                    .padding(.top, CardLayout.headerTop + 22)
                    .padding(.leading, CardLayout.contentLeading)
                    .padding(.trailing, 14)
            }
        }
        .onAppear { SlackService.shared.markRead() }
        .onChange(of: state.slackUnread) { _, n in if n > 0 { SlackService.shared.markRead() } }
        .onChange(of: latest?.id) { _, _ in replying = false; draft = ""; state.isEditingText = false }
        .onDisappear { state.isEditingText = false }
    }

    private func send(to msg: SlackMessage) {
        let text = draft
        guard !sending, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sending = true
        Task { @MainActor in
            let ok = await SlackService.shared.reply(to: msg, text: text)
            sending = false
            if ok { draft = ""; replying = false; state.isEditingText = false }
            withAnimation { note = ok ? "Envoyé ✓" : "Échec de l'envoi" }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { note = nil }
        }
    }
}

// MARK: - Harvest

private struct HarvestCard: View {
    @ObservedObject var state: AppState
    @State private var busy = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let err = state.harvestError {
                CardHeader(color: "#F4505E", title: "Harvest", subtitle: err)
            } else if let entry = state.harvestRunning {
                runningView(entry)
            } else {
                idle
            }
        }
        .onAppear { HarvestService.shared.markSeen() }
    }

    // Timer running: project, task and a big clock — nothing else.
    private func runningView(_ entry: HarvestEntry) -> some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: "#FA5D00", title: entry.projectName)
            Text(entry.clientName.map { "\(entry.taskName) · \($0)" } ?? entry.taskName)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .padding(.top, CardLayout.headerTop + 18)
                .padding(.leading, CardLayout.contentLeading)
                .padding(.trailing, 34)

            InsetBox(tint: Color(hex: "#FA5D00")) {
                HStack(spacing: 10) {
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        Text(HarvestService.clock(entry.elapsed(at: tl.date)))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(Color(hex: "#FA5D00"))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    Button { state.view = .harvest } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#C5C8CD"))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Changer de tâche")
                    Button {
                        busy = true
                        Task { @MainActor in await HarvestService.shared.stop(); busy = false }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color(hex: "#FA5D00")))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .help("Arrêter le timer")
                }
            }
        }
    }

    // No timer: restart the last task in one click, or pick another.
    private var idle: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: "#6B7079", title: "Harvest", subtitle: "Aucun timer")
            if let last = state.harvestLast {
                Text("Dernier : \(last.label)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .padding(.top, CardLayout.headerTop + 18)
                    .padding(.leading, CardLayout.contentLeading)
                    .padding(.trailing, 34)
            }
            InsetBox {
                HStack(spacing: 14) {
                    if let last = state.harvestLast {
                        CardLink(title: "Relancer", icon: "play.fill", color: "#FA5D00") {
                            busy = true
                            Task { @MainActor in
                                await HarvestService.shared.start(projectId: last.projectId, taskId: last.taskId, notes: last.notes)
                                busy = false
                            }
                        }
                        .disabled(busy)
                    }
                    CardLink(title: "Nouveau timer", icon: "plus", color: "#C5C8CD") { state.view = .harvest }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Full-width card: pick the project (grouped by client), the task, an optional note, start.
struct HarvestPickerView: View {
    @ObservedObject var state: AppState
    @State private var projectId: Int? = nil
    @State private var taskId: Int? = nil
    @State private var notes = ""
    @State private var busy = false
    @FocusState private var notesFocused: Bool

    private var project: HarvestProject? { state.harvestProjects.first { $0.id == projectId } }
    private var task: HarvestTask? { project?.tasks.first { $0.id == taskId } }
    private struct ClientGroup: Identifiable {
        let name: String
        let projects: [HarvestProject]
        var id: String { name }
    }

    private var clients: [ClientGroup] {
        Dictionary(grouping: state.harvestProjects, by: { $0.clientName })
            .map { ClientGroup(name: $0.key, projects: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(state.harvestRunning == nil ? "Nouveau timer" : "Changer de tâche")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    if state.harvestProjects.isEmpty {
                        ProgressView().controlSize(.mini)
                        Text("Chargement des projets…")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    PickerField(label: project.map { "\($0.clientName) · \($0.name)" } ?? "Projet") {
                        ForEach(clients) { client in
                            Section(client.name) {
                                ForEach(client.projects) { p in
                                    Button(p.name) {
                                        projectId = p.id
                                        taskId = p.tasks.count == 1 ? p.tasks[0].id : nil
                                    }
                                }
                            }
                        }
                    }
                    PickerField(label: task?.name ?? "Tâche") {
                        ForEach(project?.tasks ?? []) { t in
                            Button(t.name) { taskId = t.id }
                        }
                    }
                    .disabled(project == nil)
                    .frame(width: 150)
                }
                HStack(spacing: 8) {
                    TextField("Note (facultatif)", text: $notes)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .focused($notesFocused)
                        .onSubmit { start() }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                            .fill(Color.white.opacity(0.07)))
                    Button("Annuler") { state.view = .overview }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .keyboardShortcut(.cancelAction)
                    Button(action: start) {
                        HStack(spacing: 5) {
                            Image(systemName: busy ? "ellipsis" : "play.fill").font(.system(size: 9, weight: .bold))
                            Text("Démarrer")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                            .fill(Color(hex: "#FA5D00").opacity(task == nil ? 0.35 : 1)))
                    }
                    .buttonStyle(.plain)
                    .disabled(task == nil || busy)
                }
            }
            .padding(.leading, 96)
            .padding(.trailing, IslandConst.cardInset)
            .padding(.vertical, IslandConst.cardInset)
        }
        .onAppear {
            Task { await HarvestService.shared.loadProjects() }
            // Preselect what you were doing last
            let base = state.harvestRunning ?? state.harvestLast
            if projectId == nil, let base {
                projectId = base.projectId
                taskId = base.taskId
            }
        }
    }

    private func start() {
        guard let projectId, let taskId, !busy else { return }
        busy = true
        Task { @MainActor in
            await HarvestService.shared.start(projectId: projectId, taskId: taskId,
                                              notes: notes.trimmingCharacters(in: .whitespaces))
            busy = false
            notes = ""
            state.view = .overview
        }
    }
}

/// A menu that looks like a field: label on the left, chevron on the right.
private struct PickerField<Items: View>: View {
    let label: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#E5E7EB"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius).fill(Color.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

// MARK: - Agenda

private struct MeetingCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let m = state.nextMeeting {
                CardHeader(color: m.calendarColor, title: m.title)
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    Text(m.timing(at: tl.date))
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1)
                }
                .padding(.top, CardLayout.headerTop + 18)
                .padding(.leading, CardLayout.contentLeading)
                .padding(.trailing, 34)
                InsetBox(tint: Color(hex: "#7C5CFF")) {
                    HStack(spacing: 10) {
                        if m.joinURL != nil {
                            Button { CalendarService.shared.join(m) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "video.fill").font(.system(size: 9, weight: .bold))
                                    Text("Rejoindre")
                                }
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius - 2)
                                    .fill(Color(hex: "#7C5CFF")))
                            }
                            .buttonStyle(.plain)
                        }
                        if let loc = m.location, m.joinURL == nil || !loc.lowercased().hasPrefix("http") {
                            Text(loc)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#C5C8CD"))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        CardLink(title: "Calendrier", color: "#8E939C") { CalendarService.shared.openCalendar() }
                    }
                }
            } else {
                CardHeader(color: "#7C5CFF", title: "Agenda", subtitle: "Rien de prévu")
                Text("Aucune réunion dans les prochaines 36 h.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.top, CardLayout.headerTop + 22)
                    .padding(.leading, CardLayout.contentLeading)
            }
        }
    }
}

// MARK: - Vercel

private struct VercelCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let err = state.vercelError {
                CardHeader(color: "#F4505E", title: "Vercel", subtitle: err)
            } else if let d = state.vercelDeployments.first {
                CardHeader(color: d.statusColor, title: d.projectName,
                           subtitle: [d.branch, d.timeAgo].compactMap { $0 }.joined(separator: " · "))
                if let msg = d.commitMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, CardLayout.headerTop + 18)
                        .padding(.leading, CardLayout.contentLeading)
                        .padding(.trailing, 34)
                }
                InsetBox(tint: Color(hex: d.statusColor)) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: d.statusColor)).frame(width: 7, height: 7)
                        Text(d.statusLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: d.statusColor))
                        Spacer(minLength: 4)
                        if state.vercelDeployments.count > 1 {
                            let others = state.vercelDeployments.dropFirst().prefix(3)
                            HStack(spacing: 3) {
                                ForEach(Array(others)) { o in
                                    Circle().fill(Color(hex: o.statusColor).opacity(0.8)).frame(width: 5, height: 5)
                                }
                            }
                            .help("Déploiements précédents")
                        }
                        if !d.url.isEmpty {
                            CardLink(title: "Ouvrir", icon: "arrow.up.right") {
                                if let u = URL(string: d.url) { NSWorkspace.shared.open(u) }
                            }
                        }
                    }
                }
            } else {
                CardHeader(color: "#E5E7EB", title: "Vercel", subtitle: "Chargement…")
            }
        }
    }
}

// MARK: - GitHub

private struct GitHubCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: "#8B949E", title: "GitHub", subtitle: state.githubStats == nil ? "Chargement…" : "Aperçu")
            if let stats = state.githubStats {
                InsetBox {
                    HStack(spacing: 16) {
                        stat(icon: "star.fill", color: "#F5A524", value: format(stats.totalStars), label: "étoiles")
                        stat(icon: "square.stack.fill", color: "#8E939C", value: "\(stats.totalRepos)", label: "dépôts")
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func stat(icon: String, color: String, value: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(Color(hex: color))
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "#E5E7EB"))
                .monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
        }
    }

    private func format(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

// MARK: - ↗ targets

/// Opens the app or page behind a pill.
@MainActor
func openTarget(_ task: AgentTask?) {
    guard let task else { return }
    switch task.id {
    case SlackService.pillId:
        SlackService.shared.open(AppState.shared.slackMessages.first)
    case HarvestService.pillId:
        if let url = URL(string: "https://id.getharvest.com/harvest") { NSWorkspace.shared.open(url) }
    case "integration_github":
        if let url = URL(string: "https://github.com") { NSWorkspace.shared.open(url) }
    case CalendarService.pillId:
        if let m = AppState.shared.nextMeeting, m.joinURL != nil { CalendarService.shared.join(m) }
        else { CalendarService.shared.openCalendar() }
    case VercelService.pillId:
        let target = AppState.shared.vercelDeployments.first.flatMap { URL(string: $0.url) }
            ?? URL(string: "https://vercel.com/dashboard")
        if let target { NSWorkspace.shared.open(target) }
    default:
        openClaude()
    }
}

/// Brings Claude (desktop app, VS Code or a terminal) to the front.
@MainActor
func openClaude() {
    let candidates = ["com.anthropic.claudefordesktop", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                      "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]
    for id in candidates {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }) {
            app.activate(options: .activateIgnoringOtherApps)
            return
        }
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}
