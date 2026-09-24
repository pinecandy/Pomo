import AppKit
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

    func test_parkedFrame_keepsTheFaceOnScreenAndRunsTheNeckPastTheBezel() {
        let right = EdgeDock.parkedFrame(side: .right, anchorMidY: 400, screen: screen, visible: visible)
        let left = EdgeDock.parkedFrame(side: .left, anchorMidY: 400, screen: screen, visible: visible)
        XCTAssertEqual(right.width, EdgeDock.diameter + EdgeDock.neck)
        XCTAssertEqual(right.height, EdgeDock.diameter)
        XCTAssertEqual(screen.maxX - right.minX, EdgeDock.diameter, accuracy: 0.001)
        XCTAssertEqual(right.maxX - screen.maxX, EdgeDock.neck, accuracy: 0.001)
        XCTAssertEqual(left.maxX - screen.minX, EdgeDock.diameter, accuracy: 0.001)
        XCTAssertEqual(screen.minX - left.minX, EdgeDock.neck, accuracy: 0.001)
    }

    func test_flexibleMarginsShiftTheGlassWhenTheWindowGrows() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let glass = NSView(frame: NSRect(x: 8, y: 20, width: 48, height: 24))
        glass.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        parent.addSubview(glass)

        parent.setFrameSize(NSSize(width: 420, height: 140))

        XCTAssertNotEqual(glass.frame.origin.y, 20)
    }

    func test_glassKeepsTheCenteredRectWhenItDoesNotAutoresize() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let glass = NSView(frame: .zero)
        glass.autoresizingMask = []
        parent.addSubview(glass)
        parent.setFrameSize(NSSize(width: 420, height: 140))

        let layout = PillLayout(sizeClass: .medium, minuteDigits: 2)
        let target = layout.centeredGlassRect(in: parent.bounds)
        glass.frame = target

        XCTAssertEqual(glass.frame, target)
    }

    /// The dock cycle: the blur is given the full-size rect while the window
    /// is still the small circle, then the window grows. Flexible margins walk
    /// that rect. Empty autoresizing plus a placement after the resize does not.
    func test_repeatedDockResizes_keepTheGlassOnThePill() throws {
        let layout = PillLayout(sizeClass: .medium, minuteDigits: 2)
        let full = layout.windowSize
        let drifted = glassFrame(afterDockCycles: 6, layout: layout, full: full, lockFrame: false)
        let aligned = glassFrame(afterDockCycles: 6, layout: layout, full: full, lockFrame: true)
        let correct = layout.centeredGlassRect(in: NSRect(origin: .zero, size: full))

        try writeGlassShot(glass: drifted, correct: correct, size: full, name: "glass-drift")
        try writeGlassShot(glass: aligned, correct: correct, size: full, name: "glass-aligned")

        XCTAssertNotEqual(drifted, correct)
        XCTAssertEqual(aligned, correct)
    }

    private func glassFrame(afterDockCycles count: Int, layout: PillLayout, full: NSSize,
                            lockFrame: Bool) -> NSRect {
        let small = NSSize(width: EdgeDock.diameter, height: EdgeDock.diameter)
        let parent = NSView(frame: NSRect(origin: .zero, size: small))
        let glass = NSView(frame: parent.bounds)
        glass.autoresizingMask = lockFrame ? [] : [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        parent.addSubview(glass)
        for _ in 0..<count {
            glass.frame = layout.centeredGlassRect(in: NSRect(origin: .zero, size: full))
            parent.setFrameSize(full)
            if lockFrame {
                glass.frame = layout.centeredGlassRect(in: parent.bounds)
            }
            parent.setFrameSize(small)
        }
        parent.setFrameSize(full)
        if lockFrame {
            glass.frame = layout.centeredGlassRect(in: parent.bounds)
        }
        return glass.frame
    }

    private func writeGlassShot(glass: NSRect, correct: NSRect, size: NSSize, name: String) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.systemGreen.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: glass, xRadius: 18, yRadius: 18).fill()
        NSColor.white.setStroke()
        let outline = NSBezierPath(roundedRect: correct.insetBy(dx: 6, dy: 6), xRadius: 16, yRadius: 16)
        outline.lineWidth = 2
        outline.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(name)")
            return
        }
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}