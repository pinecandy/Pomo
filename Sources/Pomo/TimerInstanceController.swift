import AppKit
import Combine
import SwiftUI

/// Owns one timer's window: the `FloatingWindow`, the glass (VEV) under it,
/// the SwiftUI hosting view, and every subscription that keeps the three in
/// step. There is exactly one of these — see `TimerRegistry`.
@MainActor
final class TimerInstanceController {
    /// Which persisted slot this timer occupies (`pomo.timer.<index>.*`).
    /// Always 0 today; kept as a parameter because the key schema is indexed.
    let index: Int
    /// Concrete, not `any SessionSource`: the type erasure existed so a
    /// controller could hold a second timer kind, which the app no longer has.
    let source: PomodoroSource
    let window: FloatingWindow
    /// "Pin on Top" state (pomo-ten-segments-and-pin) — persisted under
    /// `pomo.timer.<index>.pinned` (default true = always-floating).
    /// true → window.level = .floating; false → .normal (can sit behind
    /// other apps).
    private(set) var isPinned: Bool

    let hoverState = PomoHoverState()
    let edge = EdgePresentation()
    private var effectView: NSVisualEffectView?
    private var hoverCancellable: AnyCancellable?
    private var idleTransitionCancellable: AnyCancellable?
    private var previousApplication: NSRunningApplication?
    private var tuningCancellables = Set<AnyCancellable>()
    private var layoutCancellables = Set<AnyCancellable>()
    private var moveObserver: NSObjectProtocol?
    /// pomo-offscreen-origin-rescue §2 — watches for monitor
    /// connect/disconnect/resolution changes while this window is live (see
    /// `rescueOnscreenIfNeeded()`). Registered in `init`, removed in `deinit`
    /// (mirrors `moveObserver`'s lifecycle).
    private var screenParamsObserver: NSObjectProtocol?

    /// A window resize smaller than this is treated as no change at all —
    /// avoids a pointless setFrame on every relayout.
    private static let resizeEpsilon: CGFloat = 1.0

    // MARK: - Onscreen-rescue policy (not design tokens — these are policy)

    /// Last-resort origin when no screen is available at all.
    private static let fallbackOrigin = NSPoint(x: 100, y: 100)
    /// Margin from the screen's visible edge for a fresh/rescued window.
    private static let screenInset: CGFloat = 24
    /// A window overlapping a screen by less than this in either dimension is
    /// treated as effectively unreachable, not merely clipped.
    private static let minOnscreenOverlap: CGFloat = 40

    var kind: TimerKind { source.kind }

    /// Bootstrap init — builds a brand-new `PomodoroSource` (restoring its
    /// persisted id) and this slot's persisted pinned state, then delegates
    /// to the designated init.
    convenience init(index: Int) {
        let restoredID = Self.loadPersistedID(index: index)
        let source = PomodoroSource(instanceIndex: index, id: restoredID)
        self.init(source: source, index: index, isPinned: Self.loadPinned(index: index))
    }

    /// Statement order below is load-bearing and must not be rearranged:
    /// the glass has to be added to the container BEFORE the hosting view, or
    /// the blur ends up painted over the content.
    init(source: PomodoroSource, index: Int, isPinned: Bool) {
        self.index = index
        self.isPinned = isPinned
        self.source = source

        let initialLayout = Self.currentLayout(
            minuteDigits: source.minuteDigits,
            sizeController: PomoSizeController.shared
        )
        self.window = Self.makeWindow(layout: initialLayout, index: index, isPinned: isPinned)

        let container = Self.makeContainer(size: initialLayout.windowSize)
        window.contentView = container

        installGlass(in: container, layout: initialLayout)
        subscribeToHover()
        subscribeToTuning()
        subscribeToLayoutInvalidation()
        subscribeToUpdateAvailability()
        installHostingView(in: container)
        wireMenuCallbacks()
        installObservers()
        restoreDockIfNeeded()

        Self.debugLogLevel(index: index, isPinned: isPinned, level: window.level)
    }

