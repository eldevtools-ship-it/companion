import SwiftUI
import AppKit

// MARK: - Layout
// The overview is two cards side by side. The character sits on the left of the
// left card, so card content starts at `CardLayout.contentLeading`. Boxes inside a
// card keep `IslandConst.cardInset` from its edges and use `IslandConst.innerRadius`,
// so every corner is concentric with the one around it.

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Two equal halves; the gap between them equals the island's side and bottom margins
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
            .frame(maxWidth: .infinity)

            CardBackground(wash: nil) {
                AgentPillsView(state: state)
            }
            .frame(maxWidth: .infinity)
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

/// A box pinned to the bottom of the card, concentric with the card's corner. Its left
/// edge lines up with the text above it, so it keeps the same gap from the character.
struct InsetBox<Content: View>: View {
    var tint: Color = .white
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                    .fill(tint.opacity(0.07))
            )
            .padding(.leading, CardLayout.contentLeading)
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
        .pointingHand()
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
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
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Color(hex: "#6B7079"))
                        .fixedSize()
                }
            }
            .padding(.top, CardLayout.headerTop)
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, 34)

            Spacer(minLength: 0)

            // Steps sit at the bottom of the card, like the boxes of the other cards
            TickerView(task: task)
                .frame(height: 44)
                .padding(.leading, CardLayout.contentLeading)
                .padding(.trailing, 12)
                .padding(.bottom, IslandConst.cardInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ClaudeIdleCard: View {
    let task: AgentTask
    private var installed: Bool { HookServer.claudeHooksInstalled() }
    private var outdated: Bool { installed && HookServer.hooksNeedUpdate() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: PillColor.claude, title: "Claude Code",
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
    @State private var shown = 0          // 0 = latest; ‹ › walk through the others
    @FocusState private var fieldFocused: Bool

    private var latest: SlackMessage? {
        let list = state.slackMessages
        guard !list.isEmpty else { return nil }
        return list[min(shown, list.count - 1)]
    }

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
                    .padding(.top, CardLayout.secondLineTop)
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
                                .textCursor()
                            Button { send(to: msg) } label: {
                                Image(systemName: sending ? "ellipsis" : "paperplane.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(hex: "#36C5F0"))
                            }
                            .buttonStyle(.plain)
                            .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                            .pointingHand()
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
                                pager
                            }
                        }
                    }
                }
            } else {
                Text("Tes messages directs et tes mentions apparaîtront ici.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(2)
                    .padding(.top, CardLayout.secondLineTop)
                    .padding(.leading, CardLayout.contentLeading)
                    .padding(.trailing, 14)
            }
        }
        .onAppear { SlackService.shared.markRead() }
        .onChange(of: state.slackUnread) { _, n in if n > 0 { SlackService.shared.markRead() } }
        .onChange(of: state.slackMessages.first?.id) { _, _ in
            shown = 0; replying = false; draft = ""; state.isEditingText = false
        }
        .onDisappear { state.isEditingText = false }
    }

    /// ‹ 2/5 › — older messages are one click away.
    private var pager: some View {
        let count = state.slackMessages.count
        let index = min(shown, count - 1)
        return HStack(spacing: 2) {
            pageButton("chevron.left", enabled: index + 1 < count) { shown = index + 1 }
            Text("\(index + 1)/\(count)")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(Color(hex: "#8E939C"))
                .monospacedDigit()
                .frame(minWidth: 26)
            pageButton("chevron.right", enabled: index > 0) { shown = index - 1 }
        }
    }

    private func pageButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color.white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointingHand()
        .help(icon == "chevron.left" ? "Message précédent" : "Message suivant")
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
            Text(entry.clientName.map { "\($0) / \(entry.taskName)" } ?? entry.taskName)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .padding(.top, CardLayout.secondLineTop)
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
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .pointingHand()
                    .help("Changer de tâche")
                    Button {
                        busy = true
                        Task { @MainActor in await HarvestService.shared.stop(); busy = false }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color(hex: "#FA5D00")))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .pointingHand()
                    .help("Arrêter le timer")
                }
            }
        }
    }

    // No timer: restart the last task in one click, or pick another.
    private var idle: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: "#6B7079", title: "Harvest")
            if let last = state.harvestLast {
                Text("Dernier : \(last.label)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .padding(.top, CardLayout.secondLineTop)
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
/// The project and task lists open inside the island (it grows downwards), no system menu.
struct HarvestPickerView: View {
    @ObservedObject var state: AppState
    @State private var projectId: Int? = nil
    @State private var taskId: Int? = nil
    @State private var notes = ""
    @State private var busy = false
    @State private var list: ListMode = .closed
    @State private var filter = ""
    @FocusState private var notesFocused: Bool
    @FocusState private var filterFocused: Bool

    private enum ListMode { case closed, project, task }

    private let fieldHeight: CGFloat = 30
    private static let orange = "#FA5D00"
    /// Two 30 pt rows 10 pt apart, centred in the closed card.
    private static let topPadding: CGFloat = {
        let card = (IslandConst.viewLayouts[.harvest]?.height ?? 160) - IslandConst.cardTop - IslandConst.contentInset
        return ((card - 70) / 2).rounded()
    }()

    private var project: HarvestProject? { state.harvestProjects.first { $0.id == projectId } }
    private var task: HarvestTask? { project?.tasks.first { $0.id == taskId } }

    private struct ClientGroup: Identifiable {
        let name: String
        let projects: [HarvestProject]
        var id: String { name }
    }

    private var clients: [ClientGroup] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? state.harvestProjects : state.harvestProjects.filter {
            $0.name.lowercased().contains(q) || $0.clientName.lowercased().contains(q)
        }
        return Dictionary(grouping: shown, by: { $0.clientName })
            .map { ClientGroup(name: $0.key, projects: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 10) {
                fieldsRow
                // Plain cross-fades only: scale/clip transitions render through an
                // offscreen layer that flashes black in the transparent island window.
                if list == .closed {
                    noteRow.transition(.opacity)
                } else {
                    listPanel.transition(.opacity)
                }
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, IslandConst.cardInset)
            // Same top in both modes (centred in the closed card), so nothing jumps
            .padding(.top, Self.topPadding)
            .padding(.bottom, IslandConst.cardInset + 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { if state.view == .harvest { prepare() } }
        .onChange(of: state.view) { _, v in
            if v == .harvest { prepare() } else if list != .closed { show(.closed) }
        }
        .onDisappear { if list != .closed { show(.closed) } }
    }

    // [Nouveau timer] [Projet ⌄] [Tâche ⌄]
    private var fieldsRow: some View {
        HStack(spacing: 8) {
            Text(state.harvestRunning == nil ? "Nouveau timer" : "Changer de tâche")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .fixedSize()
                .padding(.trailing, 4)
            FieldButton(value: project.map { "\($0.clientName) / \($0.name)" }, placeholder: "Projet",
                        open: list == .project, height: fieldHeight,
                        loading: state.harvestProjects.isEmpty) {
                show(list == .project ? .closed : .project)
            }
            FieldButton(value: task?.name, placeholder: "Tâche",
                        open: list == .task, height: fieldHeight) {
                show(list == .task ? .closed : .task)
            }
            .frame(width: 150)
            .disabled(project == nil)
            .opacity(project == nil ? 0.5 : 1)
        }
    }

    // [Note (facultatif)…] Annuler [▶ Démarrer]
    private var noteRow: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if notes.isEmpty {
                    Text("Note (facultatif)")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.48))
                        .allowsHitTesting(false)
                }
                TextField("", text: $notes)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .focused($notesFocused)
                    .onSubmit { start() }
            }
            .padding(.horizontal, 10)
            .frame(height: fieldHeight)
            .background(FieldBackground(highlighted: notesFocused))
            .textCursor()

            Button("Annuler") { state.view = .overview }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.6))
                .padding(.horizontal, 6)
                .keyboardShortcut(.cancelAction)
                .pointingHand()

            Button(action: start) {
                HStack(spacing: 5) {
                    Image(systemName: busy ? "ellipsis" : "play.fill").font(.system(size: 9, weight: .bold))
                    Text("Démarrer")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 14)
                .frame(height: fieldHeight)
                .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                    .fill(Color(hex: Self.orange).opacity(task == nil ? 0.35 : 1)))
            }
            .buttonStyle(.plain)
            .disabled(task == nil || busy)
            .pointingHand()
        }
    }

    // The open list: projects grouped by client (with a filter), or the project's tasks.
    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if list == .project {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.48))
                    ZStack(alignment: .leading) {
                        if filter.isEmpty {
                            Text("Chercher un projet ou un client")
                                .font(.system(size: 11.5))
                                .foregroundColor(Color.white.opacity(0.48))
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $filter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .focused($filterFocused)
                            .onSubmit {
                                if let only = clients.first?.projects.first, clients.count == 1,
                                   clients[0].projects.count == 1 { pick(only) }
                            }
                    }
                    .textCursor()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    if list == .project {
                        if clients.isEmpty {
                            Text(state.harvestProjects.isEmpty ? "Chargement des projets…" : "Aucun projet trouvé")
                                .font(.system(size: 11.5))
                                .foregroundColor(Color.white.opacity(0.48))
                                .padding(10)
                        }
                        ForEach(clients) { client in
                            Text(client.name.uppercased())
                                .font(.system(size: 9.5, weight: .semibold))
                                .kerning(0.4)
                                .foregroundColor(Color.white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 3)
                            ForEach(client.projects) { p in
                                ListRow(title: p.name, selected: p.id == projectId) { pick(p) }
                            }
                        }
                    } else {
                        ForEach(project?.tasks ?? []) { t in
                            ListRow(title: t.name, selected: t.id == taskId) {
                                taskId = t.id
                                show(.closed)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: IslandConst.innerRadius).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func pick(_ p: HarvestProject) {
        let changed = p.id != projectId
        projectId = p.id
        if p.tasks.count == 1 {
            taskId = p.tasks[0].id
            show(.closed)
        } else {
            if changed { taskId = nil }
            show(.task)
        }
    }

    private func show(_ mode: ListMode) {
        withAnimation(.easeInOut(duration: 0.18)) { list = mode }
        filter = ""
        let grow = mode != .closed
        if grow {
            if !state.harvestListOpen { state.harvestListOpen = true }
        } else if state.harvestListOpen {
            // Let the list fade out before the island folds back up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                if list == .closed { state.harvestListOpen = false }
            }
        }
        if mode == .project {
            NotificationCenter.default.post(name: .islandNeedsKeyboard, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { filterFocused = true }
        }
    }

    /// Fresh form each time the picker opens, preset on what you were doing last.
    private func prepare() {
        Task { await HarvestService.shared.loadProjects() }
        let base = state.harvestRunning ?? state.harvestLast
        projectId = base?.projectId
        taskId = base?.taskId
        notes = ""
        if list != .closed { show(.closed) }
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

/// Field-looking button that opens a list: value (or placeholder) and a white chevron.
private struct FieldButton: View {
    let value: String?
    let placeholder: String
    let open: Bool
    let height: CGFloat
    var loading: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(value ?? placeholder)
                    .font(.system(size: 11.5, weight: value == nil ? .regular : .medium))
                    .foregroundColor(value == nil ? Color.white.opacity(0.48) : Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(FieldBackground(highlighted: open || hovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .pointingHand()
    }
}

private struct FieldBackground: View {
    let highlighted: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: IslandConst.innerRadius)
            .fill(Color.white.opacity(highlighted ? 0.11 : 0.08))
            .overlay(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                .stroke(Color.white.opacity(highlighted ? 0.18 : 0.08), lineWidth: 1))
    }
}

/// One row in the island list (project or task).
private struct ListRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(hex: "#FA5D00"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius - 2)
                .fill(Color.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .pointingHand()
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
                .padding(.top, CardLayout.secondLineTop)
                .padding(.leading, CardLayout.contentLeading)
                .padding(.trailing, 34)
                InsetBox(tint: Color(hex: PillColor.calendar)) {
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
                                    .fill(Color(hex: PillColor.calendar)))
                            }
                            .buttonStyle(.plain)
                            .pointingHand()
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
                CardHeader(color: PillColor.calendar, title: "Agenda", subtitle: "Rien de prévu")
                Text("Aucune réunion dans les prochaines 36 h.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.top, CardLayout.secondLineTop)
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
                           subtitle: [d.account, d.branch, d.timeAgo].compactMap { $0 }.joined(separator: " · "))
                if let msg = d.commitMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, CardLayout.secondLineTop)
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
                                if let u = safeWebURL(d.url) { NSWorkspace.shared.open(u) }
                            }
                        }
                    }
                }
            } else {
                CardHeader(color: PillColor.vercel, title: "Vercel", subtitle: "Chargement…")
            }
        }
    }
}

// MARK: - GitHub

private struct GitHubCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardHeader(color: PillColor.github, title: "GitHub", subtitle: state.githubStats == nil ? "Chargement…" : "Aperçu")
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
                .font(.system(size: 13, weight: .semibold, design: .rounded))
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
        returnToSession(task)
    }
}

/// Back to where this Claude session runs: its folder's window in VS Code or Cursor
/// when one is open, otherwise the Claude app or a terminal.
@MainActor
func returnToSession(_ task: AgentTask?) {
    if let cwd = task?.sessionCwd, !cwd.isEmpty {
        let editors = [("com.microsoft.VSCode", "vscode"), ("com.todesktop.230313mzl4w4u92", "cursor")]
        for (bundleId, scheme) in editors
        where NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleId }) {
            var comps = URLComponents()
            comps.scheme = scheme
            comps.host = "file"
            comps.path = cwd
            if let url = comps.url {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
    openClaude()
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
