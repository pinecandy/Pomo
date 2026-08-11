import AppKit
import XCTest

@testable import Pomo

/// `centeredPillRect(in:pillSize:)` and `centeredGlassRect(in:)` — the AppKit
/// half of the geometry system, where the pill and the live blur have to agree
/// on the same rect down to the pixel.
final class PillLayoutRectTests: XCTestCase {

    /// medium / 2-digit: pill 296 × 98, window 344 × 146. Chosen because both
    /// pill dimensions are even, so every leftover parity below comes from the
    /// bounds and not from the pill.
    private let layout = PillLayout(sizeClass: .medium, minuteDigits: 2)

    private func allLayouts() -> [PillLayout] {
        PomoSize.allCases.flatMap { size in
            [2, 3].map { PillLayout(sizeClass: size, minuteDigits: $0) }
        }
    }

    private func label(_ layout: PillLayout) -> String {
        "\(layout.sizeClass)/\(layout.minuteDigits)-digit"
    }

    // MARK: - centeredPillRect

    func test_centeredPillRect_withAnEvenLeftover_centersExactlyAndKeepsThePillSize() {
        // Bounds derived from the pill so this stays about CENTRING, not about
        // whatever the pill currently measures (that is the golden table's job).
        let bounds = NSRect(x: 0, y: 0, width: layout.pillW + 100, height: layout.pillH + 100)
        let rect = PillLayout.centeredPillRect(in: bounds, pillSize: layout.pillSize)

        XCTAssertEqual(rect.size, layout.pillSize)
        XCTAssertEqual(rect.origin.x, 50)
        XCTAssertEqual(rect.origin.y, 50)
        XCTAssertEqual(bounds.maxX - rect.maxX, rect.minX, "left and right margins differ")
        XCTAssertEqual(bounds.maxY - rect.maxY, rect.minY, "top and bottom margins differ")
    }

    /// The rect must actually track the bounds it is given — an implementation
    /// that ignored `bounds` and used a stored size would satisfy every
    /// centring assertion that only ever passes the pill's own window.
    func test_centeredPillRect_whenTheBoundsGrow_shiftsByHalfTheExtraSpace() {
        for layout in allLayouts() {
            let own = NSRect(origin: .zero, size: layout.windowSize)
            let grown = NSRect(x: 0, y: 0,
                               width: layout.windowSize.width + 100,
                               height: layout.windowSize.height + 40)
            let atRest = PillLayout.centeredPillRect(in: own, pillSize: layout.pillSize)
            let moved = PillLayout.centeredPillRect(in: grown, pillSize: layout.pillSize)

            XCTAssertEqual(moved.size, atRest.size,
                           "\(label(layout)) the pill size must not depend on the bounds")
            XCTAssertEqual(moved.minX - atRest.minX, 50, "\(label(layout)) x did not re-centre")
            XCTAssertEqual(moved.minY - atRest.minY, 20, "\(label(layout)) y did not re-centre")
        }
    }

    /// In the app's own window the pill sits exactly one shadow margin in from
    /// every edge.
    func test_centeredPillRect_inItsOwnWindow_sitsOneShadowMarginFromEveryEdge() {
        for layout in allLayouts() {
            let bounds = NSRect(origin: .zero, size: layout.windowSize)
            let rect = PillLayout.centeredPillRect(in: bounds, pillSize: layout.pillSize)
            let shadow = layout.spacing.shadow
            XCTAssertEqual(rect.minX, shadow, "\(label(layout)) left")
            XCTAssertEqual(rect.minY, shadow, "\(label(layout)) bottom")
            XCTAssertEqual(bounds.maxX - rect.maxX, shadow, "\(label(layout)) right")
            XCTAssertEqual(bounds.maxY - rect.maxY, shadow, "\(label(layout)) top")
        }
    }

