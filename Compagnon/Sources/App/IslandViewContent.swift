import SwiftUI

// MARK: - Dispatch view content by IslandView

struct IslandViewContent: View {
    let view: IslandView
    @ObservedObject var state: AppState

    var body: some View {
        switch view {
        case .overview:  OverviewView(state: state)
        case .empty:     EmptyStateView(state: state)
        case .approval:  ApprovalView(state: state)
        case .question:  QuestionView(state: state)
        case .error:     ErrorView(state: state)
        case .finished:  FinishedView(state: state)
        case .confused:  ConfusedView()
        case .note:      NoteView(state: state)
        case .harvest:   HarvestPickerView(state: state)
        case .settings:  SettingsIslandView(state: state)
        case .greeting:  EmptyView()  // GreetingCanvasView overlaid in IslandRootView
        }
    }
}

// MARK: - Empty

struct EmptyStateView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Rien en cours pour l'instant.")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Je te préviens dès que Claude, Slack ou Harvest a besoin de toi.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#9398A1"))
                }
                Spacer()
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, 18)
        }
    }
}

// MARK: - Approval

struct ApprovalView: View {
    @ObservedObject var state: AppState

    var approval: ApprovalInfo? { state.pendingApproval }

    var body: some View {
        ZStack {
            CardBackground(wash: .amber)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask, label: "demande une autorisation")
                CodeBlock(text: approval?.command ?? approval?.tool ?? "…")
                HStack(spacing: 8) {
                    SecondaryButton("Refuser", kbd: "esc") {
                        HookServer.shared.sendApprovalDecision("deny")
                    }
                    PrimaryButton("Autoriser", kbd: "⏎") {
                        HookServer.shared.sendApprovalDecision("allow")
                    }
                    // Codex rejects updatedPermissions, so "Always" is not offered
                    if approval?.pillId != "agent_codex" {
                        SecondaryButton("Toujours", kbd: "⌘⏎") {
                            HookServer.shared.sendApprovalDecision("always")
                        }
                    }
                }
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Question

struct QuestionView: View {
    @ObservedObject var state: AppState
    @State private var index = 0
    @State private var answers: [String: Any] = [:]
    @State private var picked: Set<String> = []
    @State private var typing = false
    @State private var custom = ""
    @FocusState private var customFocused: Bool

    private var question: ClaudeQuestion? { state.pendingQuestion }
    private var item: ClaudeQuestion.Item? {
        guard let q = question, index < q.items.count else { return nil }
        return q.items[index]
    }

    var body: some View {
        ZStack {
            CardBackground(wash: .cyan)
            if let q = question, let item {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(q.items.count > 1 ? "Claude te demande · \(index + 1)/\(q.items.count)" : "Claude te demande")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                        if !item.header.isEmpty {
                            Text(item.header)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(hex: "#22D3EE"))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color(hex: "#22D3EE").opacity(0.12)))
                        }
                        Spacer(minLength: 4)
                        CardLink(title: typing ? "Choix" : "Autre…", color: "#C5C8CD") {
                            typing.toggle()
                            if typing {
                                NotificationCenter.default.post(name: .islandNeedsKeyboard, object: nil)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { customFocused = true }
                            }
                        }
                        CardLink(title: "Dans Claude", color: "#8E939C") {
                            HookServer.shared.finishQuestion(answers: nil, note: nil)
                        }
                        .help("Laisser Claude poser la question lui-même")
                    }
                    Text(item.question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if typing {
                        HStack(spacing: 8) {
                            TextField("Ta réponse…", text: $custom)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .focused($customFocused)
                                .onSubmit { answer(custom) }
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                                    .fill(Color.white.opacity(0.07)))
                                .textCursor()
                            choiceButton("Envoyer", prominent: true,
                                         disabled: custom.trimmingCharacters(in: .whitespaces).isEmpty) { answer(custom) }
                        }
                    } else {
                        HStack(spacing: 6) {
                            ForEach(Array(item.options.enumerated()), id: \.element.label) { i, opt in
                                let on = picked.contains(opt.label)
                                choiceButton(opt.label, prominent: on, key: i < 9 ? "\(i + 1)" : nil) {
                                    if item.multiSelect {
                                        if on { picked.remove(opt.label) } else { picked.insert(opt.label) }
                                    } else {
                                        answer(opt.label)
                                    }
                                }
                                .help(opt.description)
                            }
                            if item.multiSelect {
                                Spacer(minLength: 4)
                                choiceButton("Valider", prominent: true, disabled: picked.isEmpty) {
                                    let labels = item.options.map(\.label).filter { picked.contains($0) }
                                    answer(labels)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, CardLayout.contentLeading)
                .padding(.trailing, IslandConst.cardInset + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: state.pendingQuestion) { _, _ in reset() }
        // 1…9 picks an option, ⏎ validates a multiple choice (IslandWindowController)
        .onReceive(NotificationCenter.default.publisher(for: .questionShortcut)) { note in
            guard let n = note.object as? Int, let item, !typing else { return }
            if n == 0 {
                if item.multiSelect && !picked.isEmpty {
                    answer(item.options.map(\.label).filter { picked.contains($0) })
                }
                return
            }
            guard n - 1 < item.options.count else { return }
            let label = item.options[n - 1].label
            if item.multiSelect {
                if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
            } else {
                answer(label)
            }
        }
    }

    private func choiceButton(_ title: String, prominent: Bool, disabled: Bool = false, key: String? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let key {
                    Text(key)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .opacity(0.5)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(prominent ? Color(hex: "#0B0C0E") : Color(hex: "#F1F2F4"))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                .fill(prominent ? Color(hex: "#22D3EE") : Color.white.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .pointingHand()
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    /// Records the answer to the current question, then moves on or sends everything.
    private func answer(_ value: Any) {
        guard let q = question, let item else { return }
        if let text = value as? String, text.trimmingCharacters(in: .whitespaces).isEmpty { return }
        answers[item.question] = value
        if index + 1 < q.items.count {
            index += 1
            picked = []
            custom = ""
            typing = false
        } else {
            HookServer.shared.finishQuestion(answers: answers, note: nil)
        }
    }

    private func reset() {
        index = 0
        answers = [:]
        picked = []
        custom = ""
        typing = false
    }
}

// MARK: - Error

struct ErrorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: .red)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask, label: "n8n")
                Text("Workflow arrêté.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Le nœud Gmail a expiré après 30 s. Réessaie ou ouvre n8n.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#FF8D97"))
                HStack(spacing: 8) {
                    PrimaryButton("Réessayer") { /* retry */ }
                    SecondaryButton("Ouvrir dans n8n") { /* open */ }
                }
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Finished

struct FinishedView: View {
    @ObservedObject var state: AppState

    private var task: AgentTask? { state.focusTask }

    var body: some View {
        ZStack {
            CardBackground(wash: .green)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    if let task {
                        Circle().fill(Color(hex: task.color)).frame(width: 8, height: 8)
                        Text(task.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                    }
                    Text(task?.lastDuration.map { "a terminé en \(Self.duration($0))" } ?? "a terminé")
                        .font(.system(size: 12, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                Text(task?.steps.last ?? "Session terminée")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    PrimaryButton("Revenir", kbd: "⏎") {
                        returnToSession(task)
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                    SecondaryButton("OK") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                }
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "42 s", "4 min", "1 h 05"
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%d h %02d", s / 3600, (s % 3600) / 60)
    }
}

// MARK: - Confused

struct ConfusedView: View {
    var body: some View {
        ZStack {
            CardBackground(wash: .pink)
            VStack(alignment: .leading, spacing: 5) {
                Text("Trop de coups à la fois.").font(.system(size: 15, weight: .semibold))
                Text("Laisse-moi souffler — je reprends dans trois secondes.")
                    .font(.system(size: 13)).foregroundColor(Color(hex: "#9398A1"))
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Note (short message, auto-closes)

struct NoteView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.noteMessage ?? "")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.leading, CardLayout.contentLeading)
        }
    }
}

// MARK: - Ticker (overview scrolling task steps) V2

struct TickerView: View {
    let task: AgentTask?

    @State private var rowA: String = "…"   // completed (above, left-shifted)
    @State private var rowB: String = "…"   // current (below) → animates diagonally up-left
    @State private var rowC: String = ""    // incoming current — slides in from below

    @State private var rowAOffset: CGFloat = 0
    @State private var rowAOpacity: Double = 1
    @State private var rowBOffset: CGFloat = 22
    @State private var rowBPhase:  Double  = 0   // 0=current, 1=completed (drives X+scale)
    @State private var rowCOffset: CGFloat = 44
    @State private var rowCOpacity: Double = 0

    @State private var displayIndex: Int = -1
    @State private var isTransitioning = false

    private let completedScale: CGFloat = 11.5 / 13   // 0.885 — matches completed font size

    var steps: [String] {
        let raw = task?.steps ?? []
        return raw.isEmpty ? ["…"] : raw
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // Row A: completed row — always rendered at phase=1 + completedScale
            TickerRowView(text: rowA, phase: 1.0)
                .scaleEffect(completedScale, anchor: .leading)
                .offset(x: -10, y: rowAOffset)
                .opacity(rowAOpacity)

            // Row B: current step → animates diagonally up-left, phase 0→1, scale 1→completedScale
            TickerRowView(text: rowB, phase: rowBPhase)
                .scaleEffect(1 - rowBPhase * (1 - completedScale), anchor: .leading)
                .offset(x: -rowBPhase * 10, y: rowBOffset)

            // Row C: incoming new step — slides in from below at phase=0
            TickerRowView(text: rowC, phase: 0.0)
                .offset(y: rowCOffset)
                .opacity(rowCOpacity)
        }
        .frame(height: 44)
        .clipped()
        .mask(LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        ))
        .onAppear {
            let idx = task?.stepIndex ?? -1
            displayIndex = idx
            if idx >= 0, !steps.isEmpty {
                rowA = idx > 0 ? steps[max(0, idx - 1)] : "…"
                rowB = steps[min(idx, steps.count - 1)]
            }
        }
        .onChange(of: task?.steps.count) { _, _ in
            guard let task, !task.steps.isEmpty, !isTransitioning else { return }
            let newIdx = task.stepIndex
            if displayIndex < 0 {
                displayIndex = newIdx
                rowA = newIdx > 0 ? steps[max(0, newIdx - 1)] : "…"
                rowB = steps[min(newIdx, steps.count - 1)]
                return
            }
            guard newIdx != displayIndex else { return }
            tickerAnimate(to: newIdx)
        }
    }

    private func tickerAnimate(to newIdx: Int) {
        isTransitioning = true
        rowC = steps[min(newIdx, steps.count - 1)]
        rowCOffset = 44
        rowCOpacity = 0

        // Old completed (rowA): fades + slides further up
        withAnimation(.easeOut(duration: 0.28)) {
            rowAOffset  = -22
            rowAOpacity = 0
        }

        // Current (rowB): moves diagonally up-left + shrinks to completed size
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowBOffset = 0
            rowBPhase  = 1
        }

        // New current (rowC): slides in from below
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowCOffset  = 22
            rowCOpacity = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            self.displayIndex    = newIdx
            self.rowA            = self.rowB
            self.rowAOffset      = 0
            self.rowAOpacity     = 1
            self.rowB            = self.rowC
            self.rowBOffset      = 22
            self.rowBPhase       = 0
            self.rowCOffset      = 44
            self.rowCOpacity     = 0
            self.isTransitioning = false
        }
    }
}

struct TickerRowView: View {
    let text: String
    let phase: Double   // 0 = current (shimmer, large), 1 = completed (dim, scaled down by caller)

    var body: some View {
        HStack(spacing: 6) {
            // Icon: chevron fades out first half, checkmark fades in second half
            ZStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .opacity(max(0, 1 - phase * 2))
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(Color(hex: "#454850"))
                    .opacity(max(0, phase * 2 - 1))
            }
            .frame(width: 12, alignment: .center)

            // Text: shimmer fades out, dim completed text fades in (overlapping cross-fade)
            ZStack(alignment: .leading) {
                TickerShimmerText(text: text)
                    .opacity(max(0, 1 - phase * 1.6))
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1).truncationMode(.tail)
                    .opacity(min(1, max(0, phase * 2 - 0.4)))
            }
        }
        .frame(height: 22, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TickerShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2)
            // phase sweeps -0.1 → 1.1 so white peak enters from left and exits right
            let phase = p * 1.2 - 0.1
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(LinearGradient(stops: [
                    .init(color: Color(hex: "#7c818a"), location: max(0, phase - 0.3)),
                    .init(color: Color(hex: "#F2F3F5"), location: max(0, min(1, phase))),
                    .init(color: Color(hex: "#7c818a"), location: min(1, phase + 0.3)),
                ], startPoint: .leading, endPoint: .trailing))
        }
    }
}

