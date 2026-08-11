import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Token-first spacing system
//
// Two number families ONLY are allowed to drive layout in this app:
//   (a) Spacing     — 2pt-grid tokens, frozen per size class.
//   (b) Type-metric — ratios of a `TypeScale` value.
// Every other geometry value (contentH, glassW, pillSize, windowSize, ...) is
// a pure function of those two plus {sizeClass, minuteDigits}. Dimensions flow
// ONE way:
//
//   SizeClass(S/M/L) + minuteDigits(2|3)
//     → tokens → contentH/contentW → glass → pill → window
//
// No SwiftUI runtime measurement (PreferenceKey / GeometryReader) is used —
// everything below is deterministic, so PomoView, TimerInstanceController,
// PomoSize, and the PNG QA harness (main.swift) all call the same functions
// and agree byte-for-byte on every dimension.
enum Tokens {

    // MARK: 1.1 Type scale — three frozen values per size class, no ratios.
    //   caption   — the Today readout in row1
    //   header    — row1's timer icon + task name
    //   countdown — row2's hero number (bold, .rounded, monospacedDigit)
    struct TypeScale {
        let caption: CGFloat
        let header: CGFloat
        let countdown: CGFloat
    }

    static func typeScale(for size: PomoSize) -> TypeScale {
        switch size {
        case .small:  return TypeScale(caption: 8,  header: 10, countdown: 16)
        case .medium: return TypeScale(caption: 9,  header: 12, countdown: 20)
        case .large:  return TypeScale(caption: 11, header: 14, countdown: 24)
        }
    }

    // MARK: 1.3 Spacing (2pt grid, frozen per size class)
    struct SpacingScale {
        let rim: CGFloat          // space.rim    — VEV rim guard (pill → glass)
        let insetOuter: CGFloat   // inset.outer  — glass edge → content, 4 sides
        /// gap.gauge — the horizontal gap beside the hero readout, i.e.
        /// between row2's countdown and the segmented gauge.
        let gapGauge: CGFloat
        let gapSection: CGFloat   // gap.section  — task name → trailing cluster (min)
        let gapRow: CGFloat       // gap.row      — vertical row spacing
        let gapInline: CGFloat    // gap.inline   — timer icon ↔ task name
        let gapControls: CGFloat  // gap.controls — between control buttons
        let ctrlHit: CGFloat      // ctrl.hit     — button hit target
        let shadow: CGFloat       // space.shadow — window shadow margin
        /// gap.textTrailing — extra breathing room between the trailing
        /// text/controls column and the glass's trailing inset.outer edge.
        /// Frozen equal to insetOuter per size class, so the *effective*
        /// right-edge margin doubles (inset.outer + gap.textTrailing) without
        /// touching glassW/pillW/windowSize — the FILL Spacer between the
        /// gauge and this column absorbs the extra width; it's just budgeted
        /// to the trailing end of the row instead of the middle gap. Exists
        /// as a blur-edge safety margin: at full blur the digits/controls
        /// read too close to the trailing glass edge, risking a see-through
        /// clip at the softest blur settings.
        let gapTextTrailing: CGFloat
        /// inset.v — dedicated vertical glass inset (top/bottom, content →
        /// glass edge). Previously the pill reused `insetOuter` (a
        /// horizontal-edge-safety token) for vertical padding too, which read
        /// as cramped top/bottom breathing room; this is now its own token so
        /// the two axes can be tuned independently. Horizontal inset
        /// (`insetH` on PillLayout) is unchanged — still `insetOuter +
        /// gapTextTrailing`.
        let insetV: CGFloat
    }

