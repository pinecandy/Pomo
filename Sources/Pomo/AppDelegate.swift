import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Passthrough onto `TimerRegistry.shared.instances`, kept as a property
    /// so the QA hooks below (`instances.first`) read naturally.
    var instances: [TimerInstanceController] { TimerRegistry.shared.instances }
    private var tuningPanel: NSWindow?

    /// Note: there is deliberately no `applicationWillTerminate`. Quitting
    /// with a session running discards that session's in-flight time without
    /// writing a JSONL record — the same behaviour the app has always had
    /// (see `PomodoroSource.commitCurrentSession`). It is a decision, not an
    /// oversight; don't "fix" it without deciding you want the change.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateLegacyKeysIfNeeded()
        Self.migrateToHybridSchemaIfNeeded()
        Self.applyForcedSizeIfAny()

        // One pomodoro timer, always slot 0.
        let controller = TimerInstanceController(index: 0)
        TimerRegistry.shared.bootstrap(controller)
        wireAppLevelMenuActions(controller)

        Self.applyForcedPhaseIfAny(model: controller.source)

        controller.makeKeyAndOrderFront()

        let env = ProcessInfo.processInfo.environment
        if env["POMO_TUNING"] == "1" {
            showTuningPanel()
        }

        PomoSizeController.shared.onChange = { _ in
            TimerRegistry.shared.instances.forEach { $0.relayoutWindow() }
        }

        if let screenshotPath = env["POMO_SCREENSHOT_TO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Self.captureWindow(controller.window, to: screenshotPath)
                NSApp.terminate(nil)
            }
        }

        TimerRegistry.shared.persistStructure()
    }

    private func wireAppLevelMenuActions(_ controller: TimerInstanceController) {
        let window = controller.window
        window.onToggleTuning = { [weak self] in
            self?.toggleTuningPanel()
        }
    }

    static func migrateLegacyKeysIfNeeded() {
        let d = UserDefaults.standard
        guard d.object(forKey: TimerDefaultsKey.timersCount) == nil else { return }
        if d.object(forKey: TimerDefaultsKey.Legacy.workMinutes) != nil {
            d.set(d.integer(forKey: TimerDefaultsKey.Legacy.workMinutes),
                  forKey: TimerDefaultsKey.field(0, "work"))
        }
        if d.object(forKey: TimerDefaultsKey.Legacy.breakMinutes) != nil {
            d.set(d.integer(forKey: TimerDefaultsKey.Legacy.breakMinutes),
                  forKey: TimerDefaultsKey.field(0, "break"))
        }
        if let t = d.string(forKey: TimerDefaultsKey.Legacy.task) {
            d.set(t, forKey: TimerDefaultsKey.field(0, "task"))
        }
        if d.object(forKey: TimerDefaultsKey.Legacy.windowX) != nil {
            d.set(d.double(forKey: TimerDefaultsKey.Legacy.windowX),
                  forKey: TimerDefaultsKey.field(0, "x"))
        }
        if d.object(forKey: TimerDefaultsKey.Legacy.windowY) != nil {
            d.set(d.double(forKey: TimerDefaultsKey.Legacy.windowY),
                  forKey: TimerDefaultsKey.field(0, "y"))
        }
        d.set(1, forKey: TimerDefaultsKey.timersCount)
    }

    /// v1 -> v2 schema hybrid migration (pomo-dock-phase2 §4). Backfills the
    /// per-slot `.id`/`.kind`/`.hidden` keys and `pomo.timers.order` without
    /// touching or removing a single v1 key. Idempotent via
    /// `pomo.schemaVersion`, which is only written at the very end so a crash
    /// mid-migration just re-runs it next launch instead of leaving a half
    /// state.
    ///
    /// WRITE-ONLY IN THIS BINARY: nothing reads `.kind`, `.hidden`,
    /// `pomo.timers.order` or `pomo.dock.sortMode` any more — the multi-timer
    /// dock they belonged to was reverted. They are still written so a
    /// pre-revert build could read this defaults domain unchanged. Don't go
    /// hunting for the consumer; there isn't one.
    static func migrateToHybridSchemaIfNeeded() {
        let d = UserDefaults.standard
        let currentVersion = d.integer(forKey: TimerDefaultsKey.schemaVersion)  // unset = 0
        guard currentVersion < 2 else { return }
        let count = max(1, d.integer(forKey: TimerDefaultsKey.timersCount))
        var order: [String] = []
        for idx in 0..<count {
            let idKey = TimerDefaultsKey.field(idx, "id")
            let kindKey = TimerDefaultsKey.field(idx, "kind")
            let hiddenKey = TimerDefaultsKey.field(idx, "hidden")
            let id = d.string(forKey: idKey) ?? UUID().uuidString
            d.set(id, forKey: idKey)
            if d.object(forKey: kindKey) == nil { d.set("pomodoro", forKey: kindKey) }
            if d.object(forKey: hiddenKey) == nil { d.set(false, forKey: hiddenKey) }
            order.append(id)
        }
        d.set(order.joined(separator: ","), forKey: TimerDefaultsKey.timersOrder)
        if d.object(forKey: TimerDefaultsKey.dockSortMode) == nil {
            d.set("manual", forKey: TimerDefaultsKey.dockSortMode)
        }
        d.set(2, forKey: TimerDefaultsKey.schemaVersion)  // write last (crash-safe retry)
    }

    // MARK: - QA hooks (POMO_* environment variables)

    static func applyForcedSizeIfAny() {
        guard let raw = ProcessInfo.processInfo.environment["POMO_SIZE"]?.lowercased(),
              let size = PomoSize(rawValue: raw) else { return }
        PomoSizeController.shared.set(size)
    }

    static func applyForcedPhaseIfAny(model: PomodoroSource) {
        let env = ProcessInfo.processInfo.environment
        if let phase = env["POMO_PHASE"]?.lowercased() {
            switch phase {
            case "idle":
                model.phase = .work
                model.remaining = model.workDuration
                model.isRunning = false
                TodayTotalStore.shared.forceSet(0)
            case "running":
                model.phase = .work
                model.remaining = model.workDuration - (8 * 60)
                TodayTotalStore.shared.forceSet(4320)
                model.isRunning = true
            case "paused":
                model.phase = .work
                model.remaining = model.workDuration - (8 * 60)
                TodayTotalStore.shared.forceSet(4320)
                model.isRunning = false
            case "break":
                model.phase = .shortBreak
                model.remaining = model.breakDuration - 90
                TodayTotalStore.shared.forceSet(5400)
                model.isRunning = true
            case "overtime":
                model.phase = .work
                model.remaining = -8
                model.currentSessionElapsedSeconds = model.workDuration + 8
                TodayTotalStore.shared.forceSet(0)
                model.isRunning = true
            default:
                break
            }
        }
        if let taskText = env["POMO_TASK"] {
            model.currentTask = taskText
        }
        if let rawRemaining = env["POMO_REMAINING_SECONDS"],
           let secs = Int(rawRemaining) {
            model.remaining = max(-PomodoroSource.maxDisplayedOvertimeSeconds,
                                  min(secs, model.totalForPhase))
        }
        if let rawElapsed = env["POMO_SESSION_ELAPSED"],
           let secs = Int(rawElapsed) {
            TodayTotalStore.shared.forceSet(0)
            model.currentSessionElapsedSeconds = max(0, secs)
        }
        if env["POMO_PULSE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.forcePulse = true
            }
        }
    }

    /// POMO_SCREENSHOT_TO — captures the live window (unlike POMO_RENDER_PNG,
    /// which renders offscreen). Failures are NSLogged, not printed: the app
    /// runs `.accessory` and is normally launched from Finder, where stdout
    /// goes nowhere.
    static func captureWindow(_ window: NSWindow, to path: String) {
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            NSLog("Pomo: CGWindowListCreateImage failed")
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            NSLog("Pomo: PNG representation failed")
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            NSLog("Pomo: wrote screenshot to %@", path)
        } catch {
            NSLog("Pomo: failed to write screenshot — %@", String(describing: error))
        }
    }

    // MARK: - Tuning panel (⌘T)

    private func toggleTuningPanel() {
        if let panel = tuningPanel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            showTuningPanel()
        }
    }

    private func showTuningPanel() {
        if let panel = tuningPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let size = Tokens.Panel.tuningSize
        let hosting = NSHostingView(rootView: TuningPanelView())
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pomo Tuning"
        panel.level = .floating
        // Same double-release guard as FloatingWindow — this controller holds
        // the only strong reference, so AppKit must not release it on close.
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        if let main = instances.first?.window {
            // Park it just off the pill's leading edge, top-aligned.
            let f = main.frame
            panel.setFrameOrigin(NSPoint(x: f.minX - size.width - Tokens.Panel.tuningGutter,
                                         y: f.maxY - size.height))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        tuningPanel = panel
    }
}
