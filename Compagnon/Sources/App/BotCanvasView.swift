import SwiftUI

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()

    var body: some View {
        // Full frame rate when the island is open; the 20 pt cloud of the compact bar
        // looks the same at 30 fps; nothing at all when hidden.
        TimelineView(.animation(minimumInterval: state.mode == .expanded ? nil : 1.0 / 30,
                                paused: state.mode == .hidden)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dtRaw = min(0.05, now - engine.lastTime)
                let dt = dtRaw
                let ptr = pointer(state: state)
                engine.lookX = ptr.lookX
                engine.lookY = ptr.lookY
                engine.pointerNear = ptr.near
                engine.pointerAngle = ptr.angle
                engine.particleOverhang = particleOverhang
                updateLife(now: now)
                // The main character is always the cloud. The focused pill only lends it
                // a hint of its colour from below; the state colour takes over when busy.
                engine.bodyColor = nil
                engine.accent = state.focusTask.flatMap { cgColorFromHex($0.color) }

                engine.update(dt: dt)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                engine.drawHandsBehind(context: ctx, size: size)
                engine.draw(context: ctx, size: size)
                engine.drawHandsAndExtras(context: ctx, size: size)
            }
        }
        .onChange(of: state.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .botPet)) { _ in
            engine.pet()
        }
        .onChange(of: state.mode) { _, newMode in
            // Hard-reset morph when island collapses
            if newMode != .expanded {
                engine.tweens.removeValue(forKey: "morph")
                engine.locks.remove("morph")
                engine.morph = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            if let emote = notif.object as? BotEmote {
                engine.triggerEmote(emote)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            engine.slap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            engine.blink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botSetTgEs)) { notif in
            if let v = notif.object as? CGFloat {
                engine.tgEs = v
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGulp)) { _ in
            engine.gulp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botMorphTo)) { notif in
            if let target = notif.object as? CGFloat {
                let dur: CGFloat = target > 0.5 ? 550 : 650
                engine.anim("morph", keys: [TweenKey(target: target, duration: dur, ease: Ease.inOut)])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            engine.greet()
        }
        .onAppear {
            engine.setState(state.effectiveState, force: true)
        }
    }

    /// Where the pointer is for the cloud: look direction, how close it is, from which side.
    private func pointer(state: AppState) -> (lookX: CGFloat, lookY: CGFloat, near: CGFloat, angle: CGFloat) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                islandW: islandW, islandH: islandH)
        // Island is centred on screen and glued to its top
        let dx = state.mousePosition.x - (screen.frame.midX - islandW / 2 + botCx)
        let dy = state.mousePosition.y - botCy
        let dist = hypot(dx, dy)
        let near = state.mode == .expanded ? max(0, min(1, 1 - (dist - 36) / 170)) : 0
        return (tanh(dx / 260), -tanh(dy / 200), near, atan2(dy, dx))
    }

    // MARK: Life signals (typing, Claude answering, naps, late hours)

    private func updateLife(now: Double) {
        let s = state
        let wall = Date()
        // You're typing in the chat or the notes: it watches the field
        engine.watchingField = (s.view == .chat || s.view == .notes) && s.mode == .expanded
            && wall.timeIntervalSince(s.typingAt) < 1.2
        // Claude's answer is streaming in: it "speaks"
        if wall.timeIntervalSince(s.claudeTalkingAt) < 0.3 { engine.talking = 1 }
        // Late evening: heavier eyelids (checked once a minute)
        if now - engine.lastHourCheck > 60 {
            let h = Calendar.current.component(.hour, from: wall)
            engine.drowsy = (h >= 22 || h < 6) ? 1 : 0
            engine.lastHourCheck = now
        }
        // Nap after 10 minutes without the pointer moving; wake up with a yawn
        let idle = wall.timeIntervalSince(s.lastMouseMove)
        let shouldNap = idle > 600 && s.effectiveState == .idle && s.mode != .expanded
        if shouldNap && !engine.napping {
            engine.napping = true
            engine.setState(.sleeping)
        } else if !shouldNap && engine.napping {
            engine.napping = false
            engine.setState(s.effectiveState)
            engine.triggerEmote(.yawn, duration: 1.4, silent: true)
        }
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    var isDancing: Bool = false
    @StateObject private var engine: BotEngine

    init(task: AgentTask, isDancing: Bool = false) {
        self.task = task
        self.isDancing = isDancing
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    var body: some View {
        // Mini-bots are 10–18 pt: 30 fps looks the same and halves the work
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt = min(0.05, now - engine.lastTime)
                engine.setDancing(isDancing)
                engine.update(dt: dt)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                engine.draw(context: ctx, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        .onAppear {
            engine.setState(task.state, force: true)
            if let emote = task.emote {
                engine.setPermanentEmote(emote)
            }
            // Direct eye override takes priority (e.g. .wide eyes for Research)
            if let eye = task.miniEye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
        }
    }
}

// MARK: - CGColor from hex string

func cgColorFromHex(_ hex: String) -> CGColor? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let val = UInt64(h, radix: 16) else { return nil }
    let r = CGFloat((val >> 16) & 0xFF) / 255
    let g = CGFloat((val >> 8)  & 0xFF) / 255
    let b = CGFloat( val        & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

extension CGColor {
    static func from(_ hex: String) -> CGColor {
        cgColorFromHex(hex) ?? CGColor(gray: 0.5, alpha: 1)
    }
}