    static func spacingScale(for size: PomoSize) -> SpacingScale {
        switch size {
        case .small:
            return SpacingScale(rim: 4, insetOuter: 8, gapGauge: 10, gapSection: 12,
                                 gapRow: 6, gapInline: 6, gapControls: 6, ctrlHit: 20,
                                 shadow: 24, gapTextTrailing: 8, insetV: 12)
        case .medium:
            return SpacingScale(rim: 4, insetOuter: 10, gapGauge: 12, gapSection: 16,
                                 gapRow: 6, gapInline: 8, gapControls: 8, ctrlHit: 24,
                                 shadow: 24, gapTextTrailing: 10, insetV: 16)
        case .large:
            return SpacingScale(rim: 4, insetOuter: 12, gapGauge: 14, gapSection: 20,
                                 gapRow: 8, gapInline: 10, gapControls: 10, ctrlHit: 28,
                                 shadow: 24, gapTextTrailing: 12, insetV: 20)
        }
    }

    /// Segmented gauge scale. A separate struct rather than more SpacingScale
    /// fields, so the two can be tuned without disturbing each other's
    /// memberwise init. All values on the 2pt grid.
    struct SegScale {
        let w: CGFloat          // seg.w — base segment width (scaled by Decor.segWidthFactor)
        let h: CGFloat          // seg.h — segment height
    }

    /// Base widths for the fixed 10-segment gauge. `h == w × 2` at every size
    /// class.
    ///
    /// That ratio describes the BASE token, not the bar on screen: the drawn
    /// width is `PillLayout.segWActual` (w × `Decor.segWidthFactor`, 1.25), so
    /// the rendered aspect is 2.0/1.25 = 1.6:1. An earlier version of this
    /// comment claimed the 2:1 cleared an "h ≥ w×1.8" floor for the drawn bar;
    /// it does not, and predates `segWidthFactor`. What holds is that the bar
    /// stays taller than it is wide, which is what keeps it reading as a
    /// capsule rather than a dot.
    static func segScale(for size: PomoSize) -> SegScale {
        switch size {
        case .small:  return SegScale(w: 8,  h: 16)
        case .medium: return SegScale(w: 10, h: 20)
        case .large:  return SegScale(w: 12, h: 24)
        }
    }

    /// Named decorative ratios that were bare
    /// literals in PomoView. These are appearance constants, not spacing/type
    /// tokens — they don't participate in the geometry flow, they're just
    /// given names so no magic numbers remain in the view body.
    enum Decor {
        static let opacityCaptionDim: Double  = 0.68   // Today readout
        static let opacityCaption: Double     = 0.90   // idle-state countdown dim

        // MARK: Control buttons (setup and runtime rows)
        /// Glyph size as a fraction of the `ctrl.hit` target.
        static let ctrlIconFactor: CGFloat        = 0.50
        static let ctrlHoverFill: Double          = 0.20
        static let ctrlIconOpacityIdle: Double    = 0.70
        static let ctrlIconOpacityHovered: Double = 1.0
        static let ctrlScalePressed: CGFloat      = 0.90
        static let ctrlScaleHovered: CGFloat      = 1.10
        /// Opacity of the header's task-name + timer-icon chip.
        static let opacityHeaderChip: Double      = 0.95
        /// Local fill behind the two inline fields while idle editing is active.
        static let editorFillOpacity: Double      = 0.12

        // MARK: Glass top reflection
        static let glassHighlightLineWidth: CGFloat = 1
        static let glassHighlightOpacity: Double = 0.55
        static let glassHighlightFadeStop: Double = 0.36

        // MARK: Gauge decor (row2)
        static let ringOpacity: Double        = 0.35  // boundary-marker outline opacity
        static let opacityPausedDim: Double   = 0.5   // paused-state dim (gauge + readout)
        static let idleToggleFill: Double     = 0.12  // idle ▶ button's always-on fill emphasis

        // MARK: Work palette — SINGLE unified source for every green in the
        // pill. RGB(0,167,96) default. Every "green family" value (the lit
        // segment, the header icon + task-name accent, the boundary ring
        // tint) is a DERIVED mix of this one triple — no independent green
        // hex literal is allowed anywhere else in the codebase. Kept as a raw
        // (Double,Double,Double) triple rather than a SwiftUI `Color` so
        // PomoView's tuple-based `lerpColor` cross-fade can consume it
        // directly.
        //
        // Supply source is `AccentColorStore` (settings-driven, ⚙→"Gauge
        // Color…") — a computed var, so every call site picks up a change
        // live with no code change on its part.
        static var accentGreenRGB: (Double, Double, Double) { AccentColorStore.shared.rgb }

