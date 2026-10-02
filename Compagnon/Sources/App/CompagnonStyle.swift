import SwiftUI
import CoreGraphics

// MARK: - Compagnon's look
// Single source of truth for the character's palette, silhouette and antenna.
// Used by the main bot (BotEngine), the greeting and the upload animation so the
// three renderers stay identical. All coordinates are body-local, y pointing down.

enum CompagnonStyle {
    // Body: soft mint, lighter at the top-right, deeper at the bottom-left.
    static let bodyTop    = CGColor(red: 0.925, green: 0.984, blue: 0.961, alpha: 1)  // #ECFBF5
    static let bodyBottom = CGColor(red: 0.722, green: 0.886, blue: 0.820, alpha: 1)  // #B8E2D1
    // Eyes: deep navy instead of black.
    static let ink        = CGColor(red: 0.078, green: 0.129, blue: 0.239, alpha: 1)  // #14213D
    // Antenna bulb when nothing is going on: warm coral, the character's signature.
    static let accent     = CGColor(red: 1.000, green: 0.420, blue: 0.290, alpha: 1)  // #FF6B4A

    static var bodyTopColor: Color    { Color(cgColor: bodyTop) }
    static var bodyBottomColor: Color { Color(cgColor: bodyBottom) }
    static var inkColor: Color        { Color(cgColor: ink) }

    // MARK: Silhouette — a gumdrop: rounder dome on top, flatter base

    static let topExponent: CGFloat    = 2.3
    static let bottomExponent: CGFloat = 3.6

    /// Point of the body outline at angle `a` (radians, 0 = right, π/2 = bottom).
    static func bodyPoint(angle a: CGFloat, rx: CGFloat, ry: CGFloat) -> CGPoint {
        let ca = cos(a), sa = sin(a)
        let n = sa > 0 ? bottomExponent : topExponent
        let e = 2 / n
        let px = rx * (ca < 0 ? -1 : 1) * pow(abs(ca), e)
        let py = ry * (sa < 0 ? -1 : 1) * pow(abs(sa), e)
        return CGPoint(x: px, y: py)
    }

