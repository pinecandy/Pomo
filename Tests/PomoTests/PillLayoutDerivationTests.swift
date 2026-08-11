import AppKit
import XCTest

@testable import Pomo

/// The one-way derivation chain
/// `{sizeClass, minuteDigits} → tokens → contentW/H → glass → pill → window`,
/// plus the two rounding rules that feed it (`ceil2`, `minuteDigits`).
///
/// Pure arithmetic: no clock, no files, no UserDefaults.
final class PillLayoutDerivationTests: XCTestCase {

    // MARK: - Fixtures

    private func allLayouts() -> [PillLayout] {
        PomoSize.allCases.flatMap { size in
            [2, 3].map { PillLayout(sizeClass: size, minuteDigits: $0) }
        }
    }

    private func label(_ layout: PillLayout) -> String {
        "\(layout.sizeClass)/\(layout.minuteDigits)-digit"
    }

    /// Frozen numeric table — the golden guard against silent drift. These are
    /// the dimensions the pill actually renders today; if a token moves, this
    /// fails first and names the axis.
    private struct Golden {
        let size: PomoSize
        let digits: Int
        let countdownW: CGFloat
        let segClusterW: CGFloat
        let contentW: CGFloat
        let contentH: CGFloat
        let glassW: CGFloat
        let glassH: CGFloat
        let pillW: CGFloat
        let pillH: CGFloat
        let windowW: CGFloat
        let windowH: CGFloat
    }

    private static let goldenTable: [Golden] = [
        Golden(size: .small, digits: 2, countdownW: 52, segClusterW: 136,
               contentW: 198, contentH: 49, glassW: 230, glassH: 74,
               pillW: 238, pillH: 82, windowW: 286, windowH: 130),
        Golden(size: .small, digits: 3, countdownW: 64, segClusterW: 136,
               contentW: 210, contentH: 49, glassW: 242, glassH: 74,
               pillW: 250, pillH: 82, windowW: 298, windowH: 130),
        Golden(size: .medium, digits: 2, countdownW: 66, segClusterW: 170,
               contentW: 248, contentH: 57, glassW: 288, glassH: 90,
               pillW: 296, pillH: 98, windowW: 344, windowH: 146),
        Golden(size: .medium, digits: 3, countdownW: 80, segClusterW: 170,
               contentW: 262, contentH: 57, glassW: 302, glassH: 90,
               pillW: 310, pillH: 98, windowW: 358, windowH: 146),
        Golden(size: .large, digits: 2, countdownW: 78, segClusterW: 204,
               contentW: 296, contentH: 67, glassW: 344, glassH: 108,
               pillW: 352, pillH: 116, windowW: 400, windowH: 164),
        Golden(size: .large, digits: 3, countdownW: 96, segClusterW: 204,
               contentW: 314, contentH: 67, glassW: 362, glassH: 108,
               pillW: 370, pillH: 116, windowW: 418, windowH: 164),
    ]

    // MARK: - The size-class ladder these tables are indexed by

    /// Several tests below (and `contentW`'s own `max`) assume exactly three
    /// size classes in ascending order; a fourth would silently escape the
    /// frozen table.
    func test_thePomoSizeLadder_hasExactlyThreeClassesInAscendingOrder() {
        XCTAssertEqual(PomoSize.allCases, [.small, .medium, .large])
        XCTAssertEqual(PomoSize.next(after: .small), .medium)
        XCTAssertEqual(PomoSize.next(after: .medium), .large)
        XCTAssertEqual(PomoSize.next(after: .large), .large, "the ladder must saturate at the top")
        XCTAssertEqual(PomoSize.previous(before: .large), .medium)
        XCTAssertEqual(PomoSize.previous(before: .medium), .small)
        XCTAssertEqual(PomoSize.previous(before: .small), .small,
                       "the ladder must saturate at the bottom")
    }

    // MARK: - minuteDigits(forMaxMinutes:)