        /// Blend-toward-white amount for the "bright" variant (lit segment +
        /// header icon/task-name accent) — lightens the base accent so it
        /// reads clearly against the dark glass.
        static let accentGreenBrightMix: Double = 0.60
        /// Blend-toward-black amount for the "deep" variant (the consumed
        /// segments' baseline colour).
        static let accentGreenDeepMix: Double = 0.18
        /// Blend-toward-accentGreen amount for the white dot's outer ring
        /// stroke — a SUBTLE tint (the ring must still read as "white with a
        /// hint of the brand green", not a full recolor). The call site
        /// cross-fades this toward pure white (1,1,1) via `phaseT` so the
        /// break-phase ring stays exactly the original plain white.
        static let accentGreenRingMix: Double = 0.22

        private static func mixRGB(_ a: (Double, Double, Double),
                                    _ b: (Double, Double, Double),
                                    _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }

        /// Bright (lit-segment / accent) tone — accentGreen lightened toward white.
        static var accentGreenBrightRGB: (Double, Double, Double) {
            mixRGB(accentGreenRGB, (1, 1, 1), accentGreenBrightMix)
        }
        /// Deep (track / gradient-stop) tone — accentGreen darkened toward black.
        static var accentGreenDeepRGB: (Double, Double, Double) {
            mixRGB(accentGreenRGB, (0, 0, 0), accentGreenDeepMix)
        }
        /// White-dot ring tint at t=0 (pure work) — the caller lerps this
        /// toward (1,1,1) using `phaseT` so break keeps the untouched
        /// original white ring.
        static var accentGreenRingRGB: (Double, Double, Double) {
            mixRGB((1, 1, 1), accentGreenRGB, accentGreenRingMix)
        }

        // MARK: Break palette — the pink half of the work↔break cross-fade.
        // Same rule the green above states: these are the only pink literals
        // in the codebase, so the two halves of one gradient are governed by
        // one convention rather than two.
        /// #FBCFE8 — the bright/lit tone during a break.
        static let breakPinkBrightRGB: (Double, Double, Double) =
            (0xFB/255.0, 0xCF/255.0, 0xE8/255.0)
        /// #BE185D — the deep/consumed tone during a break.
        static let breakPinkDeepRGB: (Double, Double, Double) =
            (0xBE/255.0, 0x18/255.0, 0x5D/255.0)

        // MARK: Corner shape (task #4 — relaxed circular corners)
        /// cornerRadius = glassH × cornerFactor. Replaces the old full-capsule
        /// `glassH × 0.5` — 0.30 reads as a relaxed, reference-card-style
        /// corner instead of a stadium/pill. This is the SINGLE source both
        /// SwiftUI (`PomoView.cornerRadius`) and AppKit (the VEV mask) derive
        /// from, so the blur glass and overtime glow cannot desync.
        static let cornerFactor: CGFloat = 0.30

        // MARK: Segmented gauge decor
        /// Corner radius = seg.w × this. 0.5 rounds both ends fully, so each
        /// segment reads as a tall capsule.
        static let segCornerFactor: CGFloat = 0.5
        /// Outline frame: segment outer edge → frame inner edge padding.
        static let segFramePad: CGFloat = 2
        /// Boundary outline frame stroke width.
        static let segFrameStroke: CGFloat = 1.5
        /// Inner glow blur radius = seg.w × this.
        static let segGlowInnerRadiusFactor: CGFloat = 0.5
        /// Outer glow blur radius = seg.w × this.
        static let segGlowOuterRadiusFactor: CGFloat = 1.5
        static let segGlowInnerOpacity: Double = 0.85
        static let segGlowOuterOpacity: Double = 0.45
        /// Consumed side: opacity of the segment nearest the boundary.
        static let segConsumedOpacityMax: Double = 0.45
        /// Consumed side: opacity of the farthest (rightmost) segment.
        static let segConsumedOpacityMin: Double = 0.22

