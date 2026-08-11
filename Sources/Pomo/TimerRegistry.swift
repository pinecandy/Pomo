import AppKit

/// Holds the app's single window-owning controller.
///
/// This used to manage a list of timers; the multi-timer feature was reverted
/// (`pomo-single-revert`) and every add/close/setActive/reorder operation went
/// with it. The type survives as a thin shim because `AppDelegate` reaches the
/// live controller through it in two places — `applicationDidFinishLaunching`'s
/// size-change handler and `showTuningPanel`'s positioning — and a rename buys
/// nothing.
@MainActor
final class TimerRegistry {
    static let shared = TimerRegistry()

    /// The one window-owning controller. Set exactly once, at launch, by
    /// `AppDelegate.applicationDidFinishLaunching` — nothing swaps it after.
    private(set) var activeController: TimerInstanceController?

    private init() {}

    /// Compatibility passthrough for the call sites that used to iterate every
    /// live timer; there is only ever the one now.
    var instances: [TimerInstanceController] {
        activeController.map { [$0] } ?? []
    }

    /// Bootstrap-only — called exactly once from
    /// `AppDelegate.applicationDidFinishLaunching`.
    func bootstrap(_ controller: TimerInstanceController) {
        activeController = controller
    }

    /// Persists the active timer's state under the `pomo.timer.0.*` keys plus
    /// `pomo.timers.count = 1` — the same schema the multi-timer era wrote for
    /// slot 0, so a rollback to that era can still read this domain. Any
    /// `pomo.timer.1+.*` keys left over from a multi-timer install are
    /// deliberately NOT deleted (rollback insurance — task card §9).
    ///
    /// `.kind` and `.hidden` are write-only in this binary; see
    /// `AppDelegate.migrateToHybridSchemaIfNeeded`.
    func persistStructure() {
        guard let controller = activeController else { return }
        let d = UserDefaults.standard
        let state = controller.currentPersistedState()
        d.set(state.x, forKey: TimerDefaultsKey.field(0, "x"))
        d.set(state.y, forKey: TimerDefaultsKey.field(0, "y"))
        d.set(state.task, forKey: TimerDefaultsKey.field(0, "task"))
        d.set(state.work, forKey: TimerDefaultsKey.field(0, "work"))
        d.set(state.brk, forKey: TimerDefaultsKey.field(0, "break"))
        d.set(state.pinned, forKey: TimerDefaultsKey.field(0, "pinned"))
        d.set(controller.source.id.uuidString, forKey: TimerDefaultsKey.field(0, "id"))
        d.set(controller.kind.rawValue, forKey: TimerDefaultsKey.field(0, "kind"))
        d.set(false, forKey: TimerDefaultsKey.field(0, "hidden"))
        d.set(1, forKey: TimerDefaultsKey.timersCount)
    }
}
