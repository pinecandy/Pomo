import Combine
import CoreGraphics

enum ScreenEdgeSide: Equatable {
    case left
    case right
}

/// Left/right screen-edge parking. Top and bottom never dock.
enum EdgeDock {
    /// Small sphere. The pill height was too large.
    static let diameter: CGFloat = 64
    /// How far the sphere sits past the bezel so it reads as attached.
    /// The face, including the countdown, stays on screen.
    static let tuck: CGFloat = 14

    static func side(frame: CGRect, screen: CGRect) -> ScreenEdgeSide? {
        let pastLeft = screen.minX - frame.minX
        let pastRight = frame.maxX - screen.maxX
        if pastLeft > 0.5 && pastLeft >= pastRight { return .left }
        if pastRight > 0.5 { return .right }
        return nil
    }

    static func parkedFrame(side: ScreenEdgeSide,
                            anchorMidY: CGFloat,
                            screen: CGRect,
                            visible: CGRect) -> CGRect {
        let x: CGFloat
        switch side {
        case .left:
            x = screen.minX - tuck
        case .right:
            x = screen.maxX - diameter + tuck
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
    @Published var docked = false
    @Published var side: ScreenEdgeSide = .right
}