    deinit {
        if let moveObserver = moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let screenParamsObserver = screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
        }
    }

    // MARK: - Construction steps

    private static func makeWindow(layout: PillLayout, index: Int, isPinned: Bool) -> FloatingWindow {
        let size = layout.windowSize
        let origin = loadOrigin(index: index, defaultSize: size)
        let window = FloatingWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // `.behindWindow` blending only samples the desktop / underlying
        // windows if the window has no opaque backing — isOpaque = false,
        // backgroundColor = .clear and hasShadow = false are all required.
        // Any opaque backing silently degrades the live blur into a solid
        // dark slab.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Crash fix (pomo-switch-crash-fix), REQUIRED UNCONDITIONALLY —
        // regardless of whether any code path currently calls close().
        // NSWindow defaults to isReleasedWhenClosed = true, which makes AppKit
        // release the window itself on close. This controller ALSO holds a
        // strong `let window`, so on the default setting the window is
        // released twice — once by AppKit at close time, once by ARC at
        // controller deinit — a double-release that surfaces as a SIGSEGV
        // inside objc_release during deinit. As an accessory app with no Dock
        // icon, the visible symptom is just "the pill silently vanished".
        window.isReleasedWhenClosed = false
        window.level = isPinned ? .floating : .normal
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        return window
    }

    private static func makeContainer(size: NSSize) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false
        return container
    }

    /// The live `.behindWindow` blur. It lives in AppKit, directly under the
    /// window's content view and never inside SwiftUI, because a SwiftUI
    /// `clipShape` on it freezes the blur — its corners come from
    /// `CapsuleMask` instead.
    private func installGlass(in container: NSView, layout: PillLayout) {
        let pillRect = layout.centeredGlassRect(in: container.bounds)
        let effectView = NSVisualEffectView(frame: pillRect)
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = false
        effectView.appearance = NSAppearance(named: .vibrantDark)
        effectView.wantsLayer = true
        effectView.maskImage = CapsuleMask.image(size: pillRect.size)
        // Flexible margins re-split the leftover space on every resize. Docking
        // grows the window from a 64pt circle back to the pill, so those margins
        // walked the glass away from the content a little more each time.
        effectView.autoresizingMask = []
        effectView.alphaValue = TuningStore.shared.glassOpacity
        container.addSubview(effectView)
        self.effectView = effectView
    }

    private func subscribeToHover() {
        hoverCancellable = hoverState.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                if hovering {
                    self?.activateEditorIfIdle()
                } else {
                    self?.restorePreviousApplication()
                }
            }

        idleTransitionCancellable = source.$phase
            .dropFirst()
            .filter { $0 == .work }
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.hoverState.isHovering else { return }
                    self.activateEditorIfIdle()
                }
            }
    }

    private func activateEditorIfIdle() {
        guard source.isIdleForAdjust else { return }
        if previousApplication == nil {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let currentPID = NSRunningApplication.current.processIdentifier
            if frontmost?.processIdentifier != currentPID { previousApplication = frontmost }
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func restorePreviousApplication() {
        guard let application = previousApplication else { return }
        previousApplication = nil
        guard !application.isTerminated else { return }
        application.activate(options: [.activateIgnoringOtherApps])
    }

    private func subscribeToTuning() {
        TuningStore.shared.$glassOpacity
            .dropFirst()
            .sink { [weak self] op in self?.effectView?.alphaValue = op }
            .store(in: &tuningCancellables)
    }

    private func subscribeToUpdateAvailability() {
        UpdateCenter.shared.$isAvailable
            .dropFirst()
            .sink { [weak self] _ in self?.relayoutWindow() }
            .store(in: &layoutCancellables)
    }

    /// Crossing the 99↔100 minute boundary adds a digit slot and resizes the pill.
    private func subscribeToLayoutInvalidation() {
        source.minuteDigitsPublisher
            .removeDuplicates()
            .sink { [weak self] _ in self?.relayoutWindow() }
            .store(in: &layoutCancellables)
    }

    private func installHostingView(in container: NSView) {
        let contentView = PomoView(hoverState: hoverState, edge: edge).environmentObject(source)
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        container.addSubview(hosting)
    }

    private func wireMenuCallbacks() {
        window.onResetRequested = { [weak source] in source?.reset() }
        window.onResetTodayTotal = { [weak source] in source?.resetTodayTotal() }
        window.onSetWorkMinutes = { [weak source] mins in source?.workMinutes = mins }
        window.onSetBreakMinutes = { [weak source] mins in source?.breakMinutes = mins }
        window.currentWorkMinutes = { [weak source] in
            source?.workMinutes ?? PomodoroSource.defaultWorkMinutes
        }
        window.currentBreakMinutes = { [weak source] in
            source?.breakMinutes ?? PomodoroSource.defaultBreakMinutes
        }
        // pomo-p1-visibility §3: Extend/Reduce ±5min.
        window.onExtendRemaining = { [weak source] in source?.adjustRemaining(byMinutes: 5) }
        window.onReduceRemaining = { [weak source] in source?.adjustRemaining(byMinutes: -5) }
        window.canAdjustRemaining = { [weak source] in source?.isIdleForAdjust == false }
        window.onSetTask = { [weak source] text in source?.currentTask = text }
        window.currentTaskText = { [weak source] in source?.currentTask ?? "" }
        window.onRecordReview = { [weak source] text in source?.recordReview(note: text) }
        window.canRecordReview = { [weak source] in
            source?.phase == .shortBreak && source?.lastCompletedSessionID != nil
        }
        window.onTogglePin = { [weak self] in self?.togglePin() }
        window.isPinned = { [weak self] in self?.isPinned ?? true }
    }

    /// Both blocks below are `@Sendable` (NotificationCenter's signature) but
    /// both observers are registered with `queue: .main`, so the body always
    /// runs on the main actor. `MainActor.assumeIsolated` states that
    /// statically: it is synchronous, so ordering is unchanged, and it traps
    /// loudly rather than racing if the precondition were ever broken.
    /// Hopping with `Task { @MainActor in … }` instead would make these
    /// asynchronous and reorder them against the timer.
    private func installObservers() {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.handleMove()
            }
        }

        // pomo-offscreen-origin-rescue §2 — `loadOrigin` only rescues an
        // offscreen origin at construction time. If a monitor is unplugged (or
        // the resolution changes) while the window is already up, nothing else
        // re-checks its position — catch that here so the pill doesn't strand
        // itself mid-session the way a stale persisted origin would at boot.
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rescueOnscreenIfNeeded()
            }
        }
    }

    // MARK: - Window geometry

    func makeKeyAndOrderFront() {
        window.makeKeyAndOrderFront(nil)
    }

    func relayoutWindow() {
        applyWindowSize(animate: false)
    }

    /// The one place this window's origin is written to UserDefaults.
    private var adjustingFrame = false

    private func handleMove() {
        guard !adjustingFrame else { return }
        persistOrigin(window.frame.origin)
        guard let screen = window.screen ?? NSScreen.main else { return }
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        if dragging { return }
        if let side = EdgeDock.side(frame: window.frame, screen: screen.frame) {
            park(side, on: screen, animated: true)
        } else if edge.docked {
            restorePill(animated: true)
        } else {
            clampPillInside(screen)
        }
    }

    private func park(_ side: ScreenEdgeSide, on screen: NSScreen, animated: Bool = false) {
        let frame = EdgeDock.parkedFrame(
            side: side,
            anchorMidY: window.frame.midY,
            screen: screen.frame,
            visible: screen.visibleFrame
        )
        edge.side = side
        edge.docked = true
        effectView?.isHidden = true
        setFrame(frame, animated: animated)
        let defaults = UserDefaults.standard
        defaults.set(side == .left ? "left" : "right", forKey: TimerDefaultsKey.field(index, "dock"))
        defaults.set(Double(frame.midY), forKey: TimerDefaultsKey.field(index, "dockMidY"))
        persistOrigin(frame.origin)
    }

    private func restorePill(animated: Bool = false) {
        edge.docked = false
        effectView?.isHidden = false
        effectView?.alphaValue = TuningStore.shared.glassOpacity
        let layout = currentLayout()
        let size = layout.windowSize
        let mid = CGPoint(x: window.frame.midX, y: window.frame.midY)
        var rect = NSRect(x: mid.x - size.width / 2, y: mid.y - size.height / 2,
                          width: size.width, height: size.height)
        if let screen = window.screen ?? NSScreen.main {
            rect = Self.clamp(rect, into: screen.visibleFrame)
        }
        effectView?.isHidden = true
        setFrame(rect, animated: animated)
        if !animated { syncGlass() }
        UserDefaults.standard.removeObject(forKey: TimerDefaultsKey.field(index, "dock"))
        persistOrigin(rect.origin)
    }

    private func restoreDockIfNeeded() {
        let raw = UserDefaults.standard.string(forKey: TimerDefaultsKey.field(index, "dock"))
        let side: ScreenEdgeSide?
        switch raw {
        case "left": side = .left
        case "right": side = .right
        default: side = nil
        }
        guard let side, let screen = window.screen ?? NSScreen.main else { return }
        let midY = UserDefaults.standard.double(forKey: TimerDefaultsKey.field(index, "dockMidY"))
        if midY > 0 {
            let originY = midY - window.frame.height / 2
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: originY))
        }
        park(side, on: screen)
    }

    /// A release that stays inside must not leave the pill hanging off the
    /// screen. That clipped the left side after repeated drags.
    private func clampPillInside(_ screen: NSScreen) {
        let layout = currentLayout()
        let size = layout.windowSize
        var rect = NSRect(origin: window.frame.origin, size: size)
        let clamped = Self.clamp(rect, into: screen.visibleFrame)
        guard abs(clamped.origin.x - window.frame.origin.x) > 0.5
                || abs(clamped.origin.y - window.frame.origin.y) > 0.5
                || abs(window.frame.width - size.width) > 0.5 else { return }
        rect = clamped
        effectView?.isHidden = true
        setFrame(rect, animated: true)
        persistOrigin(rect.origin)
    }

    private func setFrame(_ rect: NSRect, animated: Bool) {
        adjustingFrame = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.38
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(rect, display: true, animate: true)
            } completionHandler: {
                MainActor.assumeIsolated {
                    self.adjustingFrame = false
                    self.syncGlass()
                }
            }
            return
        }
        window.setFrame(rect, display: true, animate: false)
        adjustingFrame = false
    }

    /// Place the blur from the window's real bounds. Call this only after the
    /// frame has finished changing. The SwiftUI pill centers itself in those
    /// same bounds, so the glass has to be derived from them, not from the
    /// size the window had at the start of the animation.
    private func syncGlass() {
        guard !edge.docked, let effectView, let container = window.contentView else { return }
        let layout = currentLayout()
        let rect = layout.centeredGlassRect(in: container.bounds)
        effectView.frame = rect
        effectView.maskImage = CapsuleMask.image(size: rect.size)
        effectView.alphaValue = TuningStore.shared.glassOpacity
        effectView.isHidden = false
    }

    private func persistOrigin(_ origin: NSPoint) {
        let d = UserDefaults.standard
        d.set(Double(origin.x), forKey: TimerDefaultsKey.field(index, "x"))
        d.set(Double(origin.y), forKey: TimerDefaultsKey.field(index, "y"))
    }

    /// pomo-offscreen-origin-rescue §2 — re-runs the same rescue `loadOrigin`
    /// applies at construction, but against this window's LIVE frame. No-ops
    /// when the current frame is already fine.
    private func rescueOnscreenIfNeeded() {
        let current = window.frame
        let rescued = Self.rescueOnscreenOrigin(current.origin, size: current.size)
        guard rescued != current.origin else { return }
        window.setFrameOrigin(rescued)
        persistOrigin(rescued)
    }

    /// Single source of truth for this window's frame. The top-RIGHT corner is
    /// preserved across a resize, so the pill grows leftward/downward rather
    /// than drifting.
    private func applyWindowSize(animate: Bool) {
        if edge.docked { return }
        let layout = currentLayout()
        let winSize = layout.windowSize
        let oldFrame = window.frame
        let unchanged = abs(oldFrame.width - winSize.width) < Self.resizeEpsilon
            && abs(oldFrame.height - winSize.height) < Self.resizeEpsilon
        if !animate, unchanged { return }
        let rightX = oldFrame.maxX
        let topY   = oldFrame.maxY
        var newRect = NSRect(
            x: rightX - winSize.width,
            y: topY   - winSize.height,
            width:  winSize.width,
            height: winSize.height
        )
        if let screen = window.screen ?? NSScreen.main {
            newRect = Self.clamp(newRect, into: screen.visibleFrame)
        }
        window.setFrame(newRect, display: true, animate: animate)

        if let effectView = effectView {
            let targetGlassRect = layout.centeredGlassRect(in: NSRect(origin: .zero, size: winSize))
            effectView.maskImage = CapsuleMask.image(size: targetGlassRect.size)
            if animate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Tokens.Glass.resizeDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    effectView.animator().frame = targetGlassRect
                }
            } else {
                effectView.frame = targetGlassRect
            }
        }

        persistOrigin(newRect.origin)
    }

    func currentPersistedState() -> (x: Double, y: Double, task: String, work: Int, brk: Int, pinned: Bool) {
        let origin = window.frame.origin
        return (Double(origin.x), Double(origin.y), source.currentTask, source.workMinutes, source.breakMinutes, isPinned)
    }

    // MARK: - Pin on Top

    /// Flips the pin state and applies it to the live window immediately
    /// (Cmd+P / ⚙→"Pin on Top"). Persists right away — not just at
    /// `persistStructure()` time — so the state survives a crash between
    /// toggles and the ⚙ menu's checkbox (rebuilt fresh each popup) always
    /// reads the latest value.
    func togglePin() {
        isPinned.toggle()
        applyPinned()
        UserDefaults.standard.set(isPinned, forKey: TimerDefaultsKey.field(index, "pinned"))
    }

    private func applyPinned() {
        window.level = isPinned ? .floating : .normal
        Self.debugLogLevel(index: index, isPinned: isPinned, level: window.level)
    }

    /// QA hook (POMO_DEBUG_LEVEL=1): logs the applied NSWindow.Level so the
    /// pin-persistence verification step can confirm .normal vs .floating
    /// without inspecting UI state.
    private static func debugLogLevel(index: Int, isPinned: Bool, level: NSWindow.Level) {
        guard ProcessInfo.processInfo.environment["POMO_DEBUG_LEVEL"] == "1" else { return }
        NSLog("Pomo[timer %d] pinned=%@ window.level=%d", index, isPinned ? "true" : "false", level.rawValue)
    }

    // MARK: - Persistence loaders

    private static func loadPinned(index: Int) -> Bool {
        let key = TimerDefaultsKey.field(index, "pinned")
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return true
    }

    /// Restores this slot's stable identity from `pomo.timer.<index>.id`
    /// (written by `AppDelegate.migrateToHybridSchemaIfNeeded()` on first
    /// launch after the v2 schema lands, and by
    /// `TimerRegistry.persistStructure()` on every subsequent save). Falls
    /// back to a fresh UUID when the key is missing or unparsable.
    static func loadPersistedID(index: Int) -> TimerInstanceID {
        let key = TimerDefaultsKey.field(index, "id")
        if let raw = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: raw) {
            return uuid
        }
        return UUID()
    }

    private static func loadOrigin(index: Int, defaultSize: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        let xKey = TimerDefaultsKey.field(index, "x")
        let yKey = TimerDefaultsKey.field(index, "y")
        let origin: NSPoint
        if defaults.object(forKey: xKey) != nil, defaults.object(forKey: yKey) != nil {
            origin = NSPoint(x: defaults.double(forKey: xKey), y: defaults.double(forKey: yKey))
        } else {
            origin = defaultTopRightOrigin(size: defaultSize)
        }
        // Rescue runs unconditionally (not just on the persisted-value
        // branch) — cheap, and covers the launch restore path. When `origin`
        // is already the fresh-default position on the main screen, the
        // rescue is a no-op.
        return rescueOnscreenOrigin(origin, size: defaultSize)
    }

    // MARK: - Glass geometry

    private func refreshGlassGeometry() {
        guard let effectView = effectView,
              let container = window.contentView else { return }
        let glassRect = currentLayout().centeredGlassRect(in: container.bounds)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        effectView.frame = glassRect
        effectView.maskImage = CapsuleMask.image(size: glassRect.size)
        NSAnimationContext.endGrouping()
    }

    private func currentLayout() -> PillLayout {
        Self.currentLayout(
            minuteDigits: source.minuteDigits,
            sizeController: PomoSizeController.shared
        )
    }

    private static func currentLayout(minuteDigits: Int, sizeController: PomoSizeController) -> PillLayout {
        PillLayout(sizeClass: sizeController.current,
                   minuteDigits: minuteDigits,
                   showsUpdateSlot: UpdateCenter.shared.isAvailable)
    }

    // MARK: - Onscreen rescue

    /// Same main-screen top-right default used by `loadOrigin` for a
    /// never-persisted origin AND by `rescueOnscreenOrigin` when a
    /// persisted/live origin doesn't land on any connected screen.
    private static func defaultTopRightOrigin(size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return fallbackOrigin }
        let frame = screen.visibleFrame
        return NSPoint(x: frame.maxX - size.width - screenInset,
                       y: frame.maxY - size.height - screenInset)
    }

    /// Clamps `rect` fully inside `visibleFrame` — moves the origin only
    /// (never resizes) so the whole window ends up onscreen.
    private static func clamp(_ rect: NSRect, into visibleFrame: NSRect) -> NSRect {
        var r = rect
        if r.maxX > visibleFrame.maxX { r.origin.x = visibleFrame.maxX - r.width }
        if r.minX < visibleFrame.minX { r.origin.x = visibleFrame.minX }
        if r.maxY > visibleFrame.maxY { r.origin.y = visibleFrame.maxY - r.height }
        if r.minY < visibleFrame.minY { r.origin.y = visibleFrame.minY }
        return r
    }

    /// pomo-offscreen-origin-rescue — the fix for "起動しても表示されない":
    /// a persisted `pomo.timer.<n>.{x,y}` can point at a screen that is no
    /// longer connected (external monitor unplugged, or just a stale value
    /// from long ago). Because this app's windows are `.borderless`, AppKit's
    /// usual `constrainFrameRect` onscreen guarantee never runs for them, so a
    /// raw restore silently creates an unreachable window.
    ///
    /// Picks whichever CURRENTLY CONNECTED screen the window overlaps most; if
    /// that best overlap is thinner than `minOnscreenOverlap` in either
    /// dimension (a sliver overlap is still effectively unusable), treats it
    /// as "no usable screen" and falls back to `defaultTopRightOrigin`.
    /// Otherwise clamps into that screen's `visibleFrame`.
    private static func rescueOnscreenOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let rect = NSRect(origin: origin, size: size)
        var bestScreen: NSScreen?
        var bestIntersection = NSRect.zero
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = rect.intersection(screen.visibleFrame)
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
                bestIntersection = intersection
            }
        }
        if let screen = bestScreen,
           bestIntersection.width >= minOnscreenOverlap,
           bestIntersection.height >= minOnscreenOverlap {
            return clamp(rect, into: screen.visibleFrame).origin
        }
        return defaultTopRightOrigin(size: size)
    }
}