        /// seg.countFixed (task pomo-ten-segments-and-pin) — the gauge always
        /// shows exactly this many segments at every size class. Replaces the
        /// old pitch-derived `segCount` (max segments that fit at
        /// w+gapNominal pitch, which gave S18/M16/L15 — "多い気がする" per
        /// user feedback). `PillLayout.segGapActual`'s rounding-absorption
        /// formula is unchanged; it just now divides `barRowW` by this fixed
        /// count instead of a pitch-fit count.
        static let segCountFixed: Int = 10

        /// seg.widthFactor — multiplier on the base `SegScale.w`, driving the
        /// effective segment width (`PillLayout.segWActual`). Height is left at
        /// `seg.h` (user feedback: keep the vertical length, thin the width).
        /// The gap fills whatever `barRowW` remains, so the row always fills the
        /// bar exactly. 1.0 = the original thin bars with wide gaps ("間が広い");
        /// higher = chunkier bars + tighter gaps. 1.25 keeps the tightened-gap
        /// look while slimming the bars back down from the earlier ~1.48 that
        /// read as fat ovals.
        static let segWidthFactor: CGFloat = 1.25

        /// seg.gapRatio — gap width as a fraction of `segWActual` (user feedback
        /// "ゲージ一本一本の間隔を狭めて", asked AFTER width was already thinned —
        /// so this narrows the gap independently rather than by widening bars
        /// again). 0.4 ⇒ segment:gap ≈ 2.5:1, a visibly snug row.
        static let segGapRatio: CGFloat = 0.4
    }

    /// Glass and pointer-hover timings. SwiftUI animation curves stay in
    /// `PomoView.Motion`; the AppKit glass durations live here beside the
    /// shared dwell threshold.
    ///
    /// The two values differ by 0.02s. That is probably accidental, but
    /// unifying them would change one animation's duration — a behaviour
    /// change, not a cleanup — so they stay distinct and merely visible.
    enum Glass {
        /// Pointer dwell required before the pill enters its expanded hover state.
        static let hoverActivationDelay: TimeInterval = 0.30
        /// Glass following a pill resize (S/M/L switch, digit-count change).
        static let resizeDuration: TimeInterval = 0.28
        /// Glass following the hover grow/shrink.
        static let hoverDuration: TimeInterval = 0.30
    }

    /// Modal NSAlert accessory-field sizing. Not per-`PomoSize`: these dialogs
    /// are system modals, not part of the pill.
    enum Dialog {
        static let fieldHeight: CGFloat = 24
        /// Numeric input (a minute count) — narrow is fine.
        static let numericFieldWidth: CGFloat = 200
        /// Free text (task names, review notes) — wider, since these run long
        /// and are often Japanese.
        static let textFieldWidth: CGFloat = 260
    }

    /// The tuning panel's own NSWindow geometry (⌘T). Lives here so its size
    /// is written once and the placement math cannot desync from it.
    enum Panel {
        static let tuningSize = NSSize(width: 360, height: 680)
        /// Gap between the pill's left edge and the panel's right edge.
        static let tuningGutter: CGFloat = 20
    }
}

/// Pure-function geometry for one pill configuration. Every dimension the
/// pill draws — the SwiftUI content AND the AppKit window/VEV — comes from
/// here. See the task spec §1.4 for the derivation and §4 for the frozen
/// S/M/L numeric table this was validated against.
struct PillLayout {
    let sizeClass: PomoSize
    /// 2 or 3 — see `PomodoroSource.minuteDigits`. Upper bound is 3 (Custom max
    /// is 180 minutes).
    let minuteDigits: Int