    static func bodyCGPath(rx: CGFloat, ry: CGFloat, steps: Int = 96) -> CGPath {
        let path = CGMutablePath()
        for i in 0...steps {
            let p = bodyPoint(angle: CGFloat(i) / CGFloat(steps) * 2 * .pi, rx: rx, ry: ry)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: Antenna — a little stalk with a glowing bulb that shows Claude's state

    struct Antenna {
        let base: CGPoint
        let control: CGPoint
        let tip: CGPoint
        let stalkWidth: CGFloat
        let bulbRadius: CGFloat
    }

    /// Geometry for a body of half-height `ry`, bent by `angle` (radians, 0 = upright).
    static func antenna(ry: CGFloat, angle: CGFloat) -> Antenna {
        let length = ry * 0.50
        let base = CGPoint(x: 0, y: -ry * 0.96)
        let tip = CGPoint(x: base.x + sin(angle) * length,
                          y: base.y - cos(angle) * length)
        // The stalk stays upright at the base and bends towards the tip.
        let control = CGPoint(x: base.x + sin(angle) * length * 0.25,
                              y: base.y - length * 0.6)
        return Antenna(base: base, control: control, tip: tip,
                       stalkWidth: max(1, ry * 0.075), bulbRadius: ry * 0.15)
    }

    /// How brightly the bulb glows for a state, 0…1, pulsing over time.
    static func bulbGlow(_ state: BotState, time t: Double) -> CGFloat {
        switch state {
        case .approval, .question, .error:
            return CGFloat(0.6 + 0.4 * sin(t * 2 * .pi * 1.4))       // urgent blink
        case .working, .thinking, .searching:
            return CGFloat(0.55 + 0.25 * sin(t * 2 * .pi * 0.8))     // busy pulse
        case .sleeping:
            return 0.15
        default:
            return CGFloat(0.4 + 0.15 * sin(t * 2 * .pi * 0.25))     // slow breathing
        }
    }

    /// Draws the antenna in a SwiftUI canvas already translated to the body center.
    static func drawAntenna(_ ctx: GraphicsContext, _ a: Antenna, bulb: CGColor, glow: CGFloat, alpha: CGFloat = 1) {
        guard alpha > 0.01 else { return }
        var stalk = Path()
        stalk.move(to: a.base)
        stalk.addQuadCurve(to: a.tip, control: a.control)
        ctx.stroke(stalk, with: .color(inkColor.opacity(Double(0.85 * alpha))),
                   style: StrokeStyle(lineWidth: a.stalkWidth, lineCap: .round))

        let bulbColor = Color(cgColor: bulb)
        let haloR = a.bulbRadius * 2.6
        var halo = Path()
        halo.addEllipse(in: CGRect(x: a.tip.x - haloR, y: a.tip.y - haloR, width: haloR * 2, height: haloR * 2))
        ctx.fill(halo, with: .radialGradient(
            Gradient(colors: [bulbColor.opacity(Double(0.45 * glow * alpha)), bulbColor.opacity(0)]),
            center: a.tip, startRadius: 0, endRadius: haloR))

        let r = a.bulbRadius
        var ball = Path()
        ball.addEllipse(in: CGRect(x: a.tip.x - r, y: a.tip.y - r, width: r * 2, height: r * 2))
        ctx.fill(ball, with: .color(bulbColor.opacity(Double(alpha))))
        ctx.fill(ball, with: .radialGradient(
            Gradient(colors: [Color.white.opacity(Double((0.35 + 0.45 * glow) * alpha)), Color.white.opacity(0)]),
            center: CGPoint(x: a.tip.x + r * 0.3, y: a.tip.y - r * 0.35), startRadius: 0, endRadius: r * 0.9))
    }

    /// Same antenna for Core Graphics renderers (the greeting).
    static func drawAntenna(_ ctx: CGContext, _ a: Antenna, bulb: CGColor, glow: CGFloat, alpha: CGFloat = 1) {
        guard alpha > 0.01 else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(a.stalkWidth)
        ctx.setStrokeColor(ink.copy(alpha: 0.85 * alpha) ?? ink)
        ctx.beginPath()
        ctx.move(to: a.base)
        ctx.addQuadCurve(to: a.tip, control: a.control)
        ctx.strokePath()

        let cs = CGColorSpaceCreateDeviceRGB()
        let haloR = a.bulbRadius * 2.6
        let h0 = bulb.copy(alpha: 0.45 * glow * alpha) ?? bulb
        let h1 = bulb.copy(alpha: 0) ?? bulb
        if let g = CGGradient(colorsSpace: cs, colors: [h0, h1] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: a.tip, startRadius: 0,
                                   endCenter: a.tip, endRadius: haloR, options: [])
        }
        let r = a.bulbRadius
        ctx.setFillColor(bulb.copy(alpha: alpha) ?? bulb)
        ctx.fillEllipse(in: CGRect(x: a.tip.x - r, y: a.tip.y - r, width: r * 2, height: r * 2))
        let w0 = CGColor(red: 1, green: 1, blue: 1, alpha: (0.35 + 0.45 * glow) * alpha)
        let w1 = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        if let g = CGGradient(colorsSpace: cs, colors: [w0, w1] as CFArray, locations: [0, 1]) {
            let c = CGPoint(x: a.tip.x + r * 0.3, y: a.tip.y - r * 0.35)
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: a.tip.x - r, y: a.tip.y - r, width: r * 2, height: r * 2))
            ctx.clip()
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * 0.9, options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Small white reflection that makes the eyes look alive.
    static func catchlight(eyeWidth w: CGFloat, eyeHeight h: CGFloat) -> CGRect {
        let r = w * 0.17
        return CGRect(x: w * 0.12 - r, y: -h * 0.24 - r, width: r * 2, height: r * 2)
    }
}