// MARK: - Agent pills (overview right card)

struct AgentPillsView: View {
    @ObservedObject var state: AppState
    @State private var swapping = false

    private var others: [AgentTask] {
        Array(state.tasks.filter { $0.id != state.focusId }.prefix(4))
    }

    private let gap: CGFloat = 4
    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: gap), GridItem(.flexible(), spacing: gap)]
    }

    var body: some View {
        // Tiles fill the card with `cardInset` all around, so their corners are
        // concentric with the card's (radius = cardRadius − cardInset).
        GeometryReader { geo in
            let rows: CGFloat = others.count > 2 ? 2 : 1
            let height = (geo.size.height - IslandConst.cardInset * 2 - gap * (rows - 1)) / rows
            LazyVGrid(columns: columns, spacing: gap) {
                ForEach(others) { task in
                    AgentPill(task: task, state: state, swapping: $swapping, height: height) {
                        swapping = true
                        state.setFocus(task.id)
                        SoundEngine.shared.play("blip")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { swapping = false }
                    }
                }
            }
            .padding(IslandConst.cardInset)
        }
    }
}

struct AgentPill: View {
    let task: AgentTask
    @ObservedObject var state: AppState
    @Binding var swapping: Bool
    var height: CGFloat = 28
    let onTap: () -> Void
    @State private var isHovered = false

