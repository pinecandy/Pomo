import CoreGraphics
import XCTest

@testable import Pomo

final class EdgeDockTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let visible = CGRect(x: 0, y: 40, width: 1000, height: 730)

    func test_side_ignoresVerticalOverflow() {
        let above = CGRect(x: 100, y: 790, width: 200, height: 40)
        XCTAssertNil(EdgeDock.side(frame: above, screen: screen))
    }

    func test_side_picksTheCrossedHorizontalEdge() {
        let left = CGRect(x: -4, y: 100, width: 200, height: 80)
        let right = CGRect(x: 900, y: 100, width: 200, height: 80)
        XCTAssertEqual(EdgeDock.side(frame: left, screen: screen), .left)
        XCTAssertEqual(EdgeDock.side(frame: right, screen: screen), .right)
        XCTAssertNil(EdgeDock.side(frame: CGRect(x: 100, y: 100, width: 200, height: 80), screen: screen))
    }

    func test_parkedFrame_isASmallCircleTuckedIntoTheBezel() {
        let frame = EdgeDock.parkedFrame(side: .right, anchorMidY: 400, screen: screen, visible: visible)
        XCTAssertEqual(frame.width, EdgeDock.diameter)
        XCTAssertEqual(frame.height, EdgeDock.diameter)
        XCTAssertLessThan(EdgeDock.diameter, 80)
        XCTAssertEqual(frame.maxX - screen.maxX, EdgeDock.tuck, accuracy: 0.001)
        XCTAssertGreaterThan(screen.maxX - frame.minX, frame.width / 2)
        XCTAssertEqual(frame.midY, 400, accuracy: 0.001)
    }
}