    /// Half-point leftover: the rect must land on a whole point, or the VEV
    /// mask renders on a half pixel and the capsule edge goes soft.
    func test_centeredPillRect_withAHalfPointLeftover_snapsToAWholePoint() {
        // The pill is always on the 2pt grid, so an ODD bounds dimension is
        // what produces the half-point leftover.
        XCTAssertEqual(layout.pillW.truncatingRemainder(dividingBy: 2), 0, "precondition")
        XCTAssertEqual(layout.pillH.truncatingRemainder(dividingBy: 2), 0, "precondition")

        let bounds = NSRect(x: 0, y: 0, width: layout.pillW + 1, height: layout.pillH + 1)
        let rect = PillLayout.centeredPillRect(in: bounds, pillSize: layout.pillSize)
        XCTAssertEqual(rect.origin.x, 0)
        XCTAssertEqual(rect.origin.y, 0)
        XCTAssertEqual(rect.size, layout.pillSize, "snapping must not resize the pill")
    }

    /// The snap is to-nearest-or-EVEN (banker's rounding), not away-from-zero:
    /// a 2.5pt leftover goes DOWN to 2 while a 3.5pt leftover goes UP to 4.
    /// Plain `.rounded()` would give 3 and 4 — a silent 1pt shift.
    func test_centeredPillRect_atAHalfPointTie_roundsToEvenRatherThanAwayFromZero() {
        let downwards = PillLayout.centeredPillRect(
            in: NSRect(x: 0, y: 0, width: layout.pillW + 5, height: layout.pillH + 5),
            pillSize: layout.pillSize)
        XCTAssertEqual(downwards.origin.x, 2, "2.5 must tie down to 2")
        XCTAssertEqual(downwards.origin.y, 2, "2.5 must tie down to 2")

        let upwards = PillLayout.centeredPillRect(
            in: NSRect(x: 0, y: 0, width: layout.pillW + 7, height: layout.pillH + 7),
            pillSize: layout.pillSize)
        XCTAssertEqual(upwards.origin.x, 4, "3.5 must tie up to 4")
        XCTAssertEqual(upwards.origin.y, 4, "3.5 must tie up to 4")
    }

    /// The two axes are snapped independently — a shared rounding decision
    /// would be invisible whenever both leftovers happen to have the same
    /// parity, which is every case above.
    func test_centeredPillRect_withMixedParityLeftovers_snapsEachAxisOnItsOwn() {
        let rect = PillLayout.centeredPillRect(
            in: NSRect(x: 0, y: 0, width: layout.pillW + 4, height: layout.pillH + 5),
            pillSize: layout.pillSize)
        XCTAssertEqual(rect.origin.x, 2, "an even leftover must not be rounded")
        XCTAssertEqual(rect.origin.y, 2, "2.5 must tie down to 2 on the y axis too")

        let swapped = PillLayout.centeredPillRect(
            in: NSRect(x: 0, y: 0, width: layout.pillW + 7, height: layout.pillH + 6),
            pillSize: layout.pillSize)
        XCTAssertEqual(swapped.origin.x, 4, "3.5 must tie up to 4 on the x axis")
        XCTAssertEqual(swapped.origin.y, 3, "an odd whole leftover must not be rounded")
    }