    var type: Tokens.TypeScale { Tokens.typeScale(for: sizeClass) }
    var spacing: Tokens.SpacingScale { Tokens.spacingScale(for: sizeClass) }

    // MARK: 1.4 Derivation — 2 rows: header / bottom
    //
    // row1 header, row2 = [countdown (left)] [gap.gauge] [segmented gauge].

    /// Countdown digit metrics. The 0.72/0.34 ratios carry a deliberate
    /// safety margin over the font's measured glyph widths: `countdownReadout`
    /// renders the whole "m:ss" as ONE concatenated monospacedDigit `Text`,
    /// and a tighter 0.60/0.30 pair clipped "17:00" to "17:…" in the live QA
    /// render.
    var countdownDigitW: CGFloat { type.countdown * 0.72 }
    var countdownColonW: CGFloat { type.countdown * 0.34 }
    var countdownH: CGFloat { type.countdown * 1.20 }

    /// `(minuteDigits + 2)` digit slots — minuteDigits for the minutes, +2 for
    /// the seconds — plus one colon glyph.
    var countdownW: CGFloat {
        let slots = CGFloat(minuteDigits + 2)
        return Self.ceil2(slots * countdownDigitW + countdownColonW)
    }

    // MARK: - Segmented gauge derivation

    var seg: Tokens.SegScale { Tokens.segScale(for: sizeClass) }

    /// Fixed at 10 segments for every size class (user: "10個くらいにして。
    /// 多い気がする"). Nothing downstream — barRowW, contentW, windowSize —
    /// keys off the count except through `segClusterW`.
    var segCount: Int { Tokens.Decor.segCountFixed }

    /// The segment width actually drawn: `seg.w` scaled by `segWidthFactor`.
    /// Height stays `seg.h` (user: keep the vertical length, thin the width).
    var segWActual: CGFloat {
        seg.w * Tokens.Decor.segWidthFactor
    }

    /// Gap between segments, a fixed fraction of `segWActual` (user: "間隔を
    /// 狭めて"). Deliberately NOT the leftover space in `barRowW` — deriving
    /// it that way coupled width and gap, so the only way to narrow one was to
    /// widen the other. `barRowW` is derived from the cluster instead.
    var segGapActual: CGFloat {
        segWActual * Tokens.Decor.segGapRatio
    }
    /// The exact drawn width of the N-segment cluster (N bars + N−1 gaps). Since
    /// gap is now a fixed ratio of width (not the `barRowW` remainder), this is
    /// the TRUE width the gauge occupies — the bar row (`barRowW`) is derived
    /// FROM this so the last segment's right edge lands exactly at the content
    /// trailing edge (aligned with the ⚙ button above). No trailing empty glass.
    var segClusterW: CGFloat {
        CGFloat(segCount) * segWActual + CGFloat(segCount - 1) * segGapActual
    }
    /// Segment row height = segment height + the outline frame's pad+stroke
    /// on both top and bottom.
    var segRowH: CGFloat {
        seg.h + 2 * (Tokens.Decor.segFramePad + Tokens.Decor.segFrameStroke)
    }

    /// Leading edge of segment `i` within the bar row.
    func segmentX(_ i: Int) -> CGFloat {
        CGFloat(i) * (segWActual + segGapActual)
    }

    /// Opacity of a consumed (already-elapsed) segment. Ramps down from
    /// `segConsumedOpacityMax` at the boundary to `segConsumedOpacityMin` at
    /// the far end; a lone consumed segment gets the max.
    /// `index` is the offset from the boundary, 0 = nearest it.
    static func consumedSegmentOpacity(index: Int, consumedCount: Int) -> Double {
        guard consumedCount > 1 else { return Tokens.Decor.segConsumedOpacityMax }
        let t = Double(index) / Double(consumedCount - 1)
        return Tokens.Decor.segConsumedOpacityMax
            - (Tokens.Decor.segConsumedOpacityMax - Tokens.Decor.segConsumedOpacityMin) * t
    }

