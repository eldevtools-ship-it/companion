import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandWindowController: NSWindowController {

    private var islandPanel: IslandPanel!
    private var state: AppState { AppState.shared }

    // State machine (replaces all hover/absence/auto-close timers)
    let fsm = IslandStateMachine()

    private var wasInIsland = false
    private var frameTimer: Timer?
    private var keyMonitor: Any?
    private var viewSubscription: AnyCancellable?

    // Confused recovery timer (set by handleDizzy)
    private var confusedRecoveryTimer: DispatchWorkItem?

    // Suppress peek sound on next reveal (e.g. musicReveal)
    var silentNextReveal = false


    // Bot-head hover (love emote — mirrors prototype botHover())
    private var botHoverTimer: DispatchWorkItem?
    private var botHovering: Bool = false
    private var lastLoveTime: Double = 0
    private var botHoverStartPos: CGPoint = .zero

    private var pendingIslandClick = false   // any island click → expand on mouseUp

    // Notch real dimensions (set on init)
    private var notchW: CGFloat = IslandConst.notchWidth
    private var notchH: CGFloat = IslandConst.notchHeight
    private var hasNotch = true

    convenience init() {
        let screen = Self.notchScreen() ?? NSScreen.main!
        let geometry = Self.screenGeometry(for: screen)
        let nW = geometry.width
        let nH = geometry.height

        let panelW: CGFloat = 720
        let panelH: CGFloat = 320
        let sf = screen.frame
        let panel = IslandPanel(
            contentRect: NSRect(x: sf.midX - panelW/2, y: sf.maxY - panelH,
                                width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.notchWidth  = nW
        panel.notchHeight = nH

        self.init(window: panel)
        self.islandPanel = panel
        self.notchW = nW
        self.notchH = nH
        self.hasNotch = geometry.hasNotch
        setupPanel(screen: screen)
    }

    private func setupPanel(screen: NSScreen) {
        guard let panel = window as? IslandPanel else { return }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        // Propagate real notch dimensions to AppState
        AppState.shared.notchWidth  = notchW
        AppState.shared.notchHeight = notchH
        AppState.shared.hasNotch = hasNotch

        let contentSize = panel.contentRect(forFrameRect: panel.frame).size

        // Apple-recommended pattern: put NSHostingView and drag destination as siblings
        // inside a common superview, rather than embedding one inside the other.
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: IslandRootView().environmentObject(AppState.shared))
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]

        container.addSubview(hosting)
        panel.contentView = container

        startPolling()
        startKeyMonitor()
        wireFSM()

        // Make panel key whenever the Harvest picker (note field) becomes active
        // (nonactivatingPanel never auto-becomes key, but TextField needs it)
        viewSubscription = state.$view
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newView in
                guard let self else { return }
                if newView == .harvest || newView == .question || newView == .notes || newView == .chat {
                    self.islandPanel.makeKey()
                }
            }

        // A card with a text field (Slack reply) asks for the keyboard
        NotificationCenter.default.addObserver(forName: .islandNeedsKeyboard, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.islandPanel.makeKey() }
        }
    }

    // MARK: - FSM wiring

    private func wireFSM() {
        fsm.onTransition = { [weak self] from, to in
            guard let self else { return }
            switch to {
            case .hidden:
                self.setMode(.hidden)

            case .petit:
                if from == .greeting {
                    // Fire interrupt first so canvas collapse starts before mode change
                    NotificationCenter.default.post(name: .greetingInterrupt, object: nil)
                } else if from == .hidden {
                    if self.silentNextReveal {
                        self.silentNextReveal = false
                    } else {
                        SoundEngine.shared.play("peek")
                    }
                }
                // setMode BEFORE changing view: onChange(of: state.view) guards on .expanded,
                // so setting view while already compact won't trigger a spurious open animation.
                self.setMode(.compact)
                if from == .greeting { self.state.view = self.defaultView() }
                // Start 60s hide timer if mouse is not currently over the island
                if !self.wasInIsland { self.fsm.mouseLeft() }

            case .home:
                self.expand(to: self.defaultView())
                // Start collapse timer if mouse not currently hovering
                if !self.wasInIsland {
                    self.fsm.mouseLeft()
                }

            case .greeting:
                self.expand(to: .greeting)
            }
        }

        // FSM observes greetComplete notification
        NotificationCenter.default.addObserver(
            forName: .greetComplete, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fsm.greetComplete() }
        }

        fsm.homeToPetitDelay = { max(1, AppState.shared.autoCloseDelay) }

        // Stay open while Claude waits for an answer or while you're typing / picking
        fsm.isHeldOpen = {
            let s = AppState.shared
            return s.pendingApproval != nil || s.pendingQuestion != nil || s.isEditingText || s.harvestListOpen
        }
    }

    // MARK: - Pointer polling
    // 60 Hz while the pointer is near the island or it's open (hover, look-at, cursor);
    // 8 Hz otherwise, so a resting island barely wakes the CPU.

    private var pollHot = true

    private func startPolling() {
        schedulePoll(hot: true)
    }

    private func schedulePoll(hot: Bool) {
        frameTimer?.invalidate()
        pollHot = hot
        let t = Timer(timeInterval: hot ? 1.0 / 60.0 : 1.0 / 8.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFrame() }
        }
        t.tolerance = hot ? 0.002 : 0.04
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func pollFrame() {
        guard let panel = window as? IslandPanel else { return }

        let mouse = NSEvent.mouseLocation

        // Convert mouse to panel-local coords (macOS: origin bottom-left)
        let pf = panel.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)

        // Island rect in panel coords
        let islandRect = panel.currentIslandFrame(nw: notchW, nh: notchH)
        // On a screen without a notch, the resting bar must not intercept clicks
        // in the app window immediately below the menu bar.
        let hoverRect = !hasNotch && state.mode != .expanded
            ? islandRect : islandRect.insetBy(dx: -6, dy: -6)
        let inIsland = hoverRect.contains(local)

        // Pointer over the island: show our cursor (hand on buttons), not the one the
        // app underneath keeps setting (often a text I-beam).
        if inIsland && (local != lastLocal || !wasInIsland) {
            IslandCursor.apply()
        }
        lastLocal = local

        // Toggle click-through
        let shouldAcceptMouse = inIsland
        if panel.ignoresMouseEvents == shouldAcceptMouse {
            panel.ignoresMouseEvents = !shouldAcceptMouse
            if shouldAcceptMouse, let cv = panel.contentView {
                panel.invalidateCursorRects(for: cv)
            }
        }

        // Mouse in screen coords (Y flipped, origin top-left) for Bot look-at
        let screenH = panel.screen?.frame.height ?? NSScreen.main!.frame.height
        let newPos = CGPoint(x: mouse.x - (panel.screen?.frame.minX ?? 0), y: screenH - mouse.y)
        let cur = AppState.shared.mousePosition
        if abs(newPos.x - cur.x) > 1 || abs(newPos.y - cur.y) > 1 {
            AppState.shared.mousePosition = newPos
            AppState.shared.lastMouseMove = .now
        }

        // AppState can hide the island by itself (last task ended): keep the FSM in step.
        if state.mode == .hidden && fsm.state == .petit { fsm.hiddenExternally() }

        // Feed FSM hover enter/leave
        if inIsland && !wasInIsland {
            // If in greeting: tell greeting to stay open (tc → infinity)
            if fsm.state == .greeting {
                NotificationCenter.default.post(name: .greetingHover, object: nil)
            }
            fsm.mouseEntered()
        }
        if !inIsland && wasInIsland {
            fsm.mouseLeft()
        }
        wasInIsland = inIsland
        updateKeyboard(pointerInside: inIsland)

        // Fast polling only when it matters
        let near = islandRect.insetBy(dx: -160, dy: -160).contains(local)
        let wantHot = near || state.mode == .expanded || botHovering
        if wantHot != pollHot { schedulePoll(hot: wantHot) }

        // Bot-head hover (love emote)
        let overBot = state.mode == .expanded && state.stateOverride == nil && isBotHit(local)
        if overBot && !botHovering { botHoverIn(mousePos: NSEvent.mouseLocation) }
        if !overBot && botHovering { botHoverOut() }
        botHovering = overBot
        if botHovering { trackStroke(x: NSEvent.mouseLocation.x) }
        if botHovering {
            let m = NSEvent.mouseLocation
            let dist = hypot(m.x - botHoverStartPos.x, m.y - botHoverStartPos.y)
            if dist > 40 {
                botHoverStartPos = m
                botHoverTimer?.cancel()
                scheduleLoveTimer()
            }
        }
    }

    // MARK: - Keyboard shortcuts (approval / question)
    // The island only takes the keyboard while the pointer is on it, so a key typed
    // in another app can never answer Claude by accident.

    private var tookKeyboard = false

    private var answerPending: Bool {
        state.mode == .expanded
            && (state.pendingApproval != nil || state.pendingQuestion != nil || state.view == .finished)
    }

    private func updateKeyboard(pointerInside: Bool) {
        guard let panel = islandPanel else { return }
        if pointerInside && answerPending {
            if !panel.isKeyWindow { panel.makeKey(); tookKeyboard = true }
        } else if tookKeyboard {
            tookKeyboard = false
            // Keep it while you're typing an answer
            if panel.isKeyWindow && !(panel.firstResponder is NSText) { panel.resignKey() }
        }
    }

    /// ⏎ autoriser · ⌘⏎ toujours · ⎋ refuser — 1…9 choisir · ⏎ valider. Returns true if handled.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.window === islandPanel, answerPending, wasInIsland else { return false }
        if islandPanel.firstResponder is NSText { return false }   // typing in a field
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let cmd = event.modifierFlags.contains(.command)
        if state.view == .finished {
            guard isReturn else { return false }
            returnToSession(state.focusTask)
            collapse()
            return true
        }
        if let approval = state.pendingApproval, state.view == .approval {
            if isReturn {
                let always = cmd && approval.pillId != "agent_codex"
                HookServer.shared.sendApprovalDecision(always ? "always" : "allow")
                return true
            }
            if event.keyCode == 53 { HookServer.shared.sendApprovalDecision("deny"); return true }
            return false
        }
        if state.pendingQuestion != nil, state.view == .question {
            if isReturn {
                NotificationCenter.default.post(name: .questionShortcut, object: 0)
                return true
            }
            if let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                NotificationCenter.default.post(name: .questionShortcut, object: n)
                return true
            }
        }
        return false
    }

    private var lastLocal: CGPoint = .zero

    // MARK: - Petting: three changes of direction over the cloud within 1.4 s

    private var strokeLastX: CGFloat = 0
    private var strokeDir: CGFloat = 0
    private var strokeTurns: [Double] = []

    private func trackStroke(x: CGFloat) {
        let dx = x - strokeLastX
        strokeLastX = x
        guard abs(dx) > 1.5 else { return }
        let dir: CGFloat = dx > 0 ? 1 : -1
        if strokeDir != 0 && dir != strokeDir {
            let now = CACurrentMediaTime()
            strokeTurns = strokeTurns.filter { now - $0 < 1.4 } + [now]
            if strokeTurns.count >= 3 {
                strokeTurns = []
                NotificationCenter.default.post(name: .botPet, object: nil)
            }
        }
        strokeDir = dir
    }

    // MARK: - Bot-head hover (love emote — mirrors prototype botHover())

    private func botHoverIn(mousePos: CGPoint) {
        guard state.mode == .expanded, state.stateOverride == nil else { return }
        guard CACurrentMediaTime() - lastLoveTime > 6 else { return }
        botHoverStartPos = mousePos
        NotificationCenter.default.post(name: .botBlink, object: nil)
        NotificationCenter.default.post(name: .botSetTgEs, object: CGFloat(1.08))
        SoundEngine.shared.play("hover")
        scheduleLoveTimer()
    }

    private func botHoverOut() {
        botHoverTimer?.cancel()
        NotificationCenter.default.post(name: .botSetTgEs, object: CGFloat(1))
    }

    private func scheduleLoveTimer() {
        botHoverTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.botHovering, self.state.stateOverride == nil else { return }
            guard CACurrentMediaTime() - self.lastLoveTime > 6 else { return }
            self.lastLoveTime = CACurrentMediaTime()
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.love)
            SoundEngine.shared.play("love")
        }
        botHoverTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: item)
    }

    // MARK: - Mode transitions

    private func modeLevel(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }

    func setMode(_ mode: IslandMode) {
        let prev = state.mode
        guard mode != prev else { return }
        let shrinking = modeLevel(mode) < modeLevel(prev)
        let anim: Animation = shrinking
            ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
            : .spring(response: 0.5, dampingFraction: 0.72)
        withAnimation(anim) { state.mode = mode }
        if mode == .expanded { SoundEngine.shared.play("open") }
        if prev == .expanded {
            SoundEngine.shared.play("close")
            if fsm.isHeldOpen?() != true { state.isPinned = false }
        }
    }

    func expand(to view: IslandView) {
        state.view = view
        if state.mode == .expanded {
            // Already expanded — just switch view
        } else {
            setMode(.expanded)
        }
        state.lastActivity = .now
    }

    /// Opens the island from outside the FSM (menu bar, hotkey) and keeps the FSM in step,
    /// so leaving it afterwards folds it like any other time.
    func open(to view: IslandView) {
        fsm.openedExternally(pointerInside: wasInIsland)
        expand(to: view)
    }

    func collapse() {
        guard fsm.isHeldOpen?() != true else { return }
        state.isPinned = false
        // Keep the FSM in step with what is on screen (home/greeting → petit now).
        fsm.collapse()
        setMode(.compact)
        window?.resignKey()
    }

    // MARK: - Keyboard (Escape closes)

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                if event.keyCode == 53 { // Escape
                    if self.state.mode == .expanded && !self.state.isPinned {
                        self.collapse()
                    }
                }
            }
        }

        // Answer Claude from the keyboard while the pointer is on the island
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleShortcut(event) }
            return handled ? nil : event
        }

        // Hook server expand requests (alerts only)
        NotificationCenter.default.addObserver(forName: .hookExpand, object: nil, queue: .main) { [weak self] note in
            let view = note.object as? IslandView
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.fsm.openedExternally(pointerInside: self.wasInIsland)
                self.expand(to: view)
            }
        }

        // Hook server compact reveal (non-alert work events: session start, tool use, etc.)
        NotificationCenter.default.addObserver(forName: .hookReveal, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fsm.reveal()
            }
        }

        // ⌥⌘J from anywhere: chat with Claude
        NotificationCenter.default.addObserver(forName: .openChat, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.open(to: .chat) }
        }

        // ⌥⌘N from anywhere: the notes, ready to type
        NotificationCenter.default.addObserver(forName: .openNotes, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.open(to: .notes) }
        }

        // Collapse requests from views (OK button, etc.)
        NotificationCenter.default.addObserver(forName: .islandCollapse, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }

        // .botDizzy — posted by BotEngine.slap() on 3rd hit; show confused view + recover after 3.3s
        NotificationCenter.default.addObserver(forName: .botDizzy, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDizzy() }
        }

        // Clicks: slap the character, or open the island on mouseUp.
        // Uses MainActor.assumeIsolated (synchronous) to avoid race with pollFrame().
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard self.wasInIsland else { return }
                self.pendingIslandClick = true
                self.botHoverTimer?.cancel()
                self.botHovering = false
                guard self.isBotHit(event.locationInWindow) else { return }
                // Post slap only when expanded
                guard self.state.mode == .expanded else { return }
                NotificationCenter.default.post(name: .triggerSlap, object: nil)
            }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let hadPendingClick = self.pendingIslandClick
                self.pendingIslandClick = false
                if hadPendingClick && self.state.mode != .expanded {
                    if self.fsm.state == .home {
                        // FSM already thinks it's open (e.g. the view folded it): just reopen.
                        self.expand(to: self.defaultView())
                    } else {
                        self.fsm.click()   // FSM petit/hidden→home; onTransition calls expand(to:)
                    }
                }
            }
            return event
        }
        // Global hotkey to show island
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self, self.state.hotkeyEnabled else { return }
                let pressed = event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue
                guard pressed == self.state.hotkeyFlags, event.keyCode == self.state.hotkeyCode else { return }
                if self.state.mode == .hidden || self.state.mode == .compact {
                    self.open(to: .overview)
                }
            }
        }
    }

    // MARK: - Helpers

    func defaultView() -> IslandView {
        if state.pendingApproval != nil { return .approval }
        return state.tasks.isEmpty ? .empty : .overview
    }

    // MARK: - Dizzy recovery (triggered by BotEngine.slap via .botDizzy)

    private func handleDizzy() {
        let prevView = state.view
        state.stateOverride = .dizzy
        expand(to: .confused)
        confusedRecoveryTimer?.cancel()
        let recovery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.stateOverride = nil
            if self.state.view == .confused {
                let fallback = self.state.tasks.isEmpty ? IslandView.empty : .overview
                self.state.view = (prevView == .confused) ? fallback : prevView
            }
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        }
        confusedRecoveryTimer = recovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3, execute: recovery)
    }

    // MARK: - Bot hit test (for slap trigger)

    private func isBotHit(_ windowPoint: CGPoint) -> Bool {
        let s = AppState.shared
        let panelH = window?.frame.height ?? 320
        let panelW = window?.frame.width  ?? 720
        let (islandW, islandH) = islandSize(mode: s.mode, view: s.view, nw: notchW, nh: notchH)
        let islandMinX = (panelW - islandW) / 2
        let (cx, cy, diameter, _) = botPosition(mode: s.mode, view: s.view,
                                                  islandW: islandW, islandH: islandH,
                                                  hasNotch: s.hasNotch)
        let radius = (diameter / 0.6) / 2
        // botPosition cy is from island TOP; panel AppKit coords have y=0 at bottom
        // island top in AppKit coords = panelH (island glued to top of panel/screen)
        let botX = islandMinX + cx
        let botY = panelH - cy
        let dx = windowPoint.x - botX
        let dy = windowPoint.y - botY
        return dx*dx + dy*dy <= radius * radius
    }

    // MARK: - Notch detection (static)

    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static func screenGeometry(for screen: NSScreen) -> IslandScreenGeometry {
        let visibleMenuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // visibleFrame includes the menu bar only while it is visible. Keep a
        // small resting bar when menus auto-hide or the app is in full screen.
        let menuBarHeight = visibleMenuBarHeight > 0
            ? visibleMenuBarHeight : NSStatusBar.system.thickness
        return IslandScreenGeometry(
            screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: menuBarHeight
        )
    }

}

