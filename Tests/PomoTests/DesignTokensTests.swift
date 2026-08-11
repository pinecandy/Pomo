import AppKit
import XCTest

@testable import Pomo

/// The token tables themselves — the two number families every dimension in
/// the pill is derived from. These guard the rules the tables document about
/// themselves (2pt grid, frozen relationships, ordering), so a hand-edited
/// token cannot quietly break the derivation downstream.
///
/// Deliberately NOT covered here: `Tokens.Decor.accentGreen*`, which resolves
/// through `AccentColorStore.shared` and would read the user's real
/// `UserDefaults.standard` domain.
final class DesignTokensTests: XCTestCase {

    private let sizes = PomoSize.allCases

    private func isOnTwoPointGrid(_ value: CGFloat) -> Bool {
        value.truncatingRemainder(dividingBy: 2) == 0
    }

    // MARK: - Spacing scale

    /// "Spacing (2pt grid, frozen per size class)" — every field, every size.
    func test_spacingScale_atEverySizeClass_isEntirelyOnTheTwoPointGrid() {
        for size in sizes {
            let spacing = Tokens.spacingScale(for: size)
            let fields: [(String, CGFloat)] = [
                ("rim", spacing.rim), ("insetOuter", spacing.insetOuter),
                ("gapGauge", spacing.gapGauge), ("gapSection", spacing.gapSection),
                ("gapRow", spacing.gapRow), ("gapInline", spacing.gapInline),
                ("gapControls", spacing.gapControls), ("ctrlHit", spacing.ctrlHit),
                ("shadow", spacing.shadow), ("gapTextTrailing", spacing.gapTextTrailing),
                ("insetV", spacing.insetV),
            ]
            XCTAssertEqual(fields.count, 11,
                           "SpacingScale gained or lost a field — update this grid check")
            for (name, value) in fields {
                XCTAssertTrue(isOnTwoPointGrid(value), "\(size).\(name) = \(value) is off the grid")
                XCTAssertGreaterThan(value, 0, "\(size).\(name) must be positive")
            }
        }
    }

    /// The frozen spacing table itself. Every derivation invariant in
    /// `PillLayoutDerivationTests` is stated in terms of these tokens, so
    /// without a numeric pin here both sides of an invariant could drift
    /// together and stay green.
    func test_spacingScale_matchesItsFrozenPerSizeClassTable() {
        let expected: [PomoSize: [String: CGFloat]] = [
            .small: ["rim": 4, "insetOuter": 8, "gapGauge": 10, "gapSection": 12, "gapRow": 6,
                     "gapInline": 6, "gapControls": 6, "ctrlHit": 20, "shadow": 24,
                     "gapTextTrailing": 8, "insetV": 12],
            .medium: ["rim": 4, "insetOuter": 10, "gapGauge": 12, "gapSection": 16, "gapRow": 6,
                      "gapInline": 8, "gapControls": 8, "ctrlHit": 24, "shadow": 24,
                      "gapTextTrailing": 10, "insetV": 16],
            .large: ["rim": 4, "insetOuter": 12, "gapGauge": 14, "gapSection": 20, "gapRow": 8,
                     "gapInline": 10, "gapControls": 10, "ctrlHit": 28, "shadow": 24,
                     "gapTextTrailing": 12, "insetV": 20],
        ]
        for size in sizes {
            guard let want = expected[size] else {
                return XCTFail("no frozen spacing row for \(size)")
            }
            let spacing = Tokens.spacingScale(for: size)
            let actual: [String: CGFloat] = [
                "rim": spacing.rim, "insetOuter": spacing.insetOuter,
                "gapGauge": spacing.gapGauge, "gapSection": spacing.gapSection,
                "gapRow": spacing.gapRow, "gapInline": spacing.gapInline,
                "gapControls": spacing.gapControls, "ctrlHit": spacing.ctrlHit,
                "shadow": spacing.shadow, "gapTextTrailing": spacing.gapTextTrailing,
                "insetV": spacing.insetV,
            ]
            XCTAssertEqual(actual, want, "\(size) spacing scale drifted")
        }
    }

    /// The frozen type table.
    func test_typeScale_matchesItsFrozenPerSizeClassTable() {
        let expected: [(PomoSize, CGFloat, CGFloat, CGFloat)] = [
            (.small, 8, 10, 16),
            (.medium, 9, 12, 20),
            (.large, 11, 14, 24),
        ]
        for (size, caption, header, countdown) in expected {
            let type = Tokens.typeScale(for: size)
            XCTAssertEqual(type.caption, caption, "\(size) caption")
            XCTAssertEqual(type.header, header, "\(size) header")
            XCTAssertEqual(type.countdown, countdown, "\(size) countdown")
        }
    }

