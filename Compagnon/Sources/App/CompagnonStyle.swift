import SwiftUI
import CoreGraphics

// MARK: - Compagnon's look
// Single source of truth for the character's palette, silhouette and antenna.
// Used by the main bot (BotEngine), the greeting and the upload animation so the
// three renderers stay identical. All coordinates are body-local, y pointing down.

enum CompagnonStyle {
    // Body: a white cloud, lavender in its shadows. The state colour rises from below.
    static let bodyTop    = CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1)  // #FFFFFF
    static let bodyBottom = CGColor(red: 0.851, green: 0.851, blue: 0.957, alpha: 1)  // #D9D9F4
    // Eyes: deep blue-grey instead of black.
    static let ink        = CGColor(red: 0.149, green: 0.165, blue: 0.267, alpha: 1)  // #262A44

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

    // MARK: Cloud — the main character's silhouette
    // Five overlapping puffs (unit space: x −1.06…1.06, y −0.78…0.84). The outline is
    // where a ray from the centre leaves the last puff, so it stays one smooth shape.

    static let cloudPuffs: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (-0.60, 0.18, 0.46), (0.60, 0.18, 0.46), (-0.24, -0.20, 0.58), (0.30, -0.12, 0.52), (0.00, 0.24, 0.60),
    ]

    /// Point of the cloud outline at angle `a`, fitted to a box of half-size rx × ry.
    /// `puff` breathes the puffs (1 = rest), `phase` lets each puff move on its own.
    /// `boosts` swells individual puffs (the one nearest the pointer, a ripple on click).
    static func cloudPoint(angle a: CGFloat, rx: CGFloat, ry: CGFloat, puff: CGFloat = 1, phase: CGFloat = 0,
                           boosts: [CGFloat] = []) -> CGPoint {
        let dx = cos(a), dy = sin(a)
        var best: CGFloat = 0
        for (i, p) in cloudPuffs.enumerated() {
            let boost = i < boosts.count ? boosts[i] : 0
            let r = p.r * (puff + 0.012 * sin(phase * 2 + CGFloat(i)) + boost)
            let b = dx * p.x + dy * p.y
            let disc = b * b - (p.x * p.x + p.y * p.y - r * r)
            if disc >= 0 { best = max(best, b + sqrt(disc)) }
        }
        // unit box is 1.06 wide and 0.81 tall around y = 0.03
        return CGPoint(x: dx * best * rx / 1.06, y: (dy * best - 0.03) * ry / 0.81)
    }

    static func cloudCGPath(rx: CGFloat, ry: CGFloat, puff: CGFloat = 1, phase: CGFloat = 0, steps: Int = 120) -> CGPath {
        let path = CGMutablePath()
        for i in 0...steps {
            let p = cloudPoint(angle: CGFloat(i) / CGFloat(steps) * 2 * .pi, rx: rx, ry: ry, puff: puff, phase: phase)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}
