import SwiftUI

/// Top-level SwiftUI view rendered inside the 720×320 transparent panel.
/// The island is drawn at the top-center; everything else is transparent and click-through.
struct IslandRootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(state: state)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Island container

struct IslandContainer: View {
    @ObservedObject var state: AppState
    @State private var islandWidth:  CGFloat = IslandConst.notchWidth
    @State private var islandHeight: CGFloat = IslandConst.notchHeight
    @State private var cornerRadius: CGFloat = IslandConst.roundedCorner
    @State private var flare: CGFloat = 0
    @State private var greetNotif: Bool = false

    private let openSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    private let closeEase  = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)

    private func flare(for mode: IslandMode) -> CGFloat {
        switch mode {
        case .hidden:   return 0
        case .compact:  return IslandConst.flareCompact
        case .expanded: return IslandConst.flareExpanded
        }
    }

    var body: some View {
        let greetingActive = state.mode == .expanded && state.view == .greeting

        return ZStack(alignment: .topLeading) {
            // Black island shape
            IslandShape(width: islandWidth, height: islandHeight,
                        cornerRadius: cornerRadius, flare: flare)
                .fill(Color.black)

            // Content
            if state.mode == .expanded {
                if greetingActive {
                    // Greeting canvas: fixed 640-wide, centered by offset so x=320 aligns with island center
                    GreetingCanvasView(state: state)
                        .frame(width: IslandConst.expandedWidth, height: 150)
                        .offset(x: (islandWidth - IslandConst.expandedWidth) / 2)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, flare: 0))
                        .transition(.opacity)
                } else {
                    IslandContentView(state: state)
                        .frame(width: islandWidth, height: islandHeight)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, flare: 0))
                        .transition(.opacity)
                }
            }

            // Single BotPlacement — always alive in the view tree so spring animations
            // fire from the current position (e.g. choose at 60,101) when canvas deactivates.
            // Hidden during the greeting (it draws its own character).
            BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                // Keep idle animations inside the resting strip. Expanded views
                // retain the panel's full height for particles and hands.
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: islandWidth,
                                      height: state.mode == .expanded ? 320 : islandHeight)
                }
                .opacity(greetingActive ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: greetingActive)

            // Concentration on: a small violet light next to the character
            if state.mode == .compact && state.focusMode {
                Circle()
                    .fill(Color(hex: "#A78BFA"))
                    .frame(width: 5, height: 5)
                    .shadow(color: Color(hex: "#A78BFA").opacity(0.8), radius: 3)
                    .position(x: IslandConst.compactEar - 7, y: islandHeight / 2 + 5)
                    .transition(.opacity)
            }

            Group {
                if state.mode == .compact {
                    CompactMiniGrid(state: state)
                        .scaleEffect(IslandRestingLayout(width: islandWidth, height: islandHeight).miniGridScale)
                        .position(x: islandWidth - IslandConst.compactEar / 2, y: islandHeight / 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.mode == .compact)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .topLeading)
        .onChange(of: state.mode) { oldMode, newMode in
            let shrinking = modeOrder(newMode) < modeOrder(oldMode)
            let anim = shrinking ? closeEase : openSpring
            let (w, h) = islandSize(mode: newMode, view: state.view,
                                    nw: state.notchWidth, nh: state.notchHeight)
            let cr  = newMode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            withAnimation(anim) {
                islandWidth      = w
                islandHeight     = h
                cornerRadius     = cr
                flare            = flare(for: newMode)
            }
        }
        .onChange(of: state.view) { _, newView in
            guard state.mode == .expanded else { return }
            let (w, h) = islandSize(mode: .expanded, view: newView,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = h
            }
        }
        // The Harvest list grows the island downwards while you pick
        .onChange(of: state.harvestListOpen) { _, _ in
            guard state.mode == .expanded else { return }
            let (w, h) = islandSize(mode: .expanded, view: state.view,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = h
            }
        }
        .onAppear {
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    nw: state.notchWidth, nh: state.notchHeight)
            islandWidth      = w
            islandHeight     = h
            cornerRadius     = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            flare            = flare(for: state.mode)
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            greetNotif.toggle()
        }
    }

    private func modeOrder(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }
}

