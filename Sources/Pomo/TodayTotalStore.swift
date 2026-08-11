import Combine
import Foundation

/// The three key-value operations `TodayTotalStore` actually needs.
///
/// Narrow on purpose. Depending on the whole of `UserDefaults` forced tests to
/// create a real `UserDefaults(suiteName:)`, and `removePersistentDomain`
/// empties a suite without deleting its backing plist — so every run left a
/// file per test in ~/Library/Preferences, permanently. A protocol this small
/// lets a test pass a dictionary instead and touch no filesystem at all.
///
/// `UserDefaults` already declares these exact signatures, so its conformance
/// is empty.
protocol KeyValueStore: AnyObject {
    func integer(forKey defaultName: String) -> Int
    func string(forKey defaultName: String) -> String?
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: KeyValueStore {}

/// Owns "how much work time has been committed today" — the persistence and
/// the day-rollover check for it.
///
/// A singleton in the app, but the initializer takes its defaults store and
/// its clock so a test can drive a day rollover without waiting for midnight
/// or touching the real domain.
@MainActor
final class TodayTotalStore: ObservableObject {
    static let shared = TodayTotalStore()

    /// Committed total for today, in seconds. Does NOT include the timer's
    /// live in-flight session — `PomodoroSource.displayedTodayTotalSeconds`
    /// adds that on top so the pill's Today readout ticks up in real time.
    @Published private(set) var todaySeconds: Int

    /// Per-task committed seconds for today, keyed by trimmed task name,
    /// persisted under `pomo.today.byTask.<date>` as a JSON `[String: Int]`
    /// blob. WRITE-ONLY: nothing in the app reads this back — the per-task UI
    /// it was built for was never shipped. It is kept because the same
    /// information is only otherwise recoverable by parsing sessions.jsonl,
    /// and dropping the writes would change what lands on disk.
    private var perTaskSeconds: [String: Int]

    private let defaults: KeyValueStore
    private let now: () -> Date

    /// The `pomo.today.<date>` key this instance was last loaded/saved
    /// against — used to detect a day rollover.
    private var loadedKey: String

    /// Same rollover guard for the per-task blob. Kept separate so the two
    /// reload paths stay uncoupled, though in practice they always match.
    private var perTaskLoadedKey: String

    init(defaults: KeyValueStore = UserDefaults.standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now

        let key = Self.todayKey(at: now())
        self.loadedKey = key
        self.todaySeconds = defaults.integer(forKey: key)

        let taskKey = Self.todayByTaskKey(at: now())
        self.perTaskLoadedKey = taskKey
        self.perTaskSeconds = Self.loadPerTask(key: taskKey, from: defaults)
    }

    // MARK: - Key derivation (pure)

    /// The `yyyy-MM-dd` stamp the day's keys are built from.
    ///
    /// `en_US_POSIX` is required, not cosmetic: with the device locale, a user
    /// on the Japanese calendar gets "0008-08-01" instead of "2026-08-01", so
    /// every day's total would land under a key nothing ever reads again.
    /// Verified to produce a byte-identical stamp under the current locale
    /// (ja_JP, Gregorian), so no existing key is orphaned by pinning it.
    static func dateStamp(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func todayKey(at date: Date) -> String { "pomo.today.\(dateStamp(at: date))" }
    static func todayByTaskKey(at date: Date) -> String {
        "pomo.today.byTask.\(dateStamp(at: date))"
    }

    /// Whether a task name earns its own per-task entry.
    static func tracksPerTask(task: String, seconds: Int) -> Bool {
        !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && seconds >= SessionLog.minimumLoggedSeconds
    }

    // MARK: - Storage

    private static func loadPerTask(key: String, from defaults: KeyValueStore) -> [String: Int] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Naive day-rollover guard: re-derive the key, reload if it changed.
    /// Deliberately not hardened further (multi-timer spec decision 6).
    private func reloadIfDayChanged() {
        let key = Self.todayKey(at: now())
        if key != loadedKey {
            loadedKey = key
            todaySeconds = defaults.integer(forKey: key)
        }
        let taskKey = Self.todayByTaskKey(at: now())
        if taskKey != perTaskLoadedKey {
            perTaskLoadedKey = taskKey
            perTaskSeconds = Self.loadPerTask(key: taskKey, from: defaults)
        }
    }

    /// The one read-modify-write point `PomodoroSource.commitCurrentSession()`
    /// goes through.
    func commit(seconds: Int, task: String) {
        guard seconds > 0 else { return }
        reloadIfDayChanged()
        discardForcedValueIfNeeded()
        todaySeconds += seconds
        save()
        if Self.tracksPerTask(task: task, seconds: seconds) {
            let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
            perTaskSeconds[trimmed, default: 0] += seconds
            savePerTask()
        }
    }

    /// Wipes today's committed total ("Reset Today Total"). Does NOT touch
    /// `perTaskSeconds`.
    func resetToday() {
        reloadIfDayChanged()
        discardForcedValueIfNeeded()
        todaySeconds = 0
        save()
    }

    /// QA-only: force the in-memory committed total to an exact value for a
    /// screenshot (POMO_PHASE / POMO_RENDER_PNG). Deliberately does NOT
    /// persist, so QA runs never pollute the real `pomo.today.<date>` value.
    func forceSet(_ seconds: Int) {
        todaySeconds = seconds
        isForced = true
    }

    /// True while `todaySeconds` holds a QA-forced value rather than the
    /// stored one. Without this a `commit()` after a `forceSet()` would
    /// accumulate on top of the fake number and persist the sum — the fake
    /// would escape into the user's real total. No production path does both
    /// today; this makes it safe if one ever does.
    private var isForced = false

    private func discardForcedValueIfNeeded() {
        guard isForced else { return }
        todaySeconds = defaults.integer(forKey: loadedKey)
        isForced = false
    }

    /// Test seam: today's per-task totals as currently held.
    var perTaskSecondsSnapshot: [String: Int] { perTaskSeconds }

    /// Writes go to the key `reloadIfDayChanged()` just settled on, NOT to a
    /// freshly re-derived one. Re-deriving called `now()` a second time, so a
    /// clock crossing midnight between the read and the write would add the
    /// seconds to today's in-memory total but file them under tomorrow's key,
    /// inflating tomorrow by today's entire accumulated total.
    private func save() {
        defaults.set(todaySeconds, forKey: loadedKey)
    }

    private func savePerTask() {
        guard let data = try? JSONEncoder().encode(perTaskSeconds) else { return }
        defaults.set(data, forKey: perTaskLoadedKey)
    }
}
