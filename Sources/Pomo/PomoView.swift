import SwiftUI

// MARK: - Motion tokens

/// Single source of truth for every animation curve in the pill. Keeping them
/// here makes the micro-interactions feel like one coherent system instead of
/// ad-hoc per-call-site springs — no `Animation` literal belongs below.
private enum Motion {
    static let press     = Animation.spring(response: 0.26, dampingFraction: 0.62)
    static let hover     = Animation.easeOut(duration: 0.16)
    static let pulse     = Animation.spring(response: 0.30, dampingFraction: 0.72)
    static let complete  = Animation.spring(response: 0.40, dampingFraction: 0.50)
    static let reset     = Animation.spring(response: 0.45, dampingFraction: 0.85)
    static let resize    = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let gauge     = Animation.linear(duration: 1.0)
    static let hoverPill = Animation.spring(response: 0.32, dampingFraction: 0.72)
    static let overtime  = Animation.easeInOut(duration: 0.7)
    static let taskSlot  = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Peak scale and hold time for each pulse — kept beside their curves so
    /// the two numbers that must stay in step sit adjacent.
    enum Pulse {
        static let startScale: CGFloat = 1.03
        static let startHold: TimeInterval = 0.16
        static let completeScale: CGFloat = 1.06
        static let completeHold: TimeInterval = 0.26
        /// Screenshot-only forced pulse (POMO_PULSE=1). Numerically equal to
        /// `TuningStore.Default.hoverScale` by coincidence — unrelated
        /// quantities, do not collapse them.
        static let forcedScale: CGFloat = 1.03
    }
}

struct TaskSlotOffsets: Equatable {
    let display: CGFloat
    let editor: CGFloat

    static func resolve(isEditing: Bool, distance: CGFloat, reduceMotion: Bool) -> Self {
        guard !reduceMotion else { return TaskSlotOffsets(display: 0, editor: 0) }
        if isEditing { return TaskSlotOffsets(display: -distance, editor: 0) }
        return TaskSlotOffsets(display: 0, editor: distance)
    }
}

struct DurationEditorLayout: Equatable {
    let minuteTemplate: String

    static func resolve(draft: String) -> Self {
        let slots = min(3, max(2, draft.count))
        return DurationEditorLayout(minuteTemplate: String(repeating: "0", count: slots))
    }
}

struct HoverScaleFactors: Equatable {
    let glass: CGFloat
    let content: CGFloat

    static func resolve(isHovering: Bool, hoverScale: CGFloat) -> Self {
        let glass = isHovering ? hoverScale : 1
        return HoverScaleFactors(glass: glass, content: 1)
    }
}

struct HoverHitRegion: Equatable {
    let size: CGSize
    let cornerRadius: CGFloat

    static func resolve(layout: PillLayout) -> Self {
        HoverHitRegion(
            size: CGSize(width: layout.glassW, height: layout.glassH),
            cornerRadius: layout.glassH * Tokens.Decor.cornerFactor
        )
    }
}