    /// The frozen segment table.
    func test_segScale_matchesItsFrozenPerSizeClassTable() {
        let expected: [(PomoSize, CGFloat, CGFloat)] = [
            (.small, 8, 16), (.medium, 10, 20), (.large, 12, 24),
        ]
        for (size, w, h) in expected {
            let seg = Tokens.segScale(for: size)
            XCTAssertEqual(seg.w, w, "\(size) seg.w")
            XCTAssertEqual(seg.h, h, "\(size) seg.h")
        }
    }

    /// Documented: `gap.textTrailing` is "frozen equal to insetOuter per size
    /// class", which is what makes the effective edge margin exactly double.
    func test_spacingScale_freezesTheTextTrailingGapEqualToTheOuterInset() {
        for size in sizes {
            let spacing = Tokens.spacingScale(for: size)
            XCTAssertEqual(spacing.gapTextTrailing, spacing.insetOuter, "\(size)")
        }
    }

    /// The rim guard and the shadow margin are size-independent constants; if
    /// one of them ever became per-size, `windowSize` and `centeredGlassRect`
    /// would need revisiting.
    func test_spacingScale_keepsTheRimAndShadowIdenticalAcrossSizeClasses() {
        let rims = sizes.map { Tokens.spacingScale(for: $0).rim }
        let shadows = sizes.map { Tokens.spacingScale(for: $0).shadow }
        XCTAssertEqual(Set(rims).count, 1, "rim differs per size class: \(rims)")
        XCTAssertEqual(Set(shadows).count, 1, "shadow differs per size class: \(shadows)")
        XCTAssertEqual(rims.first, 4)
        XCTAssertEqual(shadows.first, 24)
    }

    /// The whole point of the size classes: bigger class, bigger spacing.
    func test_spacingScale_growsFromSmallToMediumToLarge() {
        let small = Tokens.spacingScale(for: .small)
        let medium = Tokens.spacingScale(for: .medium)
        let large = Tokens.spacingScale(for: .large)

        for (smaller, bigger, name) in [(small, medium, "small→medium"), (medium, large, "medium→large")] {
            XCTAssertGreaterThan(bigger.insetOuter, smaller.insetOuter, "\(name) insetOuter")
            XCTAssertGreaterThan(bigger.insetV, smaller.insetV, "\(name) insetV")
            XCTAssertGreaterThan(bigger.gapGauge, smaller.gapGauge, "\(name) gapGauge")
            XCTAssertGreaterThan(bigger.gapSection, smaller.gapSection, "\(name) gapSection")
            XCTAssertGreaterThan(bigger.gapInline, smaller.gapInline, "\(name) gapInline")
            XCTAssertGreaterThan(bigger.gapControls, smaller.gapControls, "\(name) gapControls")
            XCTAssertGreaterThan(bigger.ctrlHit, smaller.ctrlHit, "\(name) ctrlHit")
            XCTAssertGreaterThanOrEqual(bigger.gapRow, smaller.gapRow, "\(name) gapRow")
        }
    }

    /// The vertical inset is its own token precisely so it can be roomier than
    /// the horizontal-edge-safety one it used to borrow.
    func test_spacingScale_givesTheVerticalInsetItsOwnLargerValue() {
        for size in sizes {
            let spacing = Tokens.spacingScale(for: size)
            XCTAssertGreaterThan(spacing.insetV, spacing.insetOuter, "\(size)")
        }
    }

    /// macOS pointer targets: the control hit box must stay comfortably
    /// clickable even at the smallest size class.
    func test_spacingScale_keepsTheControlHitTargetUsableAtEverySizeClass() {
        for size in sizes {
            XCTAssertGreaterThanOrEqual(Tokens.spacingScale(for: size).ctrlHit, 20, "\(size)")
        }
    }

    // MARK: - Type scale

    func test_typeScale_ordersCaptionBelowHeaderBelowCountdownAtEverySizeClass() {
        for size in sizes {
            let type = Tokens.typeScale(for: size)
            XCTAssertGreaterThan(type.header, type.caption, "\(size)")
            XCTAssertGreaterThan(type.countdown, type.header, "\(size)")
            XCTAssertGreaterThan(type.caption, 0, "\(size)")
        }
    }