// MARK: - Island shape
//
// The body is `width` × `height` with rounded bottom corners. At the top, a concave
// `flare` curves outwards on both sides (drawn outside the frame), so the island
// grows out of the screen edge instead of meeting it at a hard right angle.

struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat   // bottom corners
    var flare: CGFloat          // top flare, outside the frame

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(width, height), .init(cornerRadius, flare)) }
        set {
            width        = newValue.first.first
            height       = newValue.first.second
            cornerRadius = newValue.second.first
            flare        = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, min(cornerRadius, width / 2, height / 2))
        let f  = max(0, min(flare, height - cr))
        var p  = Path()
        p.move(to: CGPoint(x: -f, y: 0))
        p.addLine(to: CGPoint(x: width + f, y: 0))
        // Top-right flare: from the screen edge down into the right side
        p.addQuadCurve(to: CGPoint(x: width, y: f), control: CGPoint(x: width, y: 0))
        p.addLine(to: CGPoint(x: width, y: height - cr))
        p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: cr, y: height))
        p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: f))
        // Top-left flare
        p.addQuadCurve(to: CGPoint(x: -f, y: 0), control: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Bot placement helper

struct BotPlacement: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    var body: some View {
        let (cx, cy, diameter, opacity) = botPosition(mode: state.mode, view: state.view, islandW: islandW, islandH: islandH, hasNotch: state.hasNotch)
        let canvasSize = diameter / 0.6
        let overhang: CGFloat = 40

        Group {
            if state.mode == .expanded {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: botGlowColor(state.effectiveState), location: 0),
                            .init(color: .clear, location: 0.62)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 1.1
                    ))
                    .frame(width: diameter * 2.2, height: diameter * 2.2)
                    .blur(radius: 6)
                    .opacity(botGlowOpacity(state.effectiveState))
                    .position(x: cx, y: cy)
                    .animation(.easeInOut(duration: 0.4), value: state.effectiveState)
            }

            // Extra 40pt canvas at top for heart particles; position offset up by 20pt;
            // BotEngine compensates with cy = H/2 + particleOverhang/2 + oy*R + R*0.06.
            BotCanvasView(state: state, particleOverhang: overhang)
                .frame(width: canvasSize, height: canvasSize + overhang)
                .opacity(opacity)
                .position(x: cx, y: cy - overhang / 2)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cx)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cy)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: canvasSize)
        }
        // Slap, drag, and hover are handled by the AppKit NSEvent monitor in
        // IslandWindowController — not SwiftUI gestures — so this is safe.
        .allowsHitTesting(false)
    }

    private func botGlowColor(_ s: BotState) -> Color {
        switch s {
        case .working:   return Color(hex: "#3B9EFF")
        case .thinking:  return Color(hex: "#A78BFA")
        case .searching: return Color(hex: "#6366F1")
        case .approval:  return Color(hex: "#F5A524")
        case .error:     return Color(hex: "#F4505E")
        case .finished:  return Color(hex: "#34D399")
        case .ratelimit: return Color(hex: "#F59E0B")
        default:         return Color.white
        }
    }

    private func botGlowOpacity(_ s: BotState) -> Double {
        switch s {
        case .idle, .sleeping: return 0.15
        case .dizzy:           return 0.0
        default:               return 0.65
        }
    }
}

func botPosition(mode: IslandMode, view: IslandView, islandW: CGFloat, islandH: CGFloat, hasNotch: Bool = true) -> (CGFloat, CGFloat, CGFloat, Double) {
    let resting = IslandRestingLayout(width: islandW, height: islandH)
    switch mode {
    case .hidden:
        return hasNotch ? (46, 16, 6, 0)
            : (islandW / 2, resting.botCenterY, resting.botDiameter, 1)
    case .compact: return (IslandConst.compactEar / 2, resting.botCenterY, resting.botDiameter, 1)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        let diameter = layout.botDiameter
        let cx = layout.botX
        let cy: CGFloat
        if let fixedY = layout.botY {
            cy = fixedY
        } else {
            // Centred in the card, which runs from below the header to contentInset above the bottom
            let cardH = islandH - IslandConst.cardTop - IslandConst.contentInset
            cy = IslandConst.cardTop + cardH / 2 + CardLayout.botCenterYOffset
        }
        return (cx, cy, diameter, 1)
    }
}

// MARK: - Island content (header + views, only in expanded mode)

