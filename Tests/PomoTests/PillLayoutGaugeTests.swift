import AppKit
import XCTest

@testable import Pomo

/// The segmented gauge's pure rules: how many bars are lit, where each bar
/// sits, how the consumed run dims, and where the boundary marker is drawn.
///
/// Everything here is a pure function of its arguments — no clock, no files,
/// no UserDefaults, no shared state — so these tests are order-independent by
/// construction.
///
/// Where a test compares against a `Tokens.Decor` constant rather than a
/// literal, `DesignTokensTests.test_gaugeDecorConstants_matchTheirFrozenValues`
/// pins that constant's value numerically, so the pair cannot drift together
/// into a vacuous "x == x".
final class PillLayoutGaugeTests: XCTestCase {

    /// The gauge the app actually draws (`Tokens.Decor.segCountFixed`).
    /// `DesignTokensTests` guards that the token is still 10, so a change to
    /// the token fails loudly there rather than silently re-scaling these
    /// expectations.
    private let total = 10

    private func layouts() -> [PillLayout] {
        PomoSize.allCases.map { PillLayout(sizeClass: $0, minuteDigits: 2) }
    }

    private func label(_ layout: PillLayout) -> String {
        "\(layout.sizeClass)/\(layout.minuteDigits)-digit"
    }

    // MARK: - litSegmentCount: the ratio == 0 vs ratio > 0 contract