    /// Frame of the outline that marks the current position. It brackets the
    /// boundary PAIR (the last lit segment and the first consumed one) when
    /// both exist, and just the last lit segment at full progress. Returns nil
    /// when nothing is lit and so no marker is drawn.
    func boundaryFrame(litCount: Int, total: Int) -> (x: CGFloat, width: CGFloat)? {
        // Guarded on BOTH sides. `litSegmentCount` clamps, so no caller can
        // currently overshoot — but with litCount > total the isPair test goes
        // false and the marker would be drawn a whole pitch past the end of
        // the gauge, which is a stranger failure than drawing nothing.
        guard litCount >= 1, litCount <= total else { return nil }
        let pad = Tokens.Decor.segFramePad
        let isPair = litCount <= total - 1
        let width = (isPair ? 2 * segWActual + segGapActual : segWActual) + 2 * pad
        return (x: segmentX(litCount - 1) - pad, width: width)
    }

    /// Lit segment count from a remaining-time ratio (`PomodoroSource.remainingRatio`).
    /// A static pure function (no PomodoroSource dependency) so the PNG QA harness
    /// and future tests can call it directly. ratio>0 always yields ≥1 (the
    /// final segment stays lit until 0:00); ratio==0 yields 0.
    static func litSegmentCount(remainingRatio: Double, total: Int) -> Int {
        guard remainingRatio > 0 else { return 0 }
        return min(total, max(1, Int(ceil(remainingRatio * Double(total)))))
    }

    /// Row2's height = the taller of the countdown text or the segmented
    /// gauge's own row height (segment + outline frame), so neither ever
    /// clips or floats off-center.
    var row2H: CGFloat { max(countdownH, segRowH) }

    /// contentH = row1(ctrlHit) + gap.row + row2.
    var contentH: CGFloat {
        spacing.ctrlHit + spacing.gapRow + row2H
    }

    // MARK: Row1 (header) width derivation

    /// SF Symbol "timer" slot width (row1 leading icon).
    var headerIconW: CGFloat { type.header * 1.2 }
    /// Minimum reserved width for the task name before it truncates.
    var taskMinW: CGFloat { type.header * 6 }

    /// Trailing-space reserve that keeps the header and runtime controls from
    /// collapsing the task label at the smallest supported layout.
    var controlsW: CGFloat { 2 * spacing.ctrlHit + spacing.gapControls }
    var headerTrailingW: CGFloat { controlsW }
    /// Minimum content width row1 needs: icon + gap + task(min) + gap + trailing cluster.
    var headerMinW: CGFloat {
        headerIconW + spacing.gapInline + taskMinW + spacing.gapSection + headerTrailingW
    }
    /// Content width = max(row2's own need — the ACTUAL segment cluster width
    /// plus the countdown column and their gap — vs. header's minimum need).
    /// Using `segClusterW` (not the old fixed `barMinW`) means the pill is only
    /// as wide as the gauge actually draws, so its right edge stays aligned
    /// with the header's trailing edge.
    var contentW: CGFloat {
        Self.ceil2(max(segClusterW + countdownW + spacing.gapGauge, headerMinW))
    }
    /// Row2's bar frame is exactly the segment cluster width, so the gauge fills
    /// its frame edge-to-edge and the last segment's right edge lands at the
    /// content trailing edge. When the header is the wider
    /// constraint the extra width is absorbed by the header's flexible Spacer,
    /// not appended after the bar, so the alignment holds.
    var barRowW: CGFloat { segClusterW }
    /// Horizontal inset (left AND right, symmetric) — insetOuter plus the
    /// blur-edge safety margin (`gapTextTrailing`), applied to both sides now
    /// that the journey bar runs edge-to-edge in both directions (§ decisions.4).
    var insetH: CGFloat { spacing.insetOuter + spacing.gapTextTrailing }