    private var tile: RoundedRectangle { RoundedRectangle(cornerRadius: IslandConst.innerRadius) }

    var body: some View {
        Button(action: { onTap() }) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    MiniBotCanvasView(task: task)
                        .frame(width: 22 / 0.6, height: 22 / 0.6)
                        .frame(width: 22, height: 22, alignment: .center)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isHovered
                                             ? Color(hex: task.color).lighter(by: 0.3)
                                             : Color(hex: "#C5C8CD"))
                            .lineLimit(1)
                        if let step = task.steps.last, height > 34 {
                            Text(step)
                                .font(.system(size: 9.5))
                                .foregroundColor(Color(hex: "#6B7079"))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // Same gap left of the mini-bot as above and below it (capped for tall tiles)
                .padding(.horizontal, min(12, max(9, (height - 22) / 2)))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(tile.fill(isHovered ? Color(hex: task.color).opacity(0.16) : Color(hex: "#0E0F11")))
                .overlay(tile.stroke(Color(hex: task.color).opacity(isHovered ? 0.5 : 0.12), lineWidth: 1))

                if let badge = task.pillBadge {
                    PillBadgeView(badge: badge, taskColor: task.color)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .pointingHand()
        .brightness(isHovered ? 0.04 : 0)
        .onHover { newHover in
            guard !swapping else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
    }
}

struct PillBadgeView: View {
    let badge: PillBadge
    let taskColor: String

    private var badgeColor: Color {
        switch badge {
        case .approval: return Color(hex: "#F5A524")
        case .finished: return Color(hex: "#22C55E")
        case .error:    return Color(hex: "#F4505E")
        case .message:  return Color(hex: "#36C5F0")
        }
    }

    private var icon: String {
        switch badge {
        case .approval: return "exclamationmark"
        case .finished: return "checkmark"
        case .error:    return "xmark"
        case .message:  return "bubble.left.fill"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "#0B0C0E"))
                .frame(width: 14, height: 14)
            Circle()
                .fill(badgeColor)
                .frame(width: 12, height: 12)
            Image(systemName: icon)
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(.black)
        }
        .shadow(color: badgeColor.opacity(0.6), radius: 4, x: 0, y: 0)
    }
}

