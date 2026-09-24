import Combine
import CoreGraphics

enum ScreenEdgeSide: Equatable {
    case left
    case right
}

/// Left/right screen-edge parking. Top and bottom never dock.
enum EdgeDock {
    /// The on-screen face. The countdown and the gauge ring live here.
    static let diameter: CGFloat = 64
    /// Rounded continuation past the bezel. A plain circle clipped by the
    /// screen edge reads as a circle set down beside the wall. This neck
    /// is the outer half of the capsule, so the body runs into the edge.
    static let neck: CGFloat = 32
    static var parkedSize: CGSize { CGSize(width: diameter + neck, height: diameter) }

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
            x = screen.minX - neck
        case .right:
            x = screen.maxX - diameter
        }
        var y = anchorMidY - diameter / 2
        let minY = visible.minY
        let maxY = visible.maxY - diameter
        if y < minY { y = minY }
        if y > maxY { y = maxY }
        return CGRect(x: x, y: y, width: parkedSize.width, height: parkedSize.height)
    }
}

@MainActor
final class EdgePresentation: ObservableObject {
    @Published var docked = false
    @Published var side: ScreenEdgeSide = .right
}
