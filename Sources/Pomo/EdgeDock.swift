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

    static func side(frame: CGRect, screen: CGRect) -> ScreenEdgeSide? {
        let pastLeft = screen.minX - frame.minX
        let pastRight = frame.maxX - screen.maxX
        if pastLeft > 0.5 && pastLeft >= pastRight { return .left }
        if pastRight > 0.5 { return .right }
        return nil
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

enum EdgeSphereStyle: Equatable {
    /// Pill window, black sphere drawn in its center while crossing an edge.
    case approaching
    /// Window is the sphere, mostly past the bezel.
    case parked
}

@MainActor
final class EdgePresentation: ObservableObject {
    @Published var style: EdgeSphereStyle?
}