struct IslandContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            IslandHeader(state: state)
                .frame(height: IslandConst.headerHeight)
                .opacity(state.view == .confused ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: state.view == .confused)

            ZStack {
                ForEach(IslandView.allCases, id: \.self) { v in
                    let active = state.view == v
                    let anim: Animation = active
                        ? .spring(response: 0.4, dampingFraction: 0.8).delay(0.16)
                        : .easeIn(duration: 0.16)
                    IslandViewContent(view: v, state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.97)
                        .allowsHitTesting(active)
                        .animation(anim, value: state.view)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, IslandConst.contentInset)
        }
        .padding(.top, IslandConst.headerTop)
        .padding(.bottom, IslandConst.contentInset)
        .foregroundColor(Color(hex: "#F5F6F8"))
    }
}

// MARK: - Island header (tabs + icons)

struct IslandHeader: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Left: back to the overview (when inside a card), then concentration.
            // The moon slides right to make room for the arrow.
            let showsBack = state.view != .overview && state.view != .empty
            HStack(spacing: 8) {
                if showsBack {
                    TabButton(icon: "chevron.left", view: .overview, state: state)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: -10)),
                            removal: .opacity.combined(with: .offset(x: -10))))
                }
                FocusButton(state: state)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showsBack)
            .padding(.leading, 16)

            Spacer()

            // Right: action icons
            HStack(spacing: 14) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.view = .settings
                    }
                }) {
                    Image(systemName: state.view == .settings ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(state.view == .settings ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .pointingHand()

                Button(action: { state.soundEnabled.toggle() }) {
                    Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .pointingHand()
            }
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Concentration toggle: Slack, Vercel and the Harvest reminder go quiet.
struct FocusButton: View {
    @ObservedObject var state: AppState
    @State private var hovered = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { state.focusMode.toggle() }
            SoundEngine.shared.play("blip")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.focusMode ? "moon.fill" : "moon")
                    .font(.system(size: 13, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                if state.focusMode {
                    Text("Concentration")
                        .font(.system(size: 11, weight: .semibold))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundColor(state.focusMode ? Color(hex: "#C4B5FD")
                             : (hovered ? Color(hex: "#B0B5BE") : Color(hex: "#8E939C")))
            .padding(.horizontal, state.focusMode ? 9 : 0)
            .frame(height: 22)
            .background(Capsule().fill(Color(hex: "#8B5CF6").opacity(state.focusMode ? 0.18 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .onHover { hovered = $0 }
        .help(state.focusMode ? "Concentration activée : seul Claude te dérange. Clique pour l'arrêter."
                              : "Concentration : couper Slack, Vercel et le rappel Harvest")
    }
}

struct TabButton: View {
    let icon: String
    let view: IslandView
    @ObservedObject var state: AppState
    var preAction: (() -> Void)? = nil
    @State private var isHovered = false

    private var isOn: Bool {
        if view == .overview { return state.view == .overview || state.view == .empty }
        return state.view == view
    }

    var body: some View {
        Button(action: {
            preAction?()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = view
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isOn ? Color(hex: "#F5F6F8") : (isHovered ? Color(hex: "#B0B5BE") : Color(hex: "#8E939C")))
                .frame(width: 30, height: 22)
                .background(
                    isOn ? Color(hex: "#1D1F23") :
                    isHovered ? Color.white.opacity(0.07) : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact mini mochi grid (2×2 to the right of the notch)

struct CompactMiniGrid: View {
    @ObservedObject var state: AppState

    private var others: [AgentTask] {
        Array(state.tasks.filter { $0.id != state.focusId }.prefix(4))
    }

    var body: some View {
        let size = IslandRestingLayout.miniSize
        let gap = IslandRestingLayout.miniGap
        let cols = [GridItem(.fixed(size), spacing: gap), GridItem(.fixed(size), spacing: gap)]
        LazyVGrid(columns: cols, spacing: gap) {
            ForEach(others) { task in
                MiniBotCanvasView(task: task)
                    .frame(width: size / 0.6, height: size / 0.6)
                    .frame(width: size, height: size, alignment: .center)
            }
        }
        .frame(width: IslandRestingLayout.miniGridSide, height: IslandRestingLayout.miniGridSide)
    }
}

// MARK: - Color helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let val = UInt64(h, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
