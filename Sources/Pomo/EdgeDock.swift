import Combine
import CoreGraphics

enum ScreenEdgeSide: Equatable {
    case left
    case right
}

/// Left/right screen-edge parking. Top and bottom never dock.
enum EdgeDock {
    /// How much of the sphere stays on screen. The rest sits past the bezel.
    static let visibleFraction: CGFloat = 1.0 / 3.0

    /// Distance over which the pill becomes the sphere. Touching the edge is
    /// the middle of that travel, not the moment it swaps.
    static let approachDistance: CGFloat = 120

    static func side(frame: CGRect, screen: CGRect) -> ScreenEdgeSide? {
        let pastLeft = screen.minX - frame.minX
        let pastRight = frame.maxX - screen.maxX
        if pastLeft > 0.5 && pastLeft >= pastRight { return .left }
        if pastRight > 0.5 { return .right }
        return nil
    }

    /// 0 keeps the pill. 1 is the docked sphere. The nearer horizontal edge wins.
    static func progress(frame: CGRect, screen: CGRect) -> (side: ScreenEdgeSide, amount: CGFloat) {
        let left = approach(gap: frame.minX - screen.minX)
        let right = approach(gap: screen.maxX - frame.maxX)
        if left >= right { return (.left, left) }
        return (.right, right)
    }

    private static func approach(gap: CGFloat) -> CGFloat {
        let traveled = approachDistance - gap
        guard traveled > 0 else { return 0 }
        return min(1, traveled / (approachDistance * 2))
    }

    /// Sphere window. Horizontally flush with the screen bezel, vertically
    /// kept inside `visible` so the menu bar cannot cover the cap.
    static func parkedFrame(side: ScreenEdgeSide,
                            diameter: CGFloat,
                            anchorMidY: CGFloat,
                            screen: CGRect,
                            visible: CGRect) -> CGRect {
        let visibleWidth = diameter * visibleFraction
        let x: CGFloat
        switch side {
        case .left:
            x = screen.minX - (diameter - visibleWidth)
        case .right:
            x = screen.maxX - visibleWidth
        }
        var y = anchorMidY - diameter / 2
        let minY = visible.minY
        let maxY = visible.maxY - diameter
        if y < minY { y = minY }
        if y > maxY { y = maxY }
        return CGRect(x: x, y: y, width: diameter, height: diameter)
    }
}

@MainActor
final class EdgePresentation: ObservableObject {
    /// 0 = pill, 1 = black sphere. Tracks the drag, then eases to 0 or 1.
    @Published var progress: CGFloat = 0
    @Published var side: ScreenEdgeSide = .right
    @Published var parked = false
    /// True only for the release ease. A drag writes `progress` directly.
    @Published var animated = false
}