    /// 99 is the last two-digit minute value — the pill must not widen for it.
    func test_minuteDigits_withNinetyNineMinutes_staysAtTwoSlots() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 99), 2)
    }

    func test_minuteDigits_withExactlyOneHundredMinutes_switchesToThreeSlots() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 100), 3)
    }

    func test_minuteDigits_withOneHundredOneMinutes_staysAtThreeSlots() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 101), 3)
    }

    func test_minuteDigits_withZeroMinutes_returnsTwoSlots() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 0), 2)
    }

    /// Invalid input: `PomodoroSource.maxMinutes` already floors at 0, but the
    /// rule itself must degrade to the narrow layout — never to 0 slots, which
    /// would collapse `countdownW`.
    func test_minuteDigits_withNegativeMinutes_returnsTwoSlots() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: -1), 2)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: -1000), 2)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: Int.min), 2)
    }

    func test_minuteDigits_withAnAbsurdlyLargeMinuteCount_returnsThreeSlots() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: Int.max), 3)
    }

    /// Whole-range contract: only ever 2 or 3, never shrinking as the largest
    /// renderable minute value grows, and it flips exactly once — at 100.
    func test_minuteDigits_acrossTheWholeRange_flipsOnceAtOneHundredAndNeverShrinks() {
        var flips = 0
        var previous = PillLayout.minuteDigits(forMaxMinutes: -5)
        for minutes in -5...400 {
            let digits = PillLayout.minuteDigits(forMaxMinutes: minutes)
            XCTAssertTrue(digits == 2 || digits == 3, "got \(digits) slots at \(minutes) min")
            XCTAssertGreaterThanOrEqual(digits, previous, "slot count shrank at \(minutes) min")
            if digits != previous {
                flips += 1
                XCTAssertEqual(minutes, 100, "the flip happened at the wrong minute")
            }
            previous = digits
        }
        XCTAssertEqual(flips, 1)
    }

    /// Cross-file contract: the longest duration the ⚙ "Custom…" dialog accepts
    /// must still fit the three slots the layout reserves.
    @MainActor
    func test_minuteDigits_atTheLongestCustomDuration_stillFitsInThreeSlots() {
        XCTAssertLessThanOrEqual(PomodoroSource.maxCustomMinutes, 999,
                                 "a 4-digit custom duration would clip the readout")
        XCTAssertGreaterThanOrEqual(PomodoroSource.maxCustomMinutes,
                                    PomodoroSource.minCustomMinutes)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: PomodoroSource.maxCustomMinutes), 3)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: PomodoroSource.minCustomMinutes), 2)
    }

    // MARK: - ceil2, the only rounding point in the system

    func test_ceil2_withAValueAlreadyOnTheGrid_leavesItUnchanged() {
        XCTAssertEqual(PillLayout.ceil2(0), 0)
        XCTAssertEqual(PillLayout.ceil2(2), 2)
        XCTAssertEqual(PillLayout.ceil2(4), 4)
        XCTAssertEqual(PillLayout.ceil2(198), 198)
    }

    func test_ceil2_withAnOddValue_roundsUpToTheNextEven() {
        XCTAssertEqual(PillLayout.ceil2(1), 2)
        XCTAssertEqual(PillLayout.ceil2(3), 4)
        XCTAssertEqual(PillLayout.ceil2(5), 6)
        XCTAssertEqual(PillLayout.ceil2(197), 198)
    }

    /// Silent-drift guard: a hair of float error above a grid point costs a
    /// full 2pt step, not a fraction of a point.
    func test_ceil2_withAFractionJustAboveTheGrid_advancesAWholeTwoPointStep() {
        XCTAssertEqual(PillLayout.ceil2(4.0001), 6)
        XCTAssertEqual(PillLayout.ceil2(198.00000001), 200)
    }

    func test_ceil2_withAFractionJustBelowTheGrid_roundsUpToThatGridPoint() {
        XCTAssertEqual(PillLayout.ceil2(5.9999), 6)
        XCTAssertEqual(PillLayout.ceil2(0.0001), 2)
        XCTAssertEqual(PillLayout.ceil2(197.99999999), 198)
    }

    /// Negative input: `.up` is a CEILING, so -3 must land on -2 (toward zero),
    /// never on -4. A `.awayFromZero` slip would silently widen nothing here
    /// but would flip the sign convention of the only rounding rule.
    func test_ceil2_withANegativeValue_roundsTowardPositiveInfinity() {
        XCTAssertEqual(PillLayout.ceil2(-2), -2)
        XCTAssertEqual(PillLayout.ceil2(-3), -2)
        XCTAssertEqual(PillLayout.ceil2(-1), 0)
        XCTAssertEqual(PillLayout.ceil2(-4.5), -4)
    }

    /// Sweep: the result is always the SMALLEST even value at or above the
    /// input — on the grid, never below, never overshooting by a whole step.
    func test_ceil2_overASweep_isTheSmallestEvenValueAtOrAboveTheInput() {
        var value: CGFloat = -12.5
        while value <= 125 {
            let rounded = PillLayout.ceil2(value)
            XCTAssertGreaterThanOrEqual(rounded, value, "ceil2(\(value)) went below its input")
            XCTAssertLessThan(rounded - value, 2, "ceil2(\(value)) overshot by a whole step")
            XCTAssertEqual(rounded.truncatingRemainder(dividingBy: 2), 0,
                           "ceil2(\(value)) = \(rounded) is off the 2pt grid")
            value += 0.25
        }
    }

    func test_ceil2_appliedTwice_changesNothingTheSecondTime() {
        var value: CGFloat = -6
        while value <= 60 {
            let once = PillLayout.ceil2(value)
            XCTAssertEqual(PillLayout.ceil2(once), once, "ceil2 is not idempotent at \(value)")
            value += 0.25
        }
    }

    // MARK: - The frozen dimension table

    func test_everyLayout_matchesTheFrozenDimensionTable() {
        for golden in Self.goldenTable {
            let layout = PillLayout(sizeClass: golden.size, minuteDigits: golden.digits)
            let name = "\(golden.size)/\(golden.digits)-digit"
            XCTAssertEqual(layout.countdownW, golden.countdownW, "\(name) countdownW")
            XCTAssertEqual(layout.segClusterW, golden.segClusterW, "\(name) segClusterW")
            XCTAssertEqual(layout.contentW, golden.contentW, "\(name) contentW")
            XCTAssertEqual(layout.contentH, golden.contentH, "\(name) contentH")
            XCTAssertEqual(layout.glassW, golden.glassW, "\(name) glassW")
            XCTAssertEqual(layout.glassH, golden.glassH, "\(name) glassH")
            XCTAssertEqual(layout.pillW, golden.pillW, "\(name) pillW")
            XCTAssertEqual(layout.pillH, golden.pillH, "\(name) pillH")
            XCTAssertEqual(layout.pillSize, NSSize(width: golden.pillW, height: golden.pillH),
                           "\(name) pillSize")
            XCTAssertEqual(layout.windowSize,
                           NSSize(width: golden.windowW, height: golden.windowH),
                           "\(name) windowSize")
        }
    }

    /// The table above must cover every configuration the app can be in — a
    /// new size class would otherwise slip past the golden guard unnoticed.
    func test_theFrozenTable_coversEveryConfigurationTheAppCanBeIn() {
        XCTAssertEqual(Self.goldenTable.count, PomoSize.allCases.count * 2)
        for size in PomoSize.allCases {
            for digits in [2, 3] {
                XCTAssertTrue(
                    Self.goldenTable.contains { $0.size == size && $0.digits == digits },
                    "\(size)/\(digits)-digit is missing from the frozen table")
            }
        }
    }

    /// The per-size intermediate values the invariants below are stated in
    /// terms of, pinned numerically. Without this, an invariant like
    /// `glassW == contentW + 2 * insetH` could stay green while both sides
    /// drifted together.
    func test_theDerivationIntermediates_matchTheirFrozenPerSizeValues() {
        let expected: [(size: PomoSize, insetH: CGFloat, segRowH: CGFloat,
                        row2H: CGFloat, headerMinW: CGFloat)] = [
            (.small, 16, 23, 23, 136),
            (.medium, 20, 27, 27, 166.4),
            (.large, 24, 31, 31, 196.8),
        ]
        for (size, insetH, segRowH, row2H, headerMinW) in expected {
            let layout = PillLayout(sizeClass: size, minuteDigits: 2)
            XCTAssertEqual(layout.insetH, insetH, accuracy: 1e-12, "\(size) insetH")
            XCTAssertEqual(layout.segRowH, segRowH, accuracy: 1e-12, "\(size) segRowH")
            XCTAssertEqual(layout.row2H, row2H, accuracy: 1e-12, "\(size) row2H")
            XCTAssertEqual(layout.headerMinW, headerMinW, accuracy: 1e-12, "\(size) headerMinW")
        }
    }

    // MARK: - Derivation invariants

    /// window = pill + the shadow margin on every side, on BOTH axes. If this
    /// slips the pill clips against its own window edge.
    func test_windowSize_isThePillPlusAShadowMarginOnEverySide() {
        for layout in allLayouts() {
            let margin = 2 * layout.spacing.shadow
            XCTAssertEqual(layout.windowSize.width, layout.pillW + margin, "\(label(layout)) width")
            XCTAssertEqual(layout.windowSize.height, layout.pillH + margin, "\(label(layout)) height")
            XCTAssertEqual(layout.windowSize.width - layout.pillSize.width,
                           layout.windowSize.height - layout.pillSize.height,
                           "\(label(layout)) shadow margin is not equal on both axes")
            XCTAssertEqual(margin, 48, "\(label(layout)) the shadow budget moved")
        }
    }

    /// glass = content + a symmetric horizontal inset. The gauge runs
    /// edge-to-edge, so the two sides must stay equal.
    func test_glassWidth_isTheContentPlusTwoSymmetricHorizontalInsets() {
        for layout in allLayouts() {
            XCTAssertEqual(layout.glassW, 2 * layout.insetH + layout.contentW, "\(label(layout))")
        }
    }

    /// glass = content + a vertical inset top and bottom, snapped up to the
    /// 2pt grid. The snap is load-bearing: `segRowH` is odd, so the raw sum is
    /// odd, and leaving it that way pushed the rounding up into `pillH` where
    /// it landed in the blur instead of the capsule.
    func test_glassHeight_isTheContentPlusTheVerticalInsetTopAndBottom_snappedToTheGrid() {
        for layout in allLayouts() {
            let raw = layout.contentH + 2 * layout.spacing.insetV
            XCTAssertEqual(layout.glassH, PillLayout.ceil2(raw), "\(label(layout))")
            XCTAssertGreaterThanOrEqual(layout.glassH, raw,
                                        "\(label(layout)) the snap must never shrink the box")
            XCTAssertLessThan(layout.glassH - raw, 2,
                              "\(label(layout)) the snap must add less than one grid step")
        }
    }

    /// Both glass axes land on the 2pt grid. Without this the odd axis pushes
    /// its rounding into `pillH`, and `centeredGlassRect` — which derives the
    /// VEV as `pillH - 2*rim` — hands that spare point to the blur.
    func test_bothGlassAxes_landOnTheTwoPointGrid() {
        for layout in allLayouts() {
            XCTAssertEqual(layout.glassH.truncatingRemainder(dividingBy: 2), 0,
                           "\(label(layout)) glassH is off the 2pt grid")
            XCTAssertEqual(layout.glassW.truncatingRemainder(dividingBy: 2), 0,
                           "\(label(layout)) glassW is off the 2pt grid")
        }
    }

    /// The horizontal inset is the outer inset PLUS the blur-edge safety
    /// margin — dropping the second term is the silent regression this guards.
    /// Because `gapTextTrailing` is frozen equal to `insetOuter`, the effective
    /// edge margin is exactly double the outer inset.
    func test_horizontalInset_includesTheBlurEdgeSafetyMargin() {
        for layout in allLayouts() {
            XCTAssertEqual(layout.insetH,
                           layout.spacing.insetOuter + layout.spacing.gapTextTrailing,
                           "\(label(layout))")
            XCTAssertEqual(layout.insetH, 2 * layout.spacing.insetOuter,
                           "\(label(layout)) effective edge margin is no longer doubled")
            XCTAssertGreaterThan(layout.insetH, layout.spacing.insetOuter, "\(label(layout))")
        }
    }

    /// The vertical inset is its OWN token, not the horizontal one reused — a
    /// regression to the old shared value would make the pill read cramped.
    func test_verticalInset_isIndependentOfTheHorizontalOne() {
        for layout in allLayouts() {
            XCTAssertNotEqual(layout.spacing.insetV, layout.insetH,
                              "\(label(layout)) the two axes have collapsed onto one value")
            XCTAssertGreaterThan(layout.spacing.insetV, layout.spacing.insetOuter,
                                 "\(label(layout))")
        }
    }

    /// pill = glass + rim on all sides, snapped UP to the 2pt grid — so the
    /// pill is never smaller than the glass it has to contain, and never more
    /// than one grid step larger.
    func test_pillSize_isTheGlassPlusTheRimGuardSnappedUpToTheGrid() {
        for layout in allLayouts() {
            let neededW = layout.glassW + 2 * layout.spacing.rim
            let neededH = layout.glassH + 2 * layout.spacing.rim
            XCTAssertGreaterThanOrEqual(layout.pillW, neededW, "\(label(layout)) width")
            XCTAssertGreaterThanOrEqual(layout.pillH, neededH, "\(label(layout)) height")
            XCTAssertLessThan(layout.pillW - neededW, 2, "\(label(layout)) width overshoot")
            XCTAssertLessThan(layout.pillH - neededH, 2, "\(label(layout)) height overshoot")
            XCTAssertEqual(layout.pillW.truncatingRemainder(dividingBy: 2), 0,
                           "\(label(layout)) pillW is off the 2pt grid")
            XCTAssertEqual(layout.pillH.truncatingRemainder(dividingBy: 2), 0,
                           "\(label(layout)) pillH is off the 2pt grid")
        }
    }

    /// Regression: the pill used to be 1pt taller than glass + rim on both
    /// sides, because the glass box was odd and only `pillH` was grid-snapped.
    /// That spare point went to the VEV, not the capsule. Now the glass is
    /// snapped first, so the pill adds EXACTLY the rim guard on each axis and
    /// nothing else — which is what makes `centeredGlassRect` land on `glassH`.
    func test_thePillAddsExactlyTheRimGuardToTheGlassOnBothAxes() {
        for layout in allLayouts() {
            XCTAssertEqual(layout.pillW - (layout.glassW + 2 * layout.spacing.rim), 0,
                           "\(label(layout)) width picked up grid slack")
            XCTAssertEqual(layout.pillH - (layout.glassH + 2 * layout.spacing.rim), 0,
                           "\(label(layout)) height picked up grid slack — the VEV will inherit it")
        }
    }

    /// contentW must satisfy BOTH rows — row2's gauge + readout + their gap,
    /// and row1's icon/task/controls minimum — with only grid snapping to
    /// spare. Losing either term truncates a row.
    func test_contentWidth_satisfiesBothRowsWithOnlyGridSnappingToSpare() {
        for layout in allLayouts() {
            let row2Need = layout.segClusterW + layout.countdownW + layout.spacing.gapGauge
            let row1Need = layout.headerMinW
            XCTAssertGreaterThanOrEqual(layout.contentW, row2Need, "\(label(layout)) row2 clipped")
            XCTAssertGreaterThanOrEqual(layout.contentW, row1Need, "\(label(layout)) row1 clipped")
            XCTAssertLessThan(layout.contentW - max(row2Need, row1Need), 2,
                              "\(label(layout)) content is wider than either row needs")
        }
    }

    /// Today it is the gauge + readout row that sets the width at every size
    /// class — the header minimum is comfortably smaller, so `contentW`'s
    /// `max(...)` never picks the header branch. Recording that balance means a
    /// token change that flips it shows up as a deliberate decision rather than
    /// as a silently different layout.
    func test_contentWidth_isCurrentlyDrivenByTheGaugeRowNotTheHeaderMinimum() {
        for layout in allLayouts() {
            XCTAssertGreaterThan(
                layout.segClusterW + layout.countdownW + layout.spacing.gapGauge,
                layout.headerMinW,
                "\(label(layout)) the header row has become the binding constraint")
        }
    }

    /// The header row is exactly one control hit target tall, so the ▶ / ⚙
    /// buttons never get squeezed by the row gap or the gauge.
    func test_contentHeight_givesTheHeaderRowAFullControlHitTarget() {
        for layout in allLayouts() {
            XCTAssertEqual(layout.contentH - layout.spacing.gapRow - layout.row2H,
                           layout.spacing.ctrlHit, "\(label(layout))")
        }
    }

    /// row2 is as tall as the taller of its two children and no taller — no
    /// invented padding, and neither child clips. Today the gauge is the taller
    /// child at every size class, so `max` always picks it.
    func test_rowTwoHeight_isTheTallerOfTheReadoutAndTheGaugeAndNothingMore() {
        for layout in allLayouts() {
            XCTAssertGreaterThanOrEqual(layout.row2H, layout.countdownH, "\(label(layout)) readout")
            XCTAssertGreaterThanOrEqual(layout.row2H, layout.segRowH, "\(label(layout)) gauge")
            XCTAssertTrue(layout.row2H == layout.countdownH || layout.row2H == layout.segRowH,
                          "\(label(layout)) row2 grew beyond both of its children")
            XCTAssertEqual(layout.row2H, layout.segRowH,
                           "\(label(layout)) the readout has become the taller child")
        }
    }

    /// The gauge row reserves the outline frame's pad + stroke on top AND
    /// bottom, or the boundary marker clips. Stated with the literal 7pt so it
    /// cannot drift together with the tokens it is derived from.
    func test_gaugeRowHeight_reservesTheOutlineFrameOnBothEdges() {
        for layout in allLayouts() {
            XCTAssertEqual(layout.segRowH,
                           layout.seg.h + 2 * (Tokens.Decor.segFramePad + Tokens.Decor.segFrameStroke),
                           "\(label(layout))")
            XCTAssertEqual(layout.segRowH, layout.seg.h + 7, accuracy: 1e-12,
                           "\(label(layout)) the outline reservation moved off 3.5pt per edge")
            XCTAssertGreaterThan(layout.segRowH, layout.seg.h, "\(label(layout))")
        }
    }

    /// The countdown column reserves one slot per rendered digit plus the
    /// colon — the deliberate safety margin over the measured glyph widths is
    /// what stops "17:00" rendering as "17:…".
    func test_countdownWidth_coversEveryDigitSlotPlusTheColon() {
        for layout in allLayouts() {
            let glyphNeed = CGFloat(layout.minuteDigits + 2) * layout.countdownDigitW
                + layout.countdownColonW
            XCTAssertGreaterThanOrEqual(layout.countdownW, glyphNeed, "\(label(layout))")
            XCTAssertLessThan(layout.countdownW - glyphNeed, 2,
                              "\(label(layout)) reserves more than a grid step of slack")
        }
    }

    /// The digit/colon ratios carry a deliberate safety margin over the
    /// measured glyph widths; pinned numerically because the tighter 0.60/0.30
    /// pair is a known regression that clipped "17:…" in the live QA render.
    func test_countdownGlyphRatios_keepTheirDeliberateSafetyMargin() {
        for layout in allLayouts() {
            XCTAssertEqual(layout.countdownDigitW, layout.type.countdown * 0.72, accuracy: 1e-12,
                           "\(label(layout)) digit slot")
            XCTAssertEqual(layout.countdownColonW, layout.type.countdown * 0.34, accuracy: 1e-12,
                           "\(label(layout)) colon slot")
            XCTAssertEqual(layout.countdownH, layout.type.countdown * 1.20, accuracy: 1e-12,
                           "\(label(layout)) line height")
            XCTAssertGreaterThan(layout.countdownDigitW, layout.countdownColonW,
                                 "\(label(layout)) a colon must be narrower than a digit")
        }
    }

    // MARK: - Monotonicity across the size classes

    func test_pillDimensions_growStrictlyFromSmallToMediumToLarge() {
        for digits in [2, 3] {
            let small = PillLayout(sizeClass: .small, minuteDigits: digits)
            let medium = PillLayout(sizeClass: .medium, minuteDigits: digits)
            let large = PillLayout(sizeClass: .large, minuteDigits: digits)

            for (smaller, bigger) in [(small, medium), (medium, large)] {
                let name = "\(smaller.sizeClass)→\(bigger.sizeClass) @\(digits)-digit"
                XCTAssertLessThan(smaller.contentW, bigger.contentW, "\(name) contentW")
                XCTAssertLessThan(smaller.contentH, bigger.contentH, "\(name) contentH")
                XCTAssertLessThan(smaller.glassW, bigger.glassW, "\(name) glassW")
                XCTAssertLessThan(smaller.glassH, bigger.glassH, "\(name) glassH")
                XCTAssertLessThan(smaller.pillW, bigger.pillW, "\(name) pillW")
                XCTAssertLessThan(smaller.pillH, bigger.pillH, "\(name) pillH")
                XCTAssertLessThan(smaller.windowSize.width, bigger.windowSize.width, "\(name) window W")
                XCTAssertLessThan(smaller.windowSize.height, bigger.windowSize.height, "\(name) window H")
                XCTAssertLessThan(smaller.segClusterW, bigger.segClusterW, "\(name) gauge")
                XCTAssertLessThan(smaller.countdownW, bigger.countdownW, "\(name) countdown")
            }
        }
    }

    // MARK: - The 2 ↔ 3 digit switch

    /// A third minute digit can only ever widen the pill, never narrow it —
    /// otherwise the 99→100 transition would clip the readout it was added for.
    func test_theThreeDigitLayout_isNeverNarrowerThanTheTwoDigitOne() {
        for size in PomoSize.allCases {
            let two = PillLayout(sizeClass: size, minuteDigits: 2)
            let three = PillLayout(sizeClass: size, minuteDigits: 3)
            XCTAssertGreaterThan(three.countdownW, two.countdownW, "\(size) countdownW")
            XCTAssertGreaterThan(three.contentW, two.contentW, "\(size) contentW")
            XCTAssertGreaterThan(three.glassW, two.glassW, "\(size) glassW")
            XCTAssertGreaterThan(three.pillW, two.pillW, "\(size) pillW")
            XCTAssertGreaterThan(three.windowSize.width, two.windowSize.width, "\(size) window")
            // …and by at least one whole digit slot, minus the grid snap.
            XCTAssertGreaterThan(three.countdownW - two.countdownW,
                                 two.countdownDigitW - 2, "\(size) extra slot is too narrow")
        }
    }

    /// The digit count is a WIDTH-only input: the 99→100 relayout must not
    /// make the pill jump vertically.
    func test_theDigitCount_doesNotChangeAnyVerticalDimension() {
        for size in PomoSize.allCases {
            let two = PillLayout(sizeClass: size, minuteDigits: 2)
            let three = PillLayout(sizeClass: size, minuteDigits: 3)
            XCTAssertEqual(three.contentH, two.contentH, "\(size) contentH")
            XCTAssertEqual(three.glassH, two.glassH, "\(size) glassH")
            XCTAssertEqual(three.pillH, two.pillH, "\(size) pillH")
            XCTAssertEqual(three.windowSize.height, two.windowSize.height, "\(size) window height")
        }
    }

    /// The gauge is fixed at 10 segments, so its cluster width must NOT move
    /// when the readout gains a digit — only the countdown column grows.
    func test_theDigitCount_doesNotResizeTheGauge() {
        for size in PomoSize.allCases {
            let two = PillLayout(sizeClass: size, minuteDigits: 2)
            let three = PillLayout(sizeClass: size, minuteDigits: 3)
            XCTAssertEqual(three.segClusterW, two.segClusterW, "\(size)")
            XCTAssertEqual(three.barRowW, two.barRowW, "\(size)")
            XCTAssertEqual(three.segCount, two.segCount, "\(size)")
        }
    }

    // MARK: - Cross-file consumers of the chain

    /// `PomoSize.pillSize` is documented as delegating to `PillLayout` at the
    /// 2-digit baseline. If the preset table ever grows its own literals again,
    /// this catches it.
    func test_thePomoSizePreset_matchesThePillLayoutTwoDigitBaseline() {
        for size in PomoSize.allCases {
            XCTAssertEqual(size.pillSize,
                           PillLayout(sizeClass: size, minuteDigits: 2).pillSize,
                           "\(size) preset drifted from PillLayout")
            // …and NOT the 3-digit one, so "canonical" really means 2-digit.
            XCTAssertNotEqual(size.pillSize,
                              PillLayout(sizeClass: size, minuteDigits: 3).pillSize,
                              "\(size) preset is using the wide baseline")
        }
    }

    // MARK: - Hover growth vs. the shadow margin

    /// §3.5: the hovered pill grows in place, so the grown pill has to stay
    /// inside the window it lives in — expressed as the consequence (it fits)
    /// rather than as the margin formula itself.
    ///
    /// `assertHoverScaleSafe` is deliberately NOT called here: it is a debug
    /// `assert`, so a violation would trap the test process instead of
    /// reporting a failure. The final assertion below cross-checks that its
    /// `maxSafe` formula describes exactly the budget the window actually has.
    func test_theDefaultHoverScale_keepsTheGrownPillInsideItsWindow() {
        let scale = TuningStore.Default.hoverScale
        XCTAssertEqual(scale, 1.03, accuracy: 1e-12, "the shipped default hover scale moved")
        XCTAssertGreaterThan(scale, 1, "hover is supposed to GROW the pill")
        for layout in allLayouts() {
            XCTAssertLessThanOrEqual(layout.pillW * scale, layout.windowSize.width,
                                     "\(label(layout)) hovered pill clips horizontally")
            XCTAssertLessThanOrEqual(layout.pillH * scale, layout.windowSize.height,
                                     "\(label(layout)) hovered pill clips vertically")
            // The debug invariant's own bound must equal the real width budget.
            XCTAssertEqual(1 + 2 * layout.spacing.shadow / layout.pillW,
                           layout.windowSize.width / layout.pillW, accuracy: 1e-12,
                           "\(label(layout)) assertHoverScaleSafe guards the wrong budget")
        }
    }

    /// `TuningPanelView` lets the user push hover scale to 1.10; the top of
    /// that slider must be safe at every size class too, not just the default.
    func test_theTopOfTheTunableHoverRange_stillFitsInsideTheWindow() {
        let panelMaximum: CGFloat = 1.10  // TuningPanelView: range 1.0...1.10
        for layout in allLayouts() {
            XCTAssertLessThanOrEqual(layout.pillW * panelMaximum, layout.windowSize.width,
                                     "\(label(layout)) clips at the top of the hover slider")
            XCTAssertLessThanOrEqual(layout.pillH * panelMaximum, layout.windowSize.height,
                                     "\(label(layout)) clips at the top of the hover slider")
        }
    }

    /// Negative test: the shadow margin is not so generous that ANY scale would
    /// fit — if it were, the two tests above would be vacuous.
    func test_theHoverBudget_isFiniteSoTheFitTestsAreNotVacuous() {
        for layout in allLayouts() {
            XCTAssertGreaterThan(layout.pillW * 1.5, layout.windowSize.width,
                                 "\(label(layout)) the window is so oversized that nothing can clip")
        }
    }

    /// The hover assertion only checks the WIDTH axis. That is sound only
    /// while the pill is never taller than it is wide — if a size class ever
    /// inverts, the assertion would guard the wrong axis.
    func test_thePillIsAlwaysWiderThanItIsTall_soWidthIsTheBindingHoverConstraint() {
        for layout in allLayouts() {
            XCTAssertGreaterThan(layout.pillW, layout.pillH, "\(label(layout))")
        }
    }
}