    func test_typeScale_growsFromSmallToMediumToLarge() {
        let small = Tokens.typeScale(for: .small)
        let medium = Tokens.typeScale(for: .medium)
        let large = Tokens.typeScale(for: .large)

        for (smaller, bigger, name) in [(small, medium, "small→medium"), (medium, large, "medium→large")] {
            XCTAssertGreaterThan(bigger.caption, smaller.caption, "\(name) caption")
            XCTAssertGreaterThan(bigger.header, smaller.header, "\(name) header")
            XCTAssertGreaterThan(bigger.countdown, smaller.countdown, "\(name) countdown")
        }
    }

    // MARK: - Segment scale

    /// Documented: `h == w × 2` at every size class, "comfortably above the
    /// h ≥ w × 1.8 floor" that keeps a segment reading as a tall capsule.
    func test_segScale_keepsEachSegmentTwiceAsTallAsItsBaseWidth() {
        for size in sizes {
            let seg = Tokens.segScale(for: size)
            XCTAssertEqual(seg.h, seg.w * 2, "\(size)")
            XCTAssertGreaterThan(seg.w, 0, "\(size)")
        }
    }

    func test_segScale_isOnTheTwoPointGridAndGrowsWithTheSizeClass() {
        for size in sizes {
            let seg = Tokens.segScale(for: size)
            XCTAssertTrue(isOnTwoPointGrid(seg.w), "\(size).w = \(seg.w) is off the grid")
            XCTAssertTrue(isOnTwoPointGrid(seg.h), "\(size).h = \(seg.h) is off the grid")
        }
        XCTAssertGreaterThan(Tokens.segScale(for: .medium).w, Tokens.segScale(for: .small).w)
        XCTAssertGreaterThan(Tokens.segScale(for: .large).w, Tokens.segScale(for: .medium).w)
    }

    // MARK: - Gauge decor

    /// The gauge decor constants the gauge and derivation tests are written in
    /// terms of, pinned numerically. Without this every `XCTAssertEqual(x,
    /// Tokens.Decor.y)` elsewhere could stay green while the token moved.
    func test_gaugeDecorConstants_matchTheirFrozenValues() {
        XCTAssertEqual(Tokens.Decor.segCountFixed, 10)
        XCTAssertEqual(Tokens.Decor.segWidthFactor, 1.25)
        XCTAssertEqual(Tokens.Decor.segGapRatio, 0.4)
        XCTAssertEqual(Tokens.Decor.segFramePad, 2)
        XCTAssertEqual(Tokens.Decor.segFrameStroke, 1.5)
        XCTAssertEqual(Tokens.Decor.segCornerFactor, 0.5)
        XCTAssertEqual(Tokens.Decor.segConsumedOpacityMax, 0.45, accuracy: 1e-12)
        XCTAssertEqual(Tokens.Decor.segConsumedOpacityMin, 0.22, accuracy: 1e-12)
        XCTAssertEqual(Tokens.Decor.cornerFactor, 0.30, accuracy: 1e-12)
    }

    /// The gauge is FIXED at ten segments at every size class — the whole
    /// `barRowW`/`contentW` derivation assumes the count does not vary.
    func test_segmentCount_isFixedAtTenForEverySizeClass() {
        XCTAssertEqual(Tokens.Decor.segCountFixed, 10)
        for size in sizes {
            XCTAssertEqual(PillLayout(sizeClass: size, minuteDigits: 2).segCount, 10, "\(size)")
            XCTAssertEqual(PillLayout(sizeClass: size, minuteDigits: 3).segCount, 10, "\(size)")
        }
    }

    /// The consumed ramp must be ordered and visible: min below max, both
    /// inside a legal opacity range, and the dimmest segment still on screen.
    func test_consumedOpacityRange_isOrderedAndStillVisibleAtItsDimmest() {
        XCTAssertLessThan(Tokens.Decor.segConsumedOpacityMin, Tokens.Decor.segConsumedOpacityMax)
        XCTAssertGreaterThan(Tokens.Decor.segConsumedOpacityMin, 0)
        XCTAssertLessThanOrEqual(Tokens.Decor.segConsumedOpacityMax, 1)
        // …and the consumed run must stay dimmer than a lit bar (opacity 1.0),
        // or the "already elapsed" half of the gauge stops reading as spent.
        XCTAssertLessThan(Tokens.Decor.segConsumedOpacityMax, 1)
    }

