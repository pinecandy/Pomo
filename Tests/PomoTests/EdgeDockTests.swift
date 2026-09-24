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

    func test_progress_isHalfwayWhenTheFrameTouchesTheEdge() {
        let touching = CGRect(x: 1000 - 200, y: 100, width: 200, height: 80)
        let approach = EdgeDock.progress(frame: touching, screen: screen)
        XCTAssertEqual(approach.side, .right)
        XCTAssertEqual(approach.amount, 0.5, accuracy: 0.001)
    }

    func test_progress_staysAtThePillWhenFarFromEitherEdge() {
        let middle = CGRect(x: 400, y: 100, width: 200, height: 80)
        XCTAssertEqual(EdgeDock.progress(frame: middle, screen: screen).amount, 0, accuracy: 0.001)
    }

    func test_parkedFrame_showsOneThirdAndJoinsTheBezel() {
        let diameter: CGFloat = 90
        let left = EdgeDock.parkedFrame(side: .left, diameter: diameter, anchorMidY: 400,
                                        screen: screen, visible: visible)
        let right = EdgeDock.parkedFrame(side: .right, diameter: diameter, anchorMidY: 400,
                                         screen: screen, visible: visible)
        XCTAssertEqual(left.maxX - screen.minX, diameter / 3, accuracy: 0.001)
        XCTAssertEqual(screen.maxX - right.minX, diameter / 3, accuracy: 0.001)
        XCTAssertEqual(left.midY, 400, accuracy: 0.001)
    }
}