// MARK: - Column agents (right side of non-overview views)

struct ColumnAgentsView: View {
    @ObservedObject var state: AppState

    var others: [AgentTask] {
        state.tasks.filter { $0.id != state.focusId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(others.prefix(4).enumerated()), id: \.1.id) { idx, task in
                MiniBotCanvasView(task: task)
                    .frame(width: 16 / 0.6, height: 16 / 0.6)
                    .frame(width: 16, height: 16)
                    .position(x: 0, y: CGFloat(50 + idx * 24))
                    .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(Double(idx) * 0.035), value: idx)
            }
        }
    }
}

// MARK: - Card background

struct CardBackground<Content: View>: View {
    enum Wash { case red, green, pink, amber, cyan, indigo, soft }

    let wash: Wash?
    let content: (() -> Content)?

    init(wash: Wash?, @ViewBuilder content: @escaping () -> Content) {
        self.wash = wash
        self.content = content
    }

    var washColor: Color {
        switch wash {
        case .red:    return Color(hex: "#F4505E").opacity(0.55)
        case .green:  return Color(hex: "#34D399").opacity(0.5)
        case .pink:   return Color(hex: "#F472B6").opacity(0.55)
        case .amber:  return Color(hex: "#F5A524").opacity(0.42)
        case .cyan:   return Color(hex: "#22D3EE").opacity(0.38)
        case .indigo: return Color(hex: "#6366F1").opacity(0.5)
        case .soft:   return Color.white.opacity(0.08)
        case nil:     return Color.clear
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: IslandConst.cardRadius)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: washColor, location: 0),
                            .init(color: .clear, location: 0.7)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: IslandConst.cardRadius))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: IslandConst.cardRadius)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )

            if let content = content {
                content()
            }
        }
    }
}