    /// Every leftover parity: always a whole point, always the full pill size,
    /// and never off-centre by more than the half point that was snapped away.
    func test_centeredPillRect_atEveryLeftoverParity_landsOnWholePointsAndStaysCentred() {
        for extra in 0...9 {
            let bounds = NSRect(x: 0, y: 0,
                                width: layout.pillW + CGFloat(extra),
                                height: layout.pillH + CGFloat(extra))
            let rect = PillLayout.centeredPillRect(in: bounds, pillSize: layout.pillSize)

            XCTAssertEqual(rect.size, layout.pillSize, "extra \(extra) resized the pill")
            XCTAssertEqual(rect.origin.x, rect.origin.x.rounded(), "extra \(extra) x is fractional")
            XCTAssertEqual(rect.origin.y, rect.origin.y.rounded(), "extra \(extra) y is fractional")
            XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.5, "extra \(extra) off-centre in x")
            XCTAssertEqual(rect.midY, bounds.midY, accuracy: 0.5, "extra \(extra) off-centre in y")
            XCTAssertGreaterThanOrEqual(rect.minX, 0, "extra \(extra) overflows the bounds")
            XCTAssertGreaterThanOrEqual(rect.minY, 0, "extra \(extra) overflows the bounds")
        }
    }

    /// Degenerate input: bounds smaller than the pill. The pill keeps its size
    /// (it is never squashed to fit) and overflows symmetrically.
    func test_centeredPillRect_withBoundsSmallerThanThePill_keepsThePillSizeAndOverflowsEvenly() {
        let bounds = NSRect(x: 0, y: 0, width: layout.pillW / 2, height: layout.pillH / 2)
        let rect = PillLayout.centeredPillRect(in: bounds, pillSize: layout.pillSize)

        XCTAssertEqual(rect.size, layout.pillSize, "the pill must never be squashed to fit")
        XCTAssertLessThan(rect.minX, 0, "too-narrow bounds should overflow, not clamp")
        XCTAssertLessThan(rect.minY, 0, "too-short bounds should overflow, not clamp")
        XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.5)
        XCTAssertEqual(rect.midY, bounds.midY, accuracy: 0.5)
    }

    /// Empty input: a zero-sized bounds still yields a full-sized pill rect
    /// rather than a zero or NaN rect.
    func test_centeredPillRect_withZeroSizedBounds_stillReturnsAFullSizedRect() {
        let rect = PillLayout.centeredPillRect(in: .zero, pillSize: layout.pillSize)
        XCTAssertEqual(rect.size, layout.pillSize)
        XCTAssertFalse(rect.origin.x.isNaN)
        XCTAssertFalse(rect.origin.y.isNaN)
        XCTAssertEqual(rect.origin.x, -layout.pillW / 2)
        XCTAssertEqual(rect.origin.y, -layout.pillH / 2)
        XCTAssertEqual(rect.midX, 0, accuracy: 0.5)
        XCTAssertEqual(rect.midY, 0, accuracy: 0.5)
    }

    /// Empty input, the other way round: a zero pill in real bounds collapses
    /// to a zero-sized rect at the centre rather than to garbage.
    func test_centeredPillRect_withAZeroSizedPill_returnsAnEmptyRectAtTheCentre() {
        let bounds = NSRect(x: 0, y: 0, width: 344, height: 146)
        let rect = PillLayout.centeredPillRect(in: bounds, pillSize: .zero)
        XCTAssertEqual(rect.size, NSSize.zero)
        XCTAssertEqual(rect.origin.x, 172)
        XCTAssertEqual(rect.origin.y, 73)
    }

    /// Regression: `centeredPillRect` used to treat `bounds` as if its origin
    /// were (0, 0), centring on the SIZE and silently ignoring the position.
    /// Every current caller passes `container.bounds` or an explicitly
    /// zero-origin rect, so nothing was visibly broken — this pins the
    /// contract the signature and the doc comment both advertise, so the trap
    /// cannot come back for the next caller.
    func test_centeredPillRect_withBoundsAwayFromTheOrigin_centersInsideThoseBounds() {
        let bounds = NSRect(x: 100, y: 50, width: 500, height: 300)
        let rect = PillLayout.centeredPillRect(in: bounds, pillSize: layout.pillSize)
        XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.5)
        XCTAssertEqual(rect.midY, bounds.midY, accuracy: 0.5)
    }

    // MARK: - centeredGlassRect

    func test_centeredGlassRect_isThePillRectInsetByTheRimGuardOnAllFourSides() {
        for layout in allLayouts() {
            let bounds = NSRect(origin: .zero, size: layout.windowSize)
            let pill = PillLayout.centeredPillRect(in: bounds, pillSize: layout.pillSize)
            let glass = layout.centeredGlassRect(in: bounds)
            let rim = layout.spacing.rim

            XCTAssertEqual(rim, 4, "\(label(layout)) the rim guard moved")
            XCTAssertEqual(glass.minX - pill.minX, rim, "\(label(layout)) left rim")
            XCTAssertEqual(pill.maxX - glass.maxX, rim, "\(label(layout)) right rim")
            XCTAssertEqual(glass.minY - pill.minY, rim, "\(label(layout)) bottom rim")
            XCTAssertEqual(pill.maxY - glass.maxY, rim, "\(label(layout)) top rim")
        }
    }

    func test_centeredGlassRect_sharesItsCentreWithThePillRect() {
        for layout in allLayouts() {
            let bounds = NSRect(origin: .zero, size: layout.windowSize)
            let pill = PillLayout.centeredPillRect(in: bounds, pillSize: layout.pillSize)
            let glass = layout.centeredGlassRect(in: bounds)
            XCTAssertEqual(glass.midX, pill.midX, "\(label(layout)) x centre drifted")
            XCTAssertEqual(glass.midY, pill.midY, "\(label(layout)) y centre drifted")
        }
    }

    /// The blur has to stay clear of the window edge by the shadow margin plus
    /// the rim, or the `.behindWindow` material clips against the window.
    func test_centeredGlassRect_keepsTheShadowMarginAndRimClearOnEveryEdge() {
        for layout in allLayouts() {
            let bounds = NSRect(origin: .zero, size: layout.windowSize)
            let glass = layout.centeredGlassRect(in: bounds)
            let clearance = layout.spacing.shadow + layout.spacing.rim

            XCTAssertEqual(glass.minX, clearance, "\(label(layout)) left")
            XCTAssertEqual(glass.minY, clearance, "\(label(layout)) bottom")
            XCTAssertEqual(bounds.maxX - glass.maxX, clearance, "\(label(layout)) right")
            XCTAssertEqual(bounds.maxY - glass.maxY, clearance, "\(label(layout)) top")
            XCTAssertTrue(bounds.contains(glass), "\(label(layout)) glass escaped the window")
        }
    }

    func test_centeredGlassRect_hasWholePointOriginAndSize_soTheMaskIsNeverHalfPixelCentred() {
        for layout in allLayouts() {
            let glass = layout.centeredGlassRect(in: NSRect(origin: .zero, size: layout.windowSize))
            XCTAssertEqual(glass.minX, glass.minX.rounded(), "\(label(layout)) x")
            XCTAssertEqual(glass.minY, glass.minY.rounded(), "\(label(layout)) y")
            XCTAssertEqual(glass.width, glass.width.rounded(), "\(label(layout)) width")
            XCTAssertEqual(glass.height, glass.height.rounded(), "\(label(layout)) height")
        }
    }

    /// The VEV must be able to hold the whole content box with both insets.
    func test_centeredGlassRect_isLargeEnoughForTheContentAndItsInsets() {
        for layout in allLayouts() {
            let glass = layout.centeredGlassRect(in: NSRect(origin: .zero, size: layout.windowSize))
            XCTAssertGreaterThanOrEqual(glass.width, layout.contentW + 2 * layout.insetH,
                                        "\(label(layout)) width")
            XCTAssertGreaterThanOrEqual(glass.height,
                                        layout.contentH + 2 * layout.spacing.insetV,
                                        "\(label(layout)) height")
        }
    }

    /// The rim guard exists "so the material edge tucks under the SwiftUI
    /// capsule", and PomoView draws that capsule at exactly `glassW × glassH`.
    /// Width holds exactly at every size class.
    func test_centeredGlassRect_widthMatchesTheSwiftUIGlassWidthExactly() {
        for layout in allLayouts() {
            let glass = layout.centeredGlassRect(in: NSRect(origin: .zero, size: layout.windowSize))
            XCTAssertEqual(glass.width, layout.glassW, "\(label(layout))")
        }
    }

    /// KNOWN DEFECT (see bugsFound): the same must hold vertically, but
    /// `glassH` is odd at every size class (73 / 89 / 107) and
    /// `pillH = ceil2(glassH + 2·rim)` rounds that odd sum up by 1, handing the
    /// extra point to the VEV. The blur therefore sticks out 0.5pt above and
    /// below the SwiftUI capsule that is supposed to cover it — and
    /// `CapsuleMask` derives its corner radius from that 1pt-taller height, so
    /// the blur's corners are rounder than the SwiftUI overlays too.
    func test_centeredGlassRect_heightMatchesTheSwiftUIGlassHeightExactly() {
        for layout in allLayouts() {
            let glass = layout.centeredGlassRect(in: NSRect(origin: .zero,
                                                            size: layout.windowSize))
            XCTAssertEqual(glass.height, layout.glassH, "\(label(layout))")
        }
    }

    /// The consequence that made the height defect visible: `CapsuleMask`
    /// takes its corner radius from the rect it is handed, while PomoView
    /// takes its overlay radius from `glassH`. While the two heights
    /// disagreed the blur's corners were rounder than the capsule's. Both
    /// axes must now agree exactly, on every size class and digit count.
    func test_theBlurMaskAndTheSwiftUICapsule_agreeOnBothSizeAndCornerRadius() {
        for layout in allLayouts() {
            let glass = layout.centeredGlassRect(in: NSRect(origin: .zero, size: layout.windowSize))
            XCTAssertEqual(glass.height, layout.glassH, "\(label(layout)) height")
            XCTAssertEqual(glass.width, layout.glassW, "\(label(layout)) width")

            let maskRadius = glass.height * Tokens.Decor.cornerFactor
            let swiftUIRadius = layout.glassH * Tokens.Decor.cornerFactor
            XCTAssertEqual(maskRadius, swiftUIRadius, accuracy: 1e-12,
                           "\(label(layout)) the blur's corners are not the capsule's corners")
        }
    }

    /// Whatever the resolution of the height defect above, the drawn glass must
    /// never be SMALLER than the SwiftUI capsule (that would expose unblurred
    /// wallpaper inside the pill) and never overshoot by a whole grid step.
    func test_centeredGlassRect_isNeverSmallerThanTheSwiftUIGlassNorAWholeStepLarger() {
        for layout in allLayouts() {
            let glass = layout.centeredGlassRect(in: NSRect(origin: .zero, size: layout.windowSize))
            XCTAssertGreaterThanOrEqual(glass.width, layout.glassW, "\(label(layout)) width")
            XCTAssertGreaterThanOrEqual(glass.height, layout.glassH, "\(label(layout)) height")
            XCTAssertLessThan(glass.width - layout.glassW, 2, "\(label(layout)) width")
            XCTAssertLessThan(glass.height - layout.glassH, 2, "\(label(layout)) height")
        }
    }

    /// Regression guard for the resize path: `TimerInstanceController` computes
    /// the glass rect from a freshly built `NSRect(origin: .zero, size: winSize)`
    /// during a size change and from `container.bounds` at rest. Both are
    /// origin-zero rects of the window's own size, so what actually has to hold
    /// is that the glass follows the LAYOUT it is asked for: computing the new
    /// layout's glass against the OLD window's bounds must give a different,
    /// wrong rect — proving the controller cannot get away with a stale bounds.
    func test_centeredGlassRect_computedAgainstAStaleWindowBounds_doesNotSilentlyMatch() {
        let ladder: [PomoSize] = [.small, .medium, .large]
        for index in 1..<ladder.count {
            let old = PillLayout(sizeClass: ladder[index - 1], minuteDigits: 2)
            let new = PillLayout(sizeClass: ladder[index], minuteDigits: 2)

            let correct = new.centeredGlassRect(in: NSRect(origin: .zero, size: new.windowSize))
            let stale = new.centeredGlassRect(in: NSRect(origin: .zero, size: old.windowSize))

            XCTAssertEqual(correct.size, stale.size,
                           "\(old.sizeClass)→\(new.sizeClass) glass size must come from the layout")
            XCTAssertNotEqual(correct.origin, stale.origin,
                              "\(old.sizeClass)→\(new.sizeClass) glass origin ignores its bounds")
            XCTAssertEqual(correct.minX, new.spacing.shadow + new.spacing.rim,
                           "\(new.sizeClass) correct rect is not one shadow+rim in")
        }
    }
}