    func test_litSegmentCount_withNoTimeRemaining_lightsNoSegments() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0, total: total), 0)
    }

    /// The documented asymmetry: `ratio == 0` yields 0, but ANY positive ratio
    /// yields at least 1 — the last bar stays lit until the clock really hits
    /// 0:00. An off-by-one here would blank the gauge a whole segment early.
    func test_litSegmentCount_withTheSmallestPositiveTimeRemaining_stillLightsOneSegment() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: .leastNonzeroMagnitude,
                                                  total: total), 1)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 1e-300, total: total), 1)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 1e-9, total: total), 1)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.001, total: total), 1)
    }

    /// `PomodoroSource.remainingRatio` clamps to 0…1, but the rule must not
    /// rely on that: a negative ratio is "finished", never a negative or
    /// wrapped-around bar count.
    func test_litSegmentCount_withANegativeRatio_lightsNoSegments() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: -0.0001, total: total), 0)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: -1, total: total), 0)
    }

    func test_litSegmentCount_atFullTimeRemaining_lightsEverySegment() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 1.0, total: total), total)
    }

    /// One tick into a session the gauge must still read FULL, not 9/10.
    func test_litSegmentCount_aHairBelowFullTime_stillLightsEverySegment() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.99999999, total: total), total)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.95, total: total), total)
    }

    func test_litSegmentCount_atHalfTimeRemaining_lightsHalfTheSegments() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.5, total: total), 5)
    }

    /// On an exact k/total boundary the k-th segment is the LAST one lit —
    /// the boundary belongs to the lower band, not the higher one.
    func test_litSegmentCount_onAnExactSegmentBoundary_lightsExactlyThatManySegments() {
        let boundaries: [(ratio: Double, lit: Int)] = [
            (0.1, 1), (0.2, 2), (0.3, 3), (0.4, 4), (0.5, 5),
            (0.6, 6), (0.7, 7), (0.8, 8), (0.9, 9), (1.0, 10),
        ]
        for (ratio, expected) in boundaries {
            XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: ratio, total: total),
                           expected,
                           "ratio \(ratio) should light \(expected) of \(total)")
        }
    }

    /// The same boundary rule stated the way the app actually hits it: whole
    /// countdown seconds of the default 25-minute phase. Integer arithmetic, so
    /// it does not depend on which side of a decimal literal the binary
    /// representation happens to land — and it pins the exact second on which a
    /// bar goes out, which is the off-by-one a user would actually see.
    func test_litSegmentCount_overWholeCountdownSeconds_dropsABarExactlyOnTheSegmentBoundary() {
        let totalSeconds = 1500                          // default 25-minute work phase
        let secondsPerSegment = totalSeconds / total     // 150
        func lit(_ remainingSeconds: Int) -> Int {
            PillLayout.litSegmentCount(
                remainingRatio: Double(remainingSeconds) / Double(totalSeconds), total: total)
        }
        for bars in 1...total {
            let boundary = secondsPerSegment * bars
            XCTAssertEqual(lit(boundary), bars, "\(boundary)s should light exactly \(bars) bars")
            XCTAssertEqual(lit(boundary - 1), bars,
                           "one second into the \(bars)-bar band must not drop a bar early")
            if bars < total {
                XCTAssertEqual(lit(boundary + 1), bars + 1,
                               "one second above the \(bars)-bar boundary must light one more")
            }
        }
        // …and the bar only goes out when the band is fully spent.
        XCTAssertEqual(lit(secondsPerSegment), 1)
        XCTAssertEqual(lit(1), 1, "the last bar stays lit down to the final second")
        XCTAssertEqual(lit(0), 0, "and only goes dark at 0:00")
    }

    /// Off-by-one guard, upper side of the boundary.
    func test_litSegmentCount_aHairAboveASegmentBoundary_lightsOneMoreSegment() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.10000001, total: total), 2)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.20000001, total: total), 3)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.50000001, total: total), 6)
    }

    /// Off-by-one guard, lower side of the boundary.
    func test_litSegmentCount_aHairBelowASegmentBoundary_doesNotLightTheNextSegment() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.09999999, total: total), 1)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.19999999, total: total), 2)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.49999999, total: total), 5)
    }

    /// Regression — `PomodoroSource` deliberately does NOT grow `totalForPhase`
    /// when a session runs into extra time, so a ratio above 1 must read as a
    /// full gauge rather than as 11+ bars (which would index past the row).
    func test_litSegmentCount_withMoreTimeThanThePhaseTotal_clampsToTheTotal() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 1.0000001, total: total), total)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 1.5, total: total), total)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 42, total: total), total)
    }

    /// Empty case: a gauge with no segments cannot light one, whatever the ratio.
    func test_litSegmentCount_withNoSegmentsAtAll_lightsNothing() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0, total: 0), 0)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.5, total: 0), 0)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 1, total: 0), 0)
    }

    /// Minimum gauge: a single segment is lit for any remaining time and dark
    /// only at zero.
    func test_litSegmentCount_withASingleSegmentGauge_lightsItForAnyRemainingTime() {
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0, total: 1), 0)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 0.01, total: 1), 1)
        XCTAssertEqual(PillLayout.litSegmentCount(remainingRatio: 1, total: 1), 1)
    }

    /// Whole-countdown sweep: the gauge only ever empties, never refills, and
    /// never leaves 0…total.
    func test_litSegmentCount_overAWholeCountdown_onlyEverDrainsAndStaysInRange() {
        var previous = total
        var distinctValues = Set<Int>()
        for step in stride(from: 1000, through: 0, by: -1) {
            let ratio = Double(step) / 1000.0
            let lit = PillLayout.litSegmentCount(remainingRatio: ratio, total: total)
            XCTAssertGreaterThanOrEqual(lit, 0, "negative bar count at ratio \(ratio)")
            XCTAssertLessThanOrEqual(lit, total, "more than \(total) bars at ratio \(ratio)")
            XCTAssertLessThanOrEqual(lit, previous, "gauge refilled while draining at ratio \(ratio)")
            previous = lit
            distinctValues.insert(lit)
        }
        XCTAssertEqual(previous, 0, "the gauge must be empty at ratio 0")
        // Every bar count 0…10 must actually occur; a gauge that only ever
        // showed 0 and 10 would satisfy every monotonicity assertion above.
        XCTAssertEqual(distinctValues, Set(0...total),
                       "the gauge skipped bar counts during a full countdown")
    }

    /// Negative test — the thing that must NOT happen: a dark gauge while the
    /// session still has time on the clock.
    func test_litSegmentCount_neverGoesFullyDarkWhileAnyTimeRemains() {
        for step in 1...1000 {
            let ratio = Double(step) / 1000.0
            XCTAssertGreaterThanOrEqual(
                PillLayout.litSegmentCount(remainingRatio: ratio, total: total), 1,
                "gauge went dark at ratio \(ratio) with time still remaining")
        }
    }

    /// The view derives `consumedCount = total - litCount` and indexes the
    /// consumed run with `i - litCount`; that arithmetic must never produce an
    /// out-of-range index for any ratio.
    func test_litSegmentCount_alwaysLeavesAValidConsumedRunForTheView() {
        for step in 0...1000 {
            let ratio = Double(step) / 1000.0
            let lit = PillLayout.litSegmentCount(remainingRatio: ratio, total: total)
            let consumed = total - lit
            XCTAssertGreaterThanOrEqual(consumed, 0, "ratio \(ratio)")
            XCTAssertLessThanOrEqual(consumed, total, "ratio \(ratio)")
            XCTAssertEqual(lit + consumed, total, "ratio \(ratio)")
        }
    }

    // MARK: - consumedSegmentOpacity

    /// The `consumedCount <= 1` guard branch: with nothing consumed the value
    /// is still defined and equals the boundary maximum (no divide-by-zero, no
    /// NaN leaking into a SwiftUI `.opacity`).
    func test_consumedSegmentOpacity_withNothingConsumed_returnsTheBoundaryMaximum() {
        let opacity = PillLayout.consumedSegmentOpacity(index: 0, consumedCount: 0)
        XCTAssertEqual(opacity, Tokens.Decor.segConsumedOpacityMax, accuracy: 1e-12)
        XCTAssertFalse(opacity.isNaN)
    }

    /// A lone consumed segment gets the max, per the doc comment — not the min,
    /// and not the midpoint.
    func test_consumedSegmentOpacity_withASingleConsumedSegment_returnsTheBoundaryMaximum() {
        XCTAssertEqual(PillLayout.consumedSegmentOpacity(index: 0, consumedCount: 1),
                       Tokens.Decor.segConsumedOpacityMax, accuracy: 1e-12)
        XCTAssertNotEqual(PillLayout.consumedSegmentOpacity(index: 0, consumedCount: 1),
                          Tokens.Decor.segConsumedOpacityMin,
                          "a lone consumed segment must take the max, not the min")
    }

    /// With exactly two consumed segments the ramp spans its full range in one
    /// step: max at the boundary, min at the far end.
    func test_consumedSegmentOpacity_withTwoConsumedSegments_spansTheWholeRampInOneStep() {
        XCTAssertEqual(PillLayout.consumedSegmentOpacity(index: 0, consumedCount: 2),
                       Tokens.Decor.segConsumedOpacityMax, accuracy: 1e-12)
        XCTAssertEqual(PillLayout.consumedSegmentOpacity(index: 1, consumedCount: 2),
                       Tokens.Decor.segConsumedOpacityMin, accuracy: 1e-12)
    }

    /// Full gauge consumed: the ends pin to max/min and the interior steps are
    /// evenly spaced (a linear ramp, not an eased or truncated one).
    func test_consumedSegmentOpacity_withAFullyConsumedGauge_rampsLinearlyFromMaxToMin() {
        let n = total
        XCTAssertEqual(PillLayout.consumedSegmentOpacity(index: 0, consumedCount: n),
                       Tokens.Decor.segConsumedOpacityMax, accuracy: 1e-12)
        XCTAssertEqual(PillLayout.consumedSegmentOpacity(index: n - 1, consumedCount: n),
                       Tokens.Decor.segConsumedOpacityMin, accuracy: 1e-12)

        let step = (Tokens.Decor.segConsumedOpacityMax - Tokens.Decor.segConsumedOpacityMin)
            / Double(n - 1)
        XCTAssertGreaterThan(step, 0, "the ramp must actually descend")
        for index in 1..<n {
            let delta = PillLayout.consumedSegmentOpacity(index: index - 1, consumedCount: n)
                - PillLayout.consumedSegmentOpacity(index: index, consumedCount: n)
            XCTAssertEqual(delta, step, accuracy: 1e-12,
                           "ramp step \(index) is uneven")
        }

        // The two middle samples straddle the midpoint of the range exactly.
        let midpoint = (Tokens.Decor.segConsumedOpacityMax + Tokens.Decor.segConsumedOpacityMin) / 2
        let straddle = (PillLayout.consumedSegmentOpacity(index: 4, consumedCount: n)
            + PillLayout.consumedSegmentOpacity(index: 5, consumedCount: n)) / 2
        XCTAssertEqual(straddle, midpoint, accuracy: 1e-12)
    }

    func test_consumedSegmentOpacity_getsDimmerWithEveryStepAwayFromTheBoundary() {
        for count in 2...total {
            for index in 1..<count {
                XCTAssertLessThan(
                    PillLayout.consumedSegmentOpacity(index: index, consumedCount: count),
                    PillLayout.consumedSegmentOpacity(index: index - 1, consumedCount: count),
                    "count \(count), index \(index) is not dimmer than its neighbour")
            }
        }
    }

    /// Negative test: no consumed segment is ever fully invisible or brighter
    /// than the boundary segment, at any consumed-run length.
    func test_consumedSegmentOpacity_staysInsideTheDeclaredRangeAndNeverVanishes() {
        for count in 0...total {
            for index in 0..<max(1, count) {
                let opacity = PillLayout.consumedSegmentOpacity(index: index, consumedCount: count)
                XCTAssertGreaterThan(opacity, 0, "count \(count), index \(index)")
                XCTAssertGreaterThanOrEqual(opacity, Tokens.Decor.segConsumedOpacityMin,
                                            "count \(count), index \(index)")
                XCTAssertLessThanOrEqual(opacity, Tokens.Decor.segConsumedOpacityMax,
                                         "count \(count), index \(index)")
            }
        }
    }

    /// The consumed run always reaches BOTH ends of the declared range once it
    /// is longer than one segment — a ramp that merely stayed inside the range
    /// (e.g. a constant, or one that stopped short of the min) would pass every
    /// range check above.
    func test_consumedSegmentOpacity_forEveryRunLongerThanOne_touchesBothEndsOfTheRange() {
        for count in 2...total {
            XCTAssertEqual(PillLayout.consumedSegmentOpacity(index: 0, consumedCount: count),
                           Tokens.Decor.segConsumedOpacityMax, accuracy: 1e-12,
                           "count \(count) does not start at the max")
            XCTAssertEqual(PillLayout.consumedSegmentOpacity(index: count - 1, consumedCount: count),
                           Tokens.Decor.segConsumedOpacityMin, accuracy: 1e-12,
                           "count \(count) does not end at the min")
        }
    }

    // MARK: - segmentX and the cluster's fit

    func test_segmentX_forTheFirstSegment_startsFlushWithTheBarRow() {
        for layout in layouts() {
            XCTAssertEqual(layout.segmentX(0), 0, "\(label(layout))")
        }
    }

    func test_segmentX_advancesByOneSegmentPlusOneGapEveryTime() {
        for layout in layouts() {
            let pitch = layout.segWActual + layout.segGapActual
            XCTAssertGreaterThan(pitch, 0, "\(label(layout)) degenerate pitch")
            for index in 1..<layout.segCount {
                XCTAssertEqual(layout.segmentX(index) - layout.segmentX(index - 1), pitch,
                               "\(label(layout)) pitch broke at index \(index)")
            }
        }
    }

    /// The drawn geometry, pinned numerically per size class so the pitch test
    /// above cannot pass by agreeing with a broken `segWActual`/`segGapActual`.
    func test_segmentGeometry_matchesTheFrozenPerSizeClassValues() {
        let expected: [(size: PomoSize, width: CGFloat, gap: CGFloat, cluster: CGFloat)] = [
            (.small, 10, 4, 136),
            (.medium, 12.5, 5, 170),
            (.large, 15, 6, 204),
        ]
        for (size, width, gap, cluster) in expected {
            let layout = PillLayout(sizeClass: size, minuteDigits: 2)
            XCTAssertEqual(layout.segWActual, width, accuracy: 1e-12, "\(size) segWActual")
            XCTAssertEqual(layout.segGapActual, gap, accuracy: 1e-12, "\(size) segGapActual")
            XCTAssertEqual(layout.segClusterW, cluster, accuracy: 1e-12, "\(size) segClusterW")
            XCTAssertEqual(layout.segmentX(layout.segCount - 1), cluster - width, accuracy: 1e-12,
                           "\(size) last segment's leading edge")
        }
    }

    /// The headline gauge invariant: the last bar's right edge lands EXACTLY on
    /// the bar row's trailing edge, so the gauge is flush with the ⚙ above it —
    /// no trailing sliver of empty glass, no overhang.
    func test_segmentCluster_endsExactlyOnTheBarRowTrailingEdge() {
        for layout in layouts() {
            let lastEdge = layout.segmentX(layout.segCount - 1) + layout.segWActual
            XCTAssertEqual(lastEdge, layout.barRowW, accuracy: 1e-12,
                           "\(label(layout)) gauge does not fill its bar row exactly")
            XCTAssertEqual(layout.barRowW, layout.segClusterW, accuracy: 1e-12,
                           "\(label(layout)) the bar row is not the segment cluster")
        }
    }

    func test_segmentPositions_areStrictlyIncreasingAndNonOverlapping() {
        for layout in layouts() {
            for index in 1..<layout.segCount {
                let previousRight = layout.segmentX(index - 1) + layout.segWActual
                XCTAssertGreaterThan(layout.segmentX(index), previousRight,
                                     "\(label(layout)) segments \(index - 1)/\(index) overlap")
            }
        }
    }

    /// The gauge is a row of tall capsules, not dots. The documented floor
    /// (h ≥ w × 1.8) is stated about the BASE `seg.w`; the width actually drawn
    /// is `segWActual` = w × `segWidthFactor`, so the drawn bar only has to stay
    /// taller than it is wide. See bugsFound — the doc comment claims the floor
    /// for the drawn bar, which is 1.6:1 today.
    func test_segmentShape_staysATallCapsuleAtEverySizeClass() {
        for layout in layouts() {
            XCTAssertGreaterThanOrEqual(layout.seg.h, layout.seg.w * 1.8,
                                        "\(label(layout)) base segment is too squat")
            XCTAssertGreaterThan(layout.seg.h, layout.segWActual,
                                 "\(label(layout)) drawn segment is wider than it is tall")
            XCTAssertGreaterThanOrEqual(layout.seg.h / layout.segWActual, 1.5,
                                        "\(label(layout)) drawn bar has stopped reading as a bar")
            XCTAssertLessThan(layout.segGapActual, layout.segWActual,
                              "\(label(layout)) gap is wider than the bar it separates")
        }
    }

    /// The gauge must always fit inside the content box it is laid out in.
    func test_segmentCluster_fitsInsideTheContentWidth() {
        for size in PomoSize.allCases {
            for digits in [2, 3] {
                let layout = PillLayout(sizeClass: size, minuteDigits: digits)
                XCTAssertLessThanOrEqual(layout.segClusterW, layout.contentW, "\(label(layout))")
                XCTAssertLessThanOrEqual(layout.segRowH, layout.row2H, "\(label(layout))")
            }
        }
    }

    // MARK: - boundaryFrame

    func test_boundaryFrame_withNothingLit_returnsNilSoNoMarkerIsDrawn() {
        for layout in layouts() {
            XCTAssertNil(layout.boundaryFrame(litCount: 0, total: total), "\(label(layout))")
        }
    }

    /// Invalid input: a negative lit count is still "nothing lit", never a
    /// frame at a negative x.
    func test_boundaryFrame_withANegativeLitCount_returnsNil() {
        for layout in layouts() {
            XCTAssertNil(layout.boundaryFrame(litCount: -1, total: total), "\(label(layout))")
            XCTAssertNil(layout.boundaryFrame(litCount: Int.min, total: total), "\(label(layout))")
        }
    }

    /// One lit: the marker brackets the PAIR (bar 0 and bar 1) and starts one
    /// frame pad before the gauge's leading edge.
    func test_boundaryFrame_withOneSegmentLit_bracketsTheFirstPairStartingOnePadEarly() {
        let pad = Tokens.Decor.segFramePad
        for layout in layouts() {
            guard let frame = layout.boundaryFrame(litCount: 1, total: total) else {
                return XCTFail("\(label(layout)) returned nil with one segment lit")
            }
            XCTAssertEqual(frame.x, -pad, accuracy: 1e-12, "\(label(layout))")
            XCTAssertEqual(frame.width, 2 * layout.segWActual + layout.segGapActual + 2 * pad,
                           accuracy: 1e-12, "\(label(layout))")
        }
    }

    /// Mid-gauge the frame spans exactly [last lit … first consumed], padded by
    /// one frame pad on each side.
    func test_boundaryFrame_midGauge_bracketsExactlyTheLastLitAndFirstConsumedSegments() {
        let pad = Tokens.Decor.segFramePad
        for layout in layouts() {
            for lit in 1...(total - 1) {
                guard let frame = layout.boundaryFrame(litCount: lit, total: total) else {
                    return XCTFail("\(label(layout)) returned nil at litCount \(lit)")
                }
                XCTAssertEqual(frame.x, layout.segmentX(lit - 1) - pad, accuracy: 1e-12,
                               "\(label(layout)) litCount \(lit) left edge")
                XCTAssertEqual(frame.x + frame.width,
                               layout.segmentX(lit) + layout.segWActual + pad, accuracy: 1e-12,
                               "\(label(layout)) litCount \(lit) right edge")
            }
        }
    }

    /// Boundary case: one short of full is still a pair.
    func test_boundaryFrame_oneSegmentShortOfFull_stillBracketsAPair() {
        let pad = Tokens.Decor.segFramePad
        for layout in layouts() {
            guard let frame = layout.boundaryFrame(litCount: total - 1, total: total) else {
                return XCTFail("\(label(layout)) returned nil at litCount \(total - 1)")
            }
            XCTAssertEqual(frame.width, 2 * layout.segWActual + layout.segGapActual + 2 * pad,
                           accuracy: 1e-12, "\(label(layout))")
        }
    }

    /// At full progress there is no consumed segment to pair with, so the frame
    /// brackets the last lit segment alone.
    func test_boundaryFrame_atFullProgress_bracketsOnlyTheLastSegment() {
        let pad = Tokens.Decor.segFramePad
        for layout in layouts() {
            guard let frame = layout.boundaryFrame(litCount: total, total: total) else {
                return XCTFail("\(label(layout)) returned nil at full progress")
            }
            XCTAssertEqual(frame.width, layout.segWActual + 2 * pad, accuracy: 1e-12,
                           "\(label(layout))")
            XCTAssertEqual(frame.x, layout.segmentX(total - 1) - pad, accuracy: 1e-12,
                           "\(label(layout))")
            XCTAssertEqual(frame.x + frame.width, layout.segClusterW + pad, accuracy: 1e-12,
                           "\(label(layout)) marker must end one pad past the gauge")
        }
    }

    /// The pair/single distinction has to be observable — otherwise the marker
    /// would silently keep bracketing two slots past the end of the gauge.
    func test_boundaryFrame_atFullProgress_isNarrowerThanThePairFrame() {
        for layout in layouts() {
            guard let pair = layout.boundaryFrame(litCount: total - 1, total: total),
                  let single = layout.boundaryFrame(litCount: total, total: total) else {
                return XCTFail("\(label(layout)) returned nil")
            }
            XCTAssertLessThan(single.width, pair.width, "\(label(layout))")
            XCTAssertEqual(pair.width - single.width,
                           layout.segWActual + layout.segGapActual, accuracy: 1e-9,
                           "\(label(layout))")
        }
    }

    /// The marker frame always extends one pad BEYOND the segment(s) it
    /// brackets on both sides — a zero pad would draw the outline on top of
    /// the bar it is supposed to frame.
    func test_boundaryFrame_alwaysSitsOutsideTheSegmentsItBrackets() {
        for layout in layouts() {
            for lit in 1...total {
                guard let frame = layout.boundaryFrame(litCount: lit, total: total) else {
                    return XCTFail("\(label(layout)) returned nil at litCount \(lit)")
                }
                let bracketedLeft = layout.segmentX(lit - 1)
                let bracketedRight = lit <= total - 1
                    ? layout.segmentX(lit) + layout.segWActual
                    : layout.segmentX(lit - 1) + layout.segWActual
                XCTAssertLessThan(frame.x, bracketedLeft,
                                  "\(label(layout)) litCount \(lit) left edge is not outside")
                XCTAssertGreaterThan(frame.x + frame.width, bracketedRight,
                                     "\(label(layout)) litCount \(lit) right edge is not outside")
            }
        }
    }

    /// Negative test: for every lit count the app can actually produce, the
    /// marker stays within one frame pad of the gauge on both sides.
    func test_boundaryFrame_neverEscapesTheGaugeByMoreThanOneFramePad() {
        let pad = Tokens.Decor.segFramePad
        for layout in layouts() {
            for lit in 1...total {
                guard let frame = layout.boundaryFrame(litCount: lit, total: total) else {
                    return XCTFail("\(label(layout)) returned nil at litCount \(lit)")
                }
                XCTAssertGreaterThanOrEqual(frame.x, -pad, "\(label(layout)) litCount \(lit)")
                XCTAssertLessThanOrEqual(frame.x + frame.width, layout.segClusterW + pad,
                                         "\(label(layout)) litCount \(lit)")
                XCTAssertGreaterThan(frame.width, 0, "\(label(layout)) litCount \(lit)")
            }
        }
    }

    /// The marker must actually MOVE with the boundary — a frame pinned to one
    /// x would satisfy every containment assertion above.
    func test_boundaryFrame_advancesByExactlyOnePitchForEachExtraLitSegment() {
        for layout in layouts() {
            let pitch = layout.segWActual + layout.segGapActual
            for lit in 2...total {
                guard let previous = layout.boundaryFrame(litCount: lit - 1, total: total),
                      let current = layout.boundaryFrame(litCount: lit, total: total) else {
                    return XCTFail("\(label(layout)) returned nil around litCount \(lit)")
                }
                XCTAssertEqual(current.x - previous.x, pitch, accuracy: 1e-12,
                               "\(label(layout)) marker did not advance at litCount \(lit)")
            }
        }
    }

    /// End-to-end through the two rules the view actually chains: a ratio in,
    /// a marker position out. Guards the pair that has to agree.
    func test_boundaryFrame_drivenByLitSegmentCount_neverEscapesTheGauge() {
        let pad = Tokens.Decor.segFramePad
        for layout in layouts() {
            var sawNil = false
            var sawFrame = false
            for step in 0...200 {
                let ratio = Double(step) / 200.0
                let lit = PillLayout.litSegmentCount(remainingRatio: ratio, total: layout.segCount)
                guard let frame = layout.boundaryFrame(litCount: lit, total: layout.segCount) else {
                    XCTAssertEqual(lit, 0, "\(label(layout)) nil marker with \(lit) lit")
                    sawNil = true
                    continue
                }
                sawFrame = true
                XCTAssertGreaterThanOrEqual(frame.x, -pad, "\(label(layout)) ratio \(ratio)")
                XCTAssertLessThanOrEqual(frame.x + frame.width, layout.segClusterW + pad,
                                         "\(label(layout)) ratio \(ratio)")
            }
            XCTAssertTrue(sawNil, "\(label(layout)) never exercised the no-marker case")
            XCTAssertTrue(sawFrame, "\(label(layout)) never exercised the marker case")
        }
    }
}