extension CardBackground where Content == EmptyView {
    init(wash: Wash?) {
        self.wash = wash
        self.content = nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: IslandConst.cardRadius)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: washColor, location: 0),
                            .init(color: .clear, location: 0.7)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: IslandConst.cardRadius))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: IslandConst.cardRadius)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )
        }
    }
}

// MARK: - Shared sub-components

struct AgentWho: View {
    let task: AgentTask?
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            if let task = task {
                Circle().fill(Color(hex: task.color)).frame(width: 8, height: 8)
                Text(task.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            }
            Text(label).font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
        }
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: IslandConst.innerRadius).stroke(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: IslandConst.innerRadius))
            .foregroundColor(Color(hex: "#E8E9EC"))
    }
}

struct ShimmeringText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: "#7c818a"), location: 0),
                        .init(color: .white, location: 0.4),
                        .init(color: Color(hex: "#7c818a"), location: 0.7)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0.0

    var body: some View {
        LinearGradient(
            stops: [
                // Clamp all locations to [0,1] and keep them ordered
                .init(color: .clear,                   location: max(0, phase - 0.3)),
                .init(color: Color.white.opacity(0.6), location: max(0, min(1, phase))),
                .init(color: .clear,                   location: min(1, phase + 0.3))
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .blendMode(.overlay)
        .onAppear {
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                phase = 1.3  // travels left→right, exits right edge cleanly
            }
        }
    }
}

// MARK: - Button styles

struct PrimaryButton: View {
    let title: String
    let kbd: String?
    let action: () -> Void

    init(_ title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.kbd = kbd; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let k = kbd {
                    Text(k).font(.system(size: 10.5))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.4)))
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Color(hex: "#F5F6F8"))
            .foregroundColor(Color(hex: "#0B0C0E"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }
}

struct SecondaryButton: View {
    let title: String
    let kbd: String?
    let action: () -> Void

    init(_ title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.kbd = kbd; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let k = kbd {
                    Text(k).font(.system(size: 10.5))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4)))
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Color.white.opacity(0.09))
            .foregroundColor(Color(hex: "#F1F2F4"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.08))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(Color(hex: "#F5F6F8"))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

// MARK: - Settings island view (Point 7)

struct SettingsIslandView: View {
    @ObservedObject var state: AppState

    private var claudeConnected: Bool { HookServer.claudeHooksInstalled() }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 10) {
                // Sound row
                HStack(spacing: 10) {
                    Toggle("", isOn: $state.soundEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.75)
                        .frame(width: 44)
                    Text("Son")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    Slider(value: $state.soundVolume, in: 0...0.2)
                        .frame(width: 72)
                        .opacity(state.soundEnabled ? 1 : 0.4)
                }

                // Auto-close row
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 16)
                    Text("Refermer après · \(Int(state.autoCloseDelay)) s")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach([2, 3, 5], id: \.self) { s in
                            Button("\(s) s") {
                                state.autoCloseDelay = Double(s)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(state.autoCloseDelay == Double(s) ? Color(hex: "#252830") : Color.clear)
                            .foregroundColor(state.autoCloseDelay == Double(s) ? Color(hex: "#F5F6F8") : Color(hex: "#6B7079"))
                            .clipShape(Capsule())
                            .buttonStyle(.plain)
                            .pointingHand()
                        }
                    }
                }

                // Connection status
                HStack(spacing: 14) {
                    StatusBadge(label: "Claude Code", ok: claudeConnected)
                    StatusBadge(label: "Slack", ok: state.slackStatus == .connected)
                    StatusBadge(label: "Harvest", ok: HarvestService.shared.isConfigured && state.harvestError == nil)
                    Spacer()
                    Button("Réglages…") {
                        NotificationCenter.default.post(name: .openFullSettings, object: nil)
                    }
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .buttonStyle(.plain)
                    .pointingHand()
                }
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
        }
    }
}

struct StatusBadge: View {
    let label: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color(hex: "#22C55E") : Color(hex: "#F4505E"))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
        }
    }
}

extension Color {
    func lighter(by amount: Double) -> Color {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(
            red: min(1, Double(components.redComponent) + amount),
            green: min(1, Double(components.greenComponent) + amount),
            blue: min(1, Double(components.blueComponent) + amount)
        )
    }
}