    /// The glass box, snapped to the 2pt grid.
    ///
    /// The snap belongs HERE, not one level up at `pillH`. `segRowH` is
    /// `seg.h + 2*(framePad + frameStroke)` = seg.h + 7, an odd number, so
    /// `contentH` and therefore the raw glass height are odd too. Previously
    /// only `pillH` was snapped, which meant `ceil2` had to absorb that odd
    /// point AFTER the rim guard had been added — and since
    /// `centeredGlassRect` derives the VEV as `pillH - 2*rim`, the spare point
    /// landed entirely in the blur. The live `.behindWindow` material sat 1pt
    /// taller than the SwiftUI content bounds, and
    /// `CapsuleMask` (which reads the corner radius off that taller rect) drew
    /// corners 0.3pt rounder than PomoView's matching overlays.
    ///
    /// Snapping here makes `centeredGlassRect(in:).height == glassH` exactly.
    /// The width already happened to be even at every size class, so the
    /// horizontal snap is a no-op — it is applied for symmetry, so a future
    /// token change cannot reintroduce the same drift on that axis.
    var glassH: CGFloat { Self.ceil2(contentH + 2 * spacing.insetV) }
    var glassW: CGFloat { Self.ceil2(contentW + 2 * insetH) }

    var pillH: CGFloat { Self.ceil2(glassH + 2 * spacing.rim) }
    var pillW: CGFloat { Self.ceil2(glassW + 2 * spacing.rim) }
    var pillSize: NSSize { NSSize(width: pillW, height: pillH) }

    /// Total NSWindow size = pill + shadow margin on every side.
    var windowSize: NSSize {
        let pad = 2 * spacing.shadow
        return NSSize(width: pillW + pad, height: pillH + pad)
    }

    /// 2pt-grid ceiling — the only rounding point in the whole system.
    static func ceil2(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.up) * 2 }

    /// The single authority for how many minute slots the countdown needs.
    /// `PomodoroSource.minuteDigits` calls through to this, so the digits
    /// rendered and the window width sized for them cannot disagree. Static so
    /// the PNG QA harness and previews can call it without a live model.
    static func minuteDigits(forMaxMinutes minutes: Int) -> Int {
        minutes >= 100 ? 3 : 2
    }

    // MARK: - AppKit geometry (glass rect)

    /// The pill rect centered inside `bounds` (window content bounds),
    /// pixel-snapped so the VEV mask is never centered on a half-pixel.
    ///
    /// The `minX`/`minY` terms matter only for a non-origin `bounds`, which no
    /// current caller passes — every one hands in a `container.bounds` or a
    /// rect built at `.zero`. Without them the function centred on the bounds'
    /// SIZE and silently ignored its position, which the signature and the
    /// wording above both promise it does not.
    static func centeredPillRect(in bounds: NSRect, pillSize: NSSize) -> NSRect {
        NSRect(
            x: bounds.minX + ((bounds.width  - pillSize.width)  / 2.0).rounded(.toNearestOrEven),
            y: bounds.minY + ((bounds.height - pillSize.height) / 2.0).rounded(.toNearestOrEven),
            width:  pillSize.width,
            height: pillSize.height
        )
    }

    /// The VEV's rect: the centered pill rect inset by the fixed rim guard
    /// (`space.rim`) on all sides, so the material edge tucks under the
    /// SwiftUI capsule. The single source `TimerInstanceController` uses for
    /// glass geometry.
    func centeredGlassRect(in bounds: NSRect) -> NSRect {
        Self.centeredPillRect(in: bounds, pillSize: pillSize)
            .insetBy(dx: spacing.rim, dy: spacing.rim)
    }

    // MARK: - Debug invariants

    /// §3.5: hover growth must stay inside the window's shadow margin or the
    /// grown glass clips against the window edge.
    func assertHoverScaleSafe(_ hoverScale: CGFloat) {
        let maxSafe = 1 + 2 * spacing.shadow / pillW
        assert(hoverScale <= maxSafe,
               "hoverScale \(hoverScale) exceeds safe margin \(maxSafe) for \(sizeClass)")
    }
}