    /// The drawn segment is wider than its base token (thicker bars) while the
    /// gap is a fraction of that width (snug row) — the documented
    /// "segment : gap ≈ 2.5 : 1". Asserted against literals rather than the
    /// tokens the implementation multiplies by, so this cannot become "x == x".
    func test_segmentWidthAndGapFactors_produceASnugRowWithBarsWiderThanGaps() {
        XCTAssertGreaterThanOrEqual(Tokens.Decor.segWidthFactor, 1)
        XCTAssertGreaterThan(Tokens.Decor.segGapRatio, 0)
        XCTAssertLessThan(Tokens.Decor.segGapRatio, 1)

        for size in sizes {
            let layout = PillLayout(sizeClass: size, minuteDigits: 2)
            XCTAssertEqual(layout.segWActual, Tokens.segScale(for: size).w * 1.25,
                           accuracy: 1e-12, "\(size) drawn bar width")
            XCTAssertGreaterThan(layout.segWActual, layout.seg.w,
                                 "\(size) the drawn bar is no longer thicker than the base token")
            XCTAssertEqual(layout.segWActual / layout.segGapActual, 2.5, accuracy: 1e-9, "\(size)")
        }
    }

    /// The boundary outline is drawn OUTSIDE the segment it brackets, so both
    /// the pad and the stroke must be positive — and the pad must be small
    /// enough that the marker does not swallow the neighbouring bar.
    func test_boundaryOutlineMetrics_arePositiveAndSitOutsideTheSegmentWithoutSwallowingItsNeighbour() {
        XCTAssertGreaterThan(Tokens.Decor.segFramePad, 0)
        XCTAssertGreaterThan(Tokens.Decor.segFrameStroke, 0)
        for size in sizes {
            let layout = PillLayout(sizeClass: size, minuteDigits: 2)
            XCTAssertLessThanOrEqual(Tokens.Decor.segFramePad, layout.segGapActual,
                                     "\(size) the marker's pad overruns the gap beside it")
            guard let frame = layout.boundaryFrame(litCount: 5, total: layout.segCount) else {
                return XCTFail("\(size) no boundary frame mid-gauge")
            }
            XCTAssertLessThan(frame.x, layout.segmentX(4), "\(size) marker starts inside the bar")
            XCTAssertGreaterThan(frame.x + frame.width, layout.segmentX(5) + layout.segWActual,
                                 "\(size) marker ends inside the bar")
        }
    }

    // MARK: - Corner shape

    /// 0.30 is a "relaxed, reference-card-style corner", explicitly NOT the
    /// old full-stadium `height × 0.5`. Above 0.5 the radius would exceed half
    /// the height and `CapsuleMask` would have to clamp it.
    func test_cornerFactor_isARelaxedCornerAndNotAFullStadium() {
        XCTAssertGreaterThan(Tokens.Decor.cornerFactor, 0)
        XCTAssertLessThan(Tokens.Decor.cornerFactor, 0.5)
    }

    /// A corner radius derived from the drawn glass height must never exceed
    /// half of it, or the capsule shape degenerates.
    func test_cornerRadius_atEverySizeClass_staysBelowHalfTheGlassHeight() {
        for size in sizes {
            for digits in [2, 3] {
                let layout = PillLayout(sizeClass: size, minuteDigits: digits)
                let radius = layout.glassH * Tokens.Decor.cornerFactor
                XCTAssertLessThan(radius, layout.glassH / 2, "\(size)/\(digits)-digit")
                XCTAssertGreaterThan(radius, 0, "\(size)/\(digits)-digit")
            }
        }
    }

    // MARK: - Opacity tokens