struct PomoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var model: PomodoroSource
    @ObservedObject var sizeController = PomoSizeController.shared
    /// Live-tuning knobs. Defaults equal the former hard-coded literals, so an
    /// untouched store renders identically. Dragging a panel slider mutates a
    /// @Published here → SwiftUI re-lays the contents instantly.
    @ObservedObject var tuning = TuningStore.shared
    /// B: subscribes to gauge-color changes so ⚙→"Gauge Color…" reflects
    /// immediately with no restart — Tokens.Decor.accentGreenRGB reads
    /// through this store on every render, so this @ObservedObject is the
    /// only wiring PomoView needs.
    @ObservedObject var accentStore = AccentColorStore.shared
    /// Injected by the owning `TimerInstanceController` so hover can reach the
    /// AppKit glass — see `PomoHoverState`. Defaults to a fresh instance so
    /// call sites that don't care (the POMO_RENDER_PNG offscreen harness)
    /// still compile.
    @ObservedObject var hoverState: PomoHoverState = PomoHoverState()
    // Hover drives the CONTENTS: the pill expands slightly. The outer look
    // (edge, glass darkness) is fixed so no grey rim ever appears.
    // POMO_FORCE_HOVER pins hover on for screenshots, since `screencapture`
    // can't synthesize a pointer.
    private let forceHover: Bool =
        ProcessInfo.processInfo.environment["POMO_FORCE_HOVER"] == "1"
    @State private var isHovering: Bool =
        ProcessInfo.processInfo.environment["POMO_FORCE_HOVER"] == "1"
    @State private var hoverGeneration: Int = 0

    @State private var pulse: CGFloat = 1.0
    /// Generation token guarding the START pulse's two-stage async chain so a
    /// fresh pulse is never stomped by a stale `reset → 1.0` asyncAfter.
    @State private var pulseGeneration: Int = 0

    /// 0 = work palette, 1 = break palette. COMPLETE cross-fades it.
    @State private var phaseT: Double = 0

    @State private var hoveredButton: ControlButton?
    @State private var pressedButton: ControlButton?
    @State private var draftWorkMinutes = ""
    @State private var minuteInputInvalid = false
    @FocusState private var setupField: SetupField?

    private enum SetupField: Hashable {
        case task
        case minutes
    }

    // MARK: - Token-first layout
    //
    // Single source of truth: `PillLayout`, a pure function of
    // {sizeClass, minuteDigits}. Every geometry value below reads through it
    // — no independent width/height/padding literals live here.
    //   row1: [timer icon + task name] —(FILL, min gap.section)— [Today]
    //   row2: [countdown mm:ss] —gap.gauge— [segmented gauge]
    //   insetH (= inset.outer + gap.textTrailing) left/right, inset.v top/bottom

    private var layout: PillLayout {
        PillLayout(sizeClass: sizeController.current,
                   minuteDigits: model.minuteDigits)
    }

    private var glassW: CGFloat { layout.glassW }
    private var glassH: CGFloat { layout.glassH }
    /// A relaxed, reference-card-style corner (not a full `glassH * 0.5`
    /// stadium capsule). Shares `Tokens.Decor.cornerFactor` and the native
    /// circular curve with the AppKit VEV mask — see `CapsuleMask`.
    private var cornerRadius: CGFloat { glassH * Tokens.Decor.cornerFactor }

    // Buttons: INDEPENDENT fixed size (ctrl.hit token), never shrinks with
    // content padding — gauge fills, buttons stay put.
    private var ctrlHit: CGFloat { layout.spacing.ctrlHit }
    private var ctrlIcon: CGFloat { ctrlHit * Tokens.Decor.ctrlIconFactor }

    /// Effective pill size = PillLayout's pure function of the current
    /// {sizeClass, minuteDigits}. The only pill-size source there is.
    private var pillSize: NSSize { layout.pillSize }

    /// Hover grows only the glass. Text and controls stay screen-stable.
    private var hoverScales: HoverScaleFactors {
        HoverScaleFactors.resolve(isHovering: isHovering, hoverScale: tuning.hoverScale)
    }
    private var hoverHitRegion: HoverHitRegion { HoverHitRegion.resolve(layout: layout) }
    private var isEditingSetup: Bool { displayState == .idle && isHovering }

    var body: some View {
        ZStack {
            Color.clear
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drive the whole-pill resize from SwiftUI (the window's own setFrame
        // is animate:false in TimerInstanceController so the two don't
        // desync). pillSize is a pure function of {sizeClass, minuteDigits},
        // so this one animation covers both S/M/L changes and digit-count
        // changes (99↔100min) — everything that can resize the pill.
        .animation(Motion.resize, value: pillSize)
    }

    private var pill: some View {
        ZStack {
            // The blur IS the glass: the pill paints no dark slab of its own.
            // The only glass body is the NSVisualEffectView living under
            // window.contentView (see TimerInstanceController) — it must stay
            // outside SwiftUI, and unclipped, or the live `.behindWindow`
            // blur freezes.
            overtimeGlow
                .scaleEffect(hoverScales.glass)
            contentStack
                .scaleEffect(hoverScales.content)
            glassHighlight
                .scaleEffect(hoverScales.glass)
        }
        .frame(width: pillSize.width, height: pillSize.height)
        // START/COMPLETE pulses still move the whole SwiftUI pill. Hover grows
        // only the glass layers above; keeping content at 1 prevents text drift.
        .scaleEffect(pulse)
        .animation(Motion.hoverPill, value: isHovering)
        .onAppear {
            // Keep the bridge consistent with forced-hover screenshots.
            hoverState.isHovering = isHovering
            phaseT = (model.phase == .shortBreak) ? 1 : 0
            draftWorkMinutes = String(model.workMinutes)
            if isHovering { focusSetupEditor() }
        }
        .onReceive(model.$startPulseToken) { _ in
            playStartPulse()
        }
        .onReceive(model.$completePulseToken) { _ in
            playCompleteBounce()
        }
        .onReceive(model.$forcePulse) { force in
            withAnimation(Motion.pulse) {
                pulse = force ? Motion.Pulse.forcedScale : 1.0
            }
        }
        .onReceive(model.$phase) { newPhase in
            withAnimation(Motion.complete) {
                phaseT = (newPhase == .shortBreak) ? 1 : 0
            }
            if newPhase == .work, isHovering {
                DispatchQueue.main.async { focusSetupEditor() }
            }
        }
        .onReceive(model.$workMinutes) { minutes in
            if setupField != .minutes { draftWorkMinutes = String(minutes) }
        }
    }

    private var overtimeGlow: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
            .fill(Color.orange.opacity(overtimeGlowOpacity))
            .shadow(color: .orange.opacity(overtimeGlowOpacity), radius: 10)
            .frame(width: glassW, height: glassH)
            .allowsHitTesting(false)
            .animation(Motion.overtime, value: model.overtimeSeconds)
    }

    /// A single specular reflection along the top edge. This is light on the
    /// existing glass, not another glass body or a full perimeter stroke.
    private var glassHighlight: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
            .strokeBorder(
                LinearGradient(
                    colors: [.clear, .white.opacity(Tokens.Decor.glassHighlightOpacity), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: Tokens.Decor.glassHighlightLineWidth
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .clear, location: Tokens.Decor.glassHighlightFadeStop),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: glassW, height: glassH)
            .allowsHitTesting(false)
    }

    private var overtimeGlowOpacity: Double {
        guard model.isOvertimeAlerting else { return 0 }
        if reduceMotion { return 0.24 }
        return model.overtimeSeconds.isMultiple(of: 2) ? 0.42 : 0.16
    }

    /// Two fixed rows, top to bottom:
    ///   row1 header: [timer icon + task name] …spacer… [Today]
    ///   row2:        [countdown mm:ss] [segmented gauge]
    private var contentStack: some View {
        VStack(spacing: layout.spacing.gapRow) {
            headerRow
                .frame(height: layout.spacing.ctrlHit)
            Group {
                if isEditingSetup {
                    durationEditor
                } else {
                    bottomRow
                }
            }
                .frame(width: layout.contentW, height: layout.row2H)
        }
        // Symmetric horizontal inset (insetH = insetOuter + gapTextTrailing)
        // — the gauge runs edge-to-edge, so the blur-edge safety margin from
        // the old trailing-only padding applies to both sides (§ decisions.4).
        .padding(.horizontal, layout.insetH)
        .padding(.vertical, layout.spacing.insetV)
        .frame(width: hoverHitRegion.size.width, height: hoverHitRegion.size.height)
        .contentShape(
            RoundedRectangle(cornerRadius: hoverHitRegion.cornerRadius, style: .circular)
        )
        .onHover(perform: handlePillHover)
        .background(setupTabBridge)
    }

    @ViewBuilder
    private var setupTabBridge: some View {
        if isEditingSetup {
            SetupTabBridge(onTab: handleSetupTab)
        }
    }

    private var taskEditor: some View {
        HStack(spacing: layout.spacing.gapInline) {
            Image(systemName: "timer")
                .frame(width: layout.headerIconW)
                .foregroundStyle(journeyBright)
            TextField("Task", text: $model.currentTask)
                .textFieldStyle(.plain)
                .focused($setupField, equals: .task)
                .onSubmit(startDraftSession)
                .accessibilityLabel("タスク名")
        }
        .font(.system(size: layout.type.header, weight: .semibold))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(editorBackground)
    }

    private var durationEditor: some View {
        return HStack(spacing: 0) {
            durationInput
            Spacer(minLength: layout.spacing.gapSection)
            controlButton(.start, symbol: "play.fill", label: "集中を開始", action: startDraftSession)
        }
    }

    private var durationInput: some View {
        let font = Font.system(size: layout.type.countdown, weight: .bold, design: .rounded)
            .monospacedDigit()
        let template = DurationEditorLayout.resolve(draft: draftWorkMinutes).minuteTemplate
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(template)
                .font(font)
                .hidden()
                .overlay(alignment: .leading) {
                    TextField("25", text: $draftWorkMinutes)
                        .textFieldStyle(.plain)
                        .font(font)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(minuteInputInvalid ? Color.red : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focused($setupField, equals: .minutes)
                        .onSubmit(startDraftSession)
                        .onChange(of: draftWorkMinutes) { _ in minuteInputInvalid = false }
                        .accessibilityLabel("集中時間、分")
                        .accessibilityHint("1分から180分までの整数。秒は0秒固定")
                }
            Text(":00")
                .font(font)
                .foregroundStyle(minuteInputInvalid ? Color.red : Color.white)
                .fixedSize()
                .accessibilityLabel("0秒")
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: ctrlHit)
        .background(editorBackground)
    }

    private var editorBackground: some View {
        RoundedRectangle(
            cornerRadius: ctrlHit * Tokens.Decor.cornerFactor,
            style: .continuous
        )
        .fill(Color.white.opacity(Tokens.Decor.editorFillOpacity))
    }

    // MARK: - Row1 header
    //
    // [timer icon + task name] …spacer(min gap.section)… [Today]

    private var headerRow: some View {
        HStack(spacing: layout.spacing.gapSection) {
            taskSlot
                .frame(maxWidth: .infinity, alignment: .leading)
            todayReadout
        }
    }

    private var taskSlot: some View {
        let offsets = TaskSlotOffsets.resolve(
            isEditing: isEditingSetup,
            distance: layout.spacing.ctrlHit,
            reduceMotion: reduceMotion
        )
        return ZStack(alignment: .leading) {
            taskChip
                .offset(y: offsets.display)
                .opacity(isEditingSetup ? 0 : 1)
                .allowsHitTesting(!isEditingSetup)
                .accessibilityHidden(isEditingSetup)
            taskEditor
                .offset(y: offsets.editor)
                .opacity(isEditingSetup ? 1 : 0)
                .allowsHitTesting(isEditingSetup)
                .accessibilityHidden(!isEditingSetup)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .animation(reduceMotion ? Motion.hover : Motion.taskSlot, value: isEditingSetup)
    }

    /// Compact task label. Editing happens inline while idle and hovering.
    private var taskChip: some View {
        HStack(spacing: layout.spacing.gapInline) {
            Image(systemName: "timer")
                .font(.system(size: layout.type.header, weight: .semibold))
                .frame(width: layout.headerIconW)
            Text(taskDisplayName)
                .font(.system(size: layout.type.header, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(journeyBright)
        .opacity(Tokens.Decor.opacityHeaderChip)
    }

    /// Today's total, just left of the control buttons — caption-sized and
    /// dimmed so it never competes with the task name or the countdown.
    private var todayReadout: some View {
        Text("Today \(model.todayStringCompact)")
            .font(.system(size: layout.type.caption, weight: .regular))
            .foregroundStyle(.white)
            .opacity(Tokens.Decor.opacityCaptionDim)
            .lineLimit(1)
            .fixedSize()
            .padding(.trailing, layout.spacing.gapInline)
    }

    /// Fallback shown when no task is set — a short, non-empty constant so
    /// row1 never renders a blank chip.
    private static let fallbackTaskLabel = "Focus"

    private var taskDisplayName: String {
        let t = model.currentTask.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? Self.fallbackTaskLabel : t
    }

    /// readout dim rule: full brightness while running/break, half while
    /// paused, slightly dimmed (not full) while idle showing the set duration.
    private var readoutOpacity: Double {
        switch displayState {
        case .running, .breakPhase: return 1.0
        case .paused:                return Tokens.Decor.opacityPausedDim
        case .idle:                  return Tokens.Decor.opacityCaption
        }
    }

    // MARK: - Row2: countdown + gauge side by side
    //
    // [countdown mm:ss (left, fixed width)] —gap.gauge— [gauge (right)],
    // vertically centered (HStack's default cross-axis alignment).
    private var bottomRow: some View {
        HStack(spacing: layout.spacing.gapGauge) {
            countdownReadout
            if isHovering, displayState != .idle {
                Spacer(minLength: layout.spacing.gapGauge)
                runtimeControls
            } else {
                segmentedBar
                    .frame(width: layout.barRowW, height: layout.segRowH)
            }
        }
    }

    private var runtimeControls: some View {
        HStack(spacing: layout.spacing.gapControls) {
            controlButton(.toggle, symbol: primaryButtonSymbol, label: primaryButtonLabel) {
                model.toggle()
            }
            controlButton(.addTime, symbol: "plus", label: "5分追加") {
                model.adjustRemaining(byMinutes: 5)
            }
            controlButton(.end, symbol: "stop.fill", label: "現在の時間を記録して終了") {
                model.endCurrentPhase()
            }
        }
    }

    /// The countdown — the pill's one "star" number. Left-aligned in its own
    /// fixed-width column so it never shifts the gauge's position as the digit
    /// count changes. Bold, `.rounded`, monospacedDigit, at `type.countdown`.
    private var countdownReadout: some View {
        let font = Font.system(size: layout.type.countdown, weight: .bold, design: .rounded)
            .monospacedDigit()
        return Text(countdownLabel)
            .font(font)
            .foregroundStyle(.white)
            .opacity(readoutOpacity)
            .frame(width: layout.countdownW, alignment: .leading)
    }

    // MARK: - Row2: the segmented glow gauge
    //
    // A row of tall-capsule segments. The left run (0..<litCount) is lit —
    // accent green, or pink on break — with a two-layer glow shadow; the right
    // run is "consumed", dim and stepping further down in opacity toward the
    // far end. An outline brackets the boundary between them. No
    // GeometryReader: every x/width comes from `PillLayout`.
    private var segmentedBar: some View {
        let segmentCount = layout.segCount
        let litCount = PillLayout.litSegmentCount(remainingRatio: model.remainingRatio,
                                                  total: segmentCount)
        let segW = layout.segWActual
        let segH = layout.seg.h
        let corner = segW * Tokens.Decor.segCornerFactor
        let dim = displayState == .paused ? Tokens.Decor.opacityPausedDim : 1.0
        let consumedCount = segmentCount - litCount

        return ZStack(alignment: .leading) {
            ForEach(0..<segmentCount, id: \.self) { i in
                if i < litCount {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(journeyBright)
                        .frame(width: segW, height: segH)
                        .shadow(color: journeyBright.opacity(Tokens.Decor.segGlowInnerOpacity),
                                radius: segW * Tokens.Decor.segGlowInnerRadiusFactor)
                        .shadow(color: journeyBright.opacity(Tokens.Decor.segGlowOuterOpacity),
                                radius: segW * Tokens.Decor.segGlowOuterRadiusFactor)
                        .opacity(dim)
                        .offset(x: layout.segmentX(i))
                } else {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(journeyDeep)
                        .opacity(PillLayout.consumedSegmentOpacity(index: i - litCount,
                                                                   consumedCount: consumedCount))
                        .frame(width: segW, height: segH)
                        .offset(x: layout.segmentX(i))
                }
            }
            // Current-position marker.
            if displayState != .paused,
               let boundary = layout.boundaryFrame(litCount: litCount, total: segmentCount) {
                let pad = Tokens.Decor.segFramePad
                RoundedRectangle(cornerRadius: corner + pad, style: .continuous)
                    .stroke(journeyRingColor.opacity(Tokens.Decor.ringOpacity),
                            lineWidth: Tokens.Decor.segFrameStroke)
                    .frame(width: boundary.width, height: segH + 2 * pad)
                    .offset(x: boundary.x)
            }
        }
        .frame(width: layout.barRowW, height: layout.segRowH, alignment: .leading)
        .animation(model.isRunning ? Motion.gauge : Motion.reset, value: litCount)
    }

    /// Lit-segment tone: work accent green (lightened) → break pink, lerped
    /// by `phaseT`.
    private var journeyBright: Color {
        lerpColor(Tokens.Decor.accentGreenBrightRGB, Tokens.Decor.breakPinkBrightRGB)
    }
    /// Consumed-segment tone: work accent green (darkened) → break pink deep.
    private var journeyDeep: Color {
        lerpColor(Tokens.Decor.accentGreenDeepRGB, Tokens.Decor.breakPinkDeepRGB)
    }
    /// The boundary marker's outline: a subtle accent-green tint during work,
    /// cross-fading to pure white on break.
    private var journeyRingColor: Color {
        lerpColor(Tokens.Decor.accentGreenRingRGB, (1, 1, 1))
    }

    private func lerpColor(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Color {
        let t = phaseT
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return Color(red: lerp(a.0, b.0), green: lerp(a.1, b.1), blue: lerp(a.2, b.2))
    }

    private static func journeyTimeLabel(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var countdownLabel: String {
        if model.isOvertime { return "+\(Self.journeyTimeLabel(model.overtimeSeconds))" }
        return Self.journeyTimeLabel(max(0, model.remaining))
    }

    // MARK: - State-driven center text

    private enum DisplayState {
        case idle
        case running
        case paused
        case breakPhase
    }

    private var displayState: DisplayState {
        // NB: POMO_PHASE only SEEDS the initial model state at launch (see
        // AppDelegate.applyForcedPhaseIfAny). displayState must derive PURELY from
        // the live model — previously it re-read the env on every render, which
        // pinned the UI to the forced phase forever, so the toggle button's icon
        // never updated (it looked stuck on the pause/stop glyph and you couldn't
        // tell the timer had paused). Derive from model state only.
        if model.phase == .shortBreak { return .breakPhase }
        if model.isRunning { return .running }
        // `isIdleForAdjust` is the model's own definition of "not started
        // yet", and it also requires zero banked elapsed time. Testing
        // `remaining == workDuration` alone was wrong: pausing at 5:00
        // elapsed and then using Extend +5 min back up to a full 25:00 made
        // the pill render as a never-started timer — undimmed, tooltip
        // offering setup — while five minutes were already banked.
        if model.isIdleForAdjust { return .idle }
        return .paused
    }

    // MARK: - Control buttons (right side)

    private enum ControlButton: Hashable {
        case start
        case toggle
        case addTime
        case end
    }

    private var primaryButtonSymbol: String {
        model.isRunning ? "pause.fill" : "play.fill"
    }

    private var primaryButtonLabel: String {
        model.isRunning ? "一時停止" : "再開"
    }

    @ViewBuilder
    private func controlButton(_ id: ControlButton,
                               symbol: String,
                               label: String,
                               action: @escaping () -> Void) -> some View {
        let hit = ctrlHit
        let isHovered = (hoveredButton == id)
        let isPressed = (pressedButton == id)
        let baseFill: Double = id == .start ? Tokens.Decor.idleToggleFill : 0.0
        ZStack {
            // Flat hover affordance — a plain opacity fill, no ring.
            Circle()
                .fill(Color.white.opacity(isHovered ? Tokens.Decor.ctrlHoverFill : baseFill))
            Image(systemName: symbol)
                .font(.system(size: ctrlIcon, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? Tokens.Decor.ctrlIconOpacityHovered
                                                          : Tokens.Decor.ctrlIconOpacityIdle))
        }
        .frame(width: hit, height: hit)
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
        .help(label)
        .scaleEffect(isPressed ? Tokens.Decor.ctrlScalePressed
                               : (isHovered ? Tokens.Decor.ctrlScaleHovered : 1.0))
        .animation(Motion.press, value: isPressed)
        .animation(Motion.hover, value: isHovered)
        .onHover { hov in
            hoveredButton = hov ? id : (hoveredButton == id ? nil : hoveredButton)
            if hov { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            // Runtime controls leave the hierarchy when hover ends. Without
            // this cleanup there is no trailing onHover(false), so the cursor
            // push would remain active over other apps.
            if hoveredButton == id {
                hoveredButton = nil
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressedButton = id }
                .onEnded { _ in
                    if pressedButton == id {
                        pressedButton = nil
                        action()
                    }
                }
        )
    }

    private func focusSetupEditor() {
        guard displayState == .idle else { return }
        if draftWorkMinutes.isEmpty { draftWorkMinutes = String(model.workMinutes) }
        selectSetupField(.task)
    }

    private func handlePillHover(_ isInside: Bool) {
        if forceHover {
            applyHoverState(true)
            return
        }
        hoverGeneration &+= 1
        let generation = hoverGeneration
        guard isInside else {
            applyHoverState(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Glass.hoverActivationDelay) {
            guard generation == hoverGeneration else { return }
            applyHoverState(true)
        }
    }

    private func applyHoverState(_ isActive: Bool) {
        guard isHovering != isActive else { return }
        isHovering = isActive
        // Mirror to this timer's AppKit glass bridge after the same delay.
        hoverState.isHovering = isActive
        if isActive { focusSetupEditor() } else { setupField = nil }
    }

    private func handleSetupTab(backward: Bool) -> Bool {
        if backward {
            guard setupField == .minutes else { return false }
            selectSetupField(.task)
        } else {
            guard setupField == .task else { return false }
            selectSetupField(.minutes)
        }
        return true
    }

    private func selectSetupField(_ field: SetupField) {
        DispatchQueue.main.async {
            setupField = field
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func startDraftSession() {
        guard let minutes = PomodoroSource.validatedMinutes(draftWorkMinutes) else {
            minuteInputInvalid = true
            setupField = .minutes
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            return
        }
        minuteInputInvalid = false
        model.workMinutes = minutes
        setupField = nil
        model.start()
    }

    // MARK: - Animations

    /// One-shot pill pulse: 1.0 → `peak` → 1.0.
    ///
    /// The generation token is the point of this helper. Without it a second
    /// pulse starting inside the first one's `hold` window gets stomped back
    /// to 1.0 by the first one's stale `asyncAfter`. Bumping the counter on
    /// entry invalidates every closure already in flight.
    private func playPulse(peak: CGFloat, animation: Animation, hold: TimeInterval) {
        pulseGeneration &+= 1
        let gen = pulseGeneration
        withAnimation(animation) { pulse = peak }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            guard gen == pulseGeneration else { return }
            withAnimation(animation) { pulse = 1.0 }
        }
    }

    private func playStartPulse() {
        playPulse(peak: Motion.Pulse.startScale,
                  animation: Motion.pulse,
                  hold: Motion.Pulse.startHold)
    }

    private func playCompleteBounce() {
        playPulse(peak: Motion.Pulse.completeScale,
                  animation: Motion.complete,
                  hold: Motion.Pulse.completeHold)
    }
}

/// SwiftUI's macOS 13 text fields do not reliably join the key-view loop in a
/// borderless `NSPanel`. Keep Tab native and local to the visible setup view.
private struct SetupTabBridge: NSViewRepresentable {
    var onTab: (Bool) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onTab: onTab) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onTab = onTab
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onTab: (Bool) -> Bool
        private var monitor: Any?

        init(onTab: @escaping (Bool) -> Bool) {
            self.onTab = onTab
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 48 else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.subtracting(.shift).isEmpty else { return event }
                return self?.onTab(flags.contains(.shift)) == true ? nil : event
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit { stop() }
    }
}
