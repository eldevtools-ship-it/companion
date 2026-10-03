import Foundation

/// Resting island dimensions, using a physical notch only when the screen has one.
struct IslandScreenGeometry {
    static let fallbackNotchWidth: CGFloat = 184
    private static let noNotchWidth: CGFloat = 80
    private static let noNotchHeight: CGFloat = 24

    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    init(screenWidth: CGFloat, safeAreaTop: CGFloat,
         auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?,
         menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measuredWidth = screenWidth - left - right
                width = measuredWidth > 0 && measuredWidth < screenWidth
                    ? measuredWidth : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }
}

/// Shared by the compact view and the greeting's collapse destination.
struct IslandRestingLayout {
    /// Width of each "ear" either side of the notch when compact (bot left, minis right).
    static let compactEar: CGFloat = 42
    /// The compact bar hangs this much below the notch, so the bots get some air.
    static let compactExtraHeight: CGFloat = 2

    let width: CGFloat
    let height: CGFloat

    /// Mini-bot grid: 2 × 2 bots of `miniSize`, `miniGap` apart.
    static let miniSize: CGFloat = 10
    static let miniGap: CGFloat = 3
    static var miniGridSide: CGFloat { miniSize * 2 + miniGap }

    /// The cloud is 0.88 D tall: this leaves about 6 pt above and below it.
    var botDiameter: CGFloat { min(20, max(0, height - 12)) }
    /// The cloud's centre sits 0.03 D below the canvas centre: lift it back to the middle.
    var botCenterY: CGFloat { height / 2 - botDiameter * 0.03 }
    var miniGridScale: CGFloat { min(1, max(0, height - 11) / Self.miniGridSide) }
    var miniGridCenterX: CGFloat { width - Self.compactEar / 2 }
}