    /// Every opacity token has to be a legal SwiftUI opacity; a value outside
    /// 0…1 is silently clamped at the call site instead of failing loudly.
    func test_everyOpacityToken_isWithinTheLegalZeroToOneRange() {
        let opacities: [(String, Double)] = [
            ("opacityCaptionDim", Tokens.Decor.opacityCaptionDim),
            ("opacityCaption", Tokens.Decor.opacityCaption),
            ("ctrlHoverFill", Tokens.Decor.ctrlHoverFill),
            ("ctrlIconOpacityIdle", Tokens.Decor.ctrlIconOpacityIdle),
            ("ctrlIconOpacityHovered", Tokens.Decor.ctrlIconOpacityHovered),
            ("opacityHeaderChip", Tokens.Decor.opacityHeaderChip),
            ("glassHighlightOpacity", Tokens.Decor.glassHighlightOpacity),
            ("ringOpacity", Tokens.Decor.ringOpacity),
            ("opacityPausedDim", Tokens.Decor.opacityPausedDim),
            ("idleToggleFill", Tokens.Decor.idleToggleFill),
            ("segGlowInnerOpacity", Tokens.Decor.segGlowInnerOpacity),
            ("segGlowOuterOpacity", Tokens.Decor.segGlowOuterOpacity),
            ("segConsumedOpacityMax", Tokens.Decor.segConsumedOpacityMax),
            ("segConsumedOpacityMin", Tokens.Decor.segConsumedOpacityMin),
        ]
        for (name, value) in opacities {
            XCTAssertGreaterThanOrEqual(value, 0, "\(name) = \(value)")
            XCTAssertLessThanOrEqual(value, 1, "\(name) = \(value)")
        }
        // Every dimming token must actually dim; a table of 1.0s would satisfy
        // the range check above while making the pill flat.
        XCTAssertLessThan(Tokens.Decor.opacityCaptionDim, Tokens.Decor.opacityCaption,
                          "the Today readout must be dimmer than the countdown")
        XCTAssertLessThan(Tokens.Decor.ctrlIconOpacityIdle, Tokens.Decor.ctrlIconOpacityHovered,
                          "hovering a control must brighten its glyph")
        XCTAssertLessThan(Tokens.Decor.segGlowOuterOpacity, Tokens.Decor.segGlowInnerOpacity,
                          "the outer bloom must be softer than the inner glow")
        XCTAssertLessThan(Tokens.Decor.opacityPausedDim, 1, "pausing must visibly dim the pill")
    }

    func test_glassHighlight_isAThinTopReflection() {
        XCTAssertGreaterThan(Tokens.Decor.glassHighlightLineWidth, 0)
        XCTAssertLessThanOrEqual(Tokens.Decor.glassHighlightLineWidth, 1)
        XCTAssertGreaterThan(Tokens.Decor.glassHighlightFadeStop, 0)
        XCTAssertLessThan(Tokens.Decor.glassHighlightFadeStop, 0.5)
    }

    func test_hoverActivationDelay_isExactlyThreeTenthsOfASecond() {
        XCTAssertEqual(Tokens.Glass.hoverActivationDelay, 0.3, accuracy: 1e-12)
    }

    /// The control glyph must fit inside its hit target with room to spare, and
    /// the press/hover scales must move in opposite directions.
    func test_controlGlyphMetrics_fitTheHitTargetAndScaleInOppositeDirections() {
        XCTAssertGreaterThan(Tokens.Decor.ctrlIconFactor, 0)
        XCTAssertLessThan(Tokens.Decor.ctrlIconFactor, 1)
        XCTAssertGreaterThan(Tokens.Decor.ctrlScaleHovered, 1, "hover must grow the control")
        XCTAssertLessThan(Tokens.Decor.ctrlScalePressed, 1, "press must shrink the control")
        for size in sizes {
            let hit = Tokens.spacingScale(for: size).ctrlHit
            let glyph = hit * Tokens.Decor.ctrlIconFactor
            XCTAssertLessThan(glyph * Tokens.Decor.ctrlScaleHovered, hit,
                              "\(size) the hovered glyph overflows its hit target")
            XCTAssertGreaterThanOrEqual(glyph, 10, "\(size) the glyph is too small to read")
        }
    }

    /// The break palette is the other half of one cross-fade: the "bright"
    /// tone must actually be lighter than the "deep" one, or the work→break
    /// lerp inverts mid-transition.
    func test_breakPalette_keepsTheBrightToneLighterThanTheDeepTone() {
        let bright = Tokens.Decor.breakPinkBrightRGB
        let deep = Tokens.Decor.breakPinkDeepRGB
        let brightLuma = bright.0 + bright.1 + bright.2
        let deepLuma = deep.0 + deep.1 + deep.2
        XCTAssertGreaterThan(brightLuma, deepLuma)
        for channel in [bright.0, bright.1, bright.2, deep.0, deep.1, deep.2] {
            XCTAssertGreaterThanOrEqual(channel, 0)
            XCTAssertLessThanOrEqual(channel, 1)
        }
        // Pinned to the documented hex pair so a re-tint is a deliberate edit.
        XCTAssertEqual(bright.0, 0xFB / 255.0, accuracy: 1e-12)
        XCTAssertEqual(deep.0, 0xBE / 255.0, accuracy: 1e-12)
    }
}
