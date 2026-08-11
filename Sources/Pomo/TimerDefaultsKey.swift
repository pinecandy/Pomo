import Foundation

/// The persisted-key schema for a timer slot, in one place.
///
/// These strings were previously hand-interpolated at ~20 sites across five
/// files in three different spellings (literal, interpolated, and
/// prefix-concatenated). A typo in any one of them is silent data loss with no
/// compile error — the read simply misses and the user gets a default.
///
/// The produced strings are unchanged from that hand-written form, so an
/// existing UserDefaults domain keeps working untouched.
enum TimerDefaultsKey {
    /// `pomo.timer.<index>.<name>` — one field of one timer slot.
    static func field(_ index: Int, _ name: String) -> String {
        "pomo.timer.\(index).\(name)"
    }

    static let timersCount   = "pomo.timers.count"
    static let timersOrder   = "pomo.timers.order"
    static let schemaVersion = "pomo.schemaVersion"
    static let dockSortMode  = "pomo.dock.sortMode"

    // Pre-multi-timer flat keys, migrated into slot 0 on first launch and
    // deliberately never deleted (decision 6).
    enum Legacy {
        static let workMinutes  = "pomo.duration.work.minutes"
        static let breakMinutes = "pomo.duration.break.minutes"
        static let task         = "pomo.task.current"
        static let windowX      = "pomo.window.x"
        static let windowY      = "pomo.window.y"
    }
}