// MARK: - IslandPanel

final class IslandPanel: NSPanel {
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow panel to sit in the menu bar / notch area — don't let macOS push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    func currentIslandFrame(nw: CGFloat, nh: CGFloat) -> CGRect {
        let s = AppState.shared
        let (w, h) = islandSize(mode: s.mode, view: s.view, nw: nw, nh: nh)
        return CGRect(x: (frame.width - w) / 2, y: frame.height - h, width: w, height: h)
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let triggerEmote     = Notification.Name("compagnon.triggerEmote")
    static let triggerSlap      = Notification.Name("compagnon.triggerSlap")
    static let botDizzy         = Notification.Name("compagnon.botDizzy")
    static let botGreet         = Notification.Name("compagnon.botGreet")
    static let botBlink         = Notification.Name("compagnon.botBlink")
    static let botPet           = Notification.Name("compagnon.botPet")
    static let botSetTgEs       = Notification.Name("compagnon.botSetTgEs")
    static let botGulp          = Notification.Name("compagnon.botGulp")
    static let botMorphTo       = Notification.Name("compagnon.botMorphTo")
    static let islandAction     = Notification.Name("compagnon.islandAction")
    static let islandCollapse   = Notification.Name("compagnon.islandCollapse")
    static let islandNeedsKeyboard = Notification.Name("compagnon.islandNeedsKeyboard")
    static let questionShortcut = Notification.Name("compagnon.questionShortcut")
    static let openFullSettings = Notification.Name("compagnon.openFullSettings")
    static let hookReveal       = Notification.Name("compagnon.hookReveal")
    // Greeting ↔ IslandWindowController
    static let greetComplete    = Notification.Name("compagnon.greetComplete")
    static let greetingHover    = Notification.Name("compagnon.greetingHover")
    static let greetingInterrupt = Notification.Name("compagnon.greetingInterrupt")
}

// MARK: - islandSize (takes real notch dimensions)

@MainActor
func islandSize(mode: IslandMode, view: IslandView,
                nw: CGFloat = IslandConst.notchWidth,
                nh: CGFloat = IslandConst.notchHeight) -> (CGFloat, CGFloat) {
    switch mode {
    case .hidden:   return (nw, nh)
    case .compact:  return (nw + IslandConst.compactEar * 2, nh + IslandRestingLayout.compactExtraHeight)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        if view == .chat {
            return (IslandConst.expandedWidth,
                    ChatLayout.islandHeight(content: AppState.shared.chatContentHeight,
                                            empty: ChatService.shared.messages.isEmpty))
        }
        if view == .notes {
            return (IslandConst.expandedWidth, NotesLayout.islandHeight(list: AppState.shared.notesContentHeight))
        }
        if view == .approval || view == .question {
            return (IslandConst.expandedWidth, PromptLayout.islandHeight(content: AppState.shared.promptContentHeight))
        }
        if view == .harvest && AppState.shared.harvestListOpen {
            return (IslandConst.expandedWidth, IslandConst.harvestListHeight)
        }
        return (IslandConst.expandedWidth, layout.height)
    }
}
