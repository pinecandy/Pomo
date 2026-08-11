import AppKit
import Combine
import Foundation

@MainActor
final class PomodoroSource: ObservableObject, SessionSource {
    // MARK: - Identity
    //
    // `id` is this timer's stable identity across relaunches; it and the
    // per-run `sessionID` are both written into sessions.jsonl — see
    // `logSession(...)` below.
    let id: TimerInstanceID
    let kind: TimerKind = .pomodoro

    /// Which persisted "slot" this timer occupies (`pomo.timer.<index>.*`).
    let instanceIndex: Int

    // MARK: - Durations (user-configurable, in MINUTES, persisted)

    static let defaultWorkMinutes = 25
    static let defaultBreakMinutes = 5
    /// Accepted range for the ⚙ menu's "Custom…" duration. The dialog's own
    /// prompt text interpolates these, so the prose and the guard cannot
    /// disagree.
    static let minCustomMinutes = 1
    static let maxCustomMinutes = 180
    static let overtimeAlertSeconds = 10
    static let maxDisplayedOvertimeSeconds = 999 * 60 + 59

    /// User-selected work session length (minutes). Changes apply to the NEXT
    /// session — a currently running session is not interrupted.
    @Published var workMinutes: Int {
        didSet {
            defaults.set(workMinutes, forKey: workKey)
            applyDurationChangeIfIdle()
        }
    }

    /// User-selected break length (minutes). Same "next session" rule.
    @Published var breakMinutes: Int {
        didSet {
            defaults.set(breakMinutes, forKey: breakKey)
            applyDurationChangeIfIdle()
        }
    }

    var workDuration: Int  { workMinutes  * 60 }
    var breakDuration: Int { breakMinutes * 60 }

    /// "What I'm working on right now" — free text, shown above the countdown.
    /// Empty string = no task set. Persisted so it survives relaunch.
    @Published var currentTask: String {
        didSet {
            defaults.set(currentTask, forKey: taskKey)
        }
    }

    // MARK: - Runtime state

    @Published var phase: Phase = .work
    @Published var remaining: Int
    @Published var isRunning: Bool = false

    /// Live tick for the *current* running session. Reset on commit.
    @Published var currentSessionElapsedSeconds: Int = 0

    /// What the UI shows — the committed total plus this session's live
    /// in-flight elapsed, so the Today readout ticks up in real time.
    var displayedTodayTotalSeconds: Int {
        todayStore.todaySeconds + currentSessionElapsedSeconds
    }

    // Pulse triggers (UI observes)
    @Published var startPulseToken: Int = 0
    @Published var completePulseToken: Int = 0

    /// Screenshot/debug only — when true, PomoView holds the pulse scale.
    @Published var forcePulse: Bool = false

    private let defaults: KeyValueStore
    private let todayStore: TodayTotalStore
    private let sessionLog: SessionLog
    private let now: () -> Date
    private var timer: Timer?
    private var sessionStartedAt: Date?
    /// Identifies the current running span for `SessionLogger`. A fresh UUID
    /// on every `start()`, including resume-after-pause — each logged
    /// interval gets its own sessionID. A "resume" concept wanting one stable
    /// ID across pause/resume cycles would need to thread this differently.
    private var currentSessionID: UUID?

    // MARK: - Break-time review capture (pomo-p2-review-capture)

    /// The `sessionID` of the most recently ended work interval (set in
    /// `endCurrentPhase()` as that work phase commits, before `phase`
    /// flips to `.shortBreak`). This is what a review note recorded during
    /// the following break links back to — the analytical value is "what did
    /// I write about THIS specific work span", not just "sometime today".
    /// `nil` until the first work phase has ended this run.
    @Published private(set) var lastCompletedSessionID: UUID?
    /// The task label as it was during that same completed work interval —
    /// used as the review record's `task` field (the user may have already
    /// changed `currentTask` by the time they write the review).
    @Published private(set) var lastCompletedTask: String?

    /// Whether a review has already been recorded for the CURRENT break —
    /// records whether the current break already has a note. Reset to `false` every
    /// time a new break begins (`endCurrentPhase()`, work → break). Deliberately
    /// does NOT block a second click — decision: re-clicking after recording
    /// appends another independent note record rather than being a no-op, so
    /// the user can add more than one thought during a single break; the
    /// checked look only means "at least one review is on record for this
    /// break", not "locked".
    @Published private(set) var reviewRecordedForCurrentBreak: Bool = false

    // MARK: - Defaults keys (instance-scoped — see TimerDefaultsKey)

    let workKey: String
    let breakKey: String
    let taskKey: String

    /// `id` defaults to a fresh UUID (what the PNG QA harness in `main.swift`
    /// gets). `TimerInstanceController` passes an explicit `id` restored from
    /// `pomo.timer.<instanceIndex>.id` when that key already exists, so the
    /// timer's identity survives relaunch instead of changing every start.
    init(instanceIndex: Int,
         id: TimerInstanceID = UUID(),
         defaults: KeyValueStore = UserDefaults.standard,
         todayStore: TodayTotalStore? = nil,
         sessionLog: SessionLog = .shared,
         now: @escaping () -> Date = Date.init) {
        self.id = id
        self.instanceIndex = instanceIndex
        self.defaults = defaults
        self.todayStore = todayStore ?? TodayTotalStore.shared
        self.sessionLog = sessionLog
        self.now = now
        self.workKey  = TimerDefaultsKey.field(instanceIndex, "work")
        self.breakKey = TimerDefaultsKey.field(instanceIndex, "break")
        self.taskKey  = TimerDefaultsKey.field(instanceIndex, "task")

        // Load durations (with sensible defaults).
        let storedWork  = defaults.integer(forKey: workKey)
        let storedBreak = defaults.integer(forKey: breakKey)
        let work = storedWork > 0 ? storedWork : Self.defaultWorkMinutes
        self.workMinutes  = work
        self.breakMinutes = storedBreak > 0 ? storedBreak : Self.defaultBreakMinutes

        self.currentTask = defaults.string(forKey: taskKey) ?? ""

        // Initial remaining = current work duration.
        self.remaining = work * 60
    }

    var totalForPhase: Int {
        switch phase {
        case .work: return workDuration
        case .shortBreak: return breakDuration
        }
    }

    // MARK: - Digit count

    /// The largest minute value the pill may have to render.
    private static func maxMinutes(work: Int, brk: Int, remaining: Int) -> Int {
        let visibleSeconds = remaining < 0 ? min(-remaining, maxDisplayedOvertimeSeconds) : remaining
        return max(work, brk, visibleSeconds / 60)
    }

    /// How many minute digits the pill needs to render without clipping.
    /// Upper bound 3 — Custom duration is capped at `maxCustomMinutes`, so 3
    /// is always enough. The 100-minute threshold itself lives in
    /// `PillLayout.minuteDigits(forMaxMinutes:)`, the single authority, so the
    /// rendered digit count and the window sized for it cannot drift apart.
    var minuteDigits: Int {
        PillLayout.minuteDigits(
            forMaxMinutes: Self.maxMinutes(work: workMinutes, brk: breakMinutes, remaining: remaining)
        )
    }

    /// Publishes `minuteDigits` only when it actually changes (2 ↔ 3) so the
    /// window controller can relayout without reacting to every per-second
    /// tick of `remaining`.
    var minuteDigitsPublisher: AnyPublisher<Int, Never> {
        Publishers.CombineLatest3($workMinutes, $breakMinutes, $remaining)
            .map { work, brk, remaining -> Int in
                PillLayout.minuteDigits(
                    forMaxMinutes: Self.maxMinutes(work: work, brk: brk, remaining: remaining)
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Fraction of the phase still remaining (1 -> 0).
    var remainingRatio: Double {
        let total = Double(totalForPhase)
        guard total > 0 else { return 0 }
        return max(0, min(1, Double(remaining) / total))
    }

    var isOvertime: Bool { phase == .work && remaining <= 0 }

    var overtimeSeconds: Int { isOvertime ? min(-remaining, Self.maxDisplayedOvertimeSeconds) : 0 }

    var isOvertimeAlerting: Bool {
        isOvertime && overtimeSeconds <= Self.overtimeAlertSeconds
    }

    /// Compact readout — no inner space ("1h12m" / "17m"). The header renders
    /// it as "Today \(todayStringCompact)".
    ///
    /// Compact at every size class, not just Small. The spaced-out "Today 1h
    /// 12m" form measures ~60pt, which Small's column cannot fit past the
    /// 1-hour mark — it truncated to "Today 1h 1…" and silently dropped the
    /// minutes, real daily information loss at S's normal operating range.
    /// Ticks up live, since `displayedTodayTotalSeconds` includes the
    /// in-flight session.
    var todayStringCompact: String {
        let total = displayedTodayTotalSeconds
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        guard hours > 0 else { return "\(minutes)m" }
        return "\(hours)h\(minutes)m"
    }

    // MARK: - Controls

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sessionStartedAt = now()
        currentSessionID = UUID()
        startPulseToken &+= 1

        timer?.invalidate()
        // The block is @Sendable (Timer's signature) but this method is
        // @MainActor and the timer is explicitly added to RunLoop.main, so it
        // only ever fires on the main actor. `assumeIsolated` states that
        // synchronously — hopping with `Task { @MainActor in … }` instead
        // would let a tick enqueued just before a pause drain afterwards and
        // decrement `remaining` on a stopped timer.
        let ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceOneSecond() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        let startedAt = sessionStartedAt
        let interruptedPhase = phase
        // Commit the live session into the persisted total — preserving the
        // realtime "Today" value the user has been watching tick up.
        commitCurrentSession()
        logSession(phase: interruptedPhase, startedAt: startedAt, end: now(), reason: .paused)
        timer?.invalidate()
        timer = nil
        sessionStartedAt = nil
        currentSessionID = nil
    }

    func reset() {
        let wasRunning = isRunning
        let startedAt = sessionStartedAt
        let interruptedPhase = phase
        timer?.invalidate()
        timer = nil
        isRunning = false
        sessionStartedAt = nil
        // Drop the current session's live time (it was not "completed").
        // Keep the persisted today total.
        currentSessionElapsedSeconds = 0
        phase = .work
        remaining = workDuration
        // Log the interrupted run (only meaningful if it was actually ticking —
        // resetting an already-idle/paused pill has nothing new to record,
        // since pause() already logged that interval with reason "pause" —
        // logging again here would double-count the same span).
        if wasRunning {
            logSession(phase: interruptedPhase, startedAt: startedAt, end: now(), reason: .reset)
        }
        currentSessionID = nil
    }

    /// Wipes the committed today total AND this timer's in-flight session.
    func resetTodayTotal() {
        todayStore.resetToday()
        currentSessionElapsedSeconds = 0
    }

    /// ⚙ menu's "Extend +5 min" / "Reduce −5 min" (pomo-p1-visibility §3,
    /// `minutes` is +5 or -5) — adjusts the LIVE countdown while
    /// running/paused. Lower-bounds at 60s so reducing can never drive the
    /// timer below 60 seconds. Positive adjustments also work during overtime,
    /// so +5 minutes moves the timer back toward the planned window exactly.
    ///
    /// Decision (gauge integrity, task card §3): deliberately does NOT grow
    /// `totalForPhase` to keep pace when extending past it. `remainingRatio`
    /// already clamps to `min(1, remaining/total)` and `progress` already
    /// clamps to `max(0, min(1, elapsed/total))`, so `remaining > totalForPhase`
    /// never produces a negative/out-of-range ratio — `litSegmentCount` just
    /// reads a full (all-10-lit) gauge until the countdown drops back under
    /// the phase's original total, which is a legible "you've gone into
    /// extra time" reading, not a broken one. Growing `totalForPhase` instead
    /// would also permanently redefine what "one work session" means for
    /// every later phase-progress computation (streaks, session logging
    /// duration, etc.) — a much bigger blast radius than this feature needs.
    func adjustRemaining(byMinutes minutes: Int) {
        let adjusted = remaining + minutes * 60
        remaining = minutes > 0 ? adjusted : max(60, adjusted)
    }

    /// True when this phase hasn't been started yet — full duration, no
    /// in-flight elapsed, not running. The ⚙ menu's Extend/Reduce items are
    /// disabled in this state (task card §3: "idle時はdisabled — idleはDuration
    /// 設定で変えられるので"); any other state (running, or paused mid-phase)
    /// enables them.
    var isIdleForAdjust: Bool {
        !isRunning && currentSessionElapsedSeconds == 0 && remaining == totalForPhase
    }

    enum TickOutcome: Equatable {
        case countdown(Int)
        case workDeadline
        case overtime(Int)
        case breakFinished
    }

    static func tickOutcome(phase: Phase, remaining: Int) -> TickOutcome {
        if phase == .shortBreak {
            return remaining <= 1 ? .breakFinished : .countdown(remaining - 1)
        }
        if remaining > 1 { return .countdown(remaining - 1) }
        if remaining == 1 { return .workDeadline }
        return .overtime(remaining - 1)
    }

    static func validatedMinutes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let minutes = Int(trimmed) else {
            return nil
        }
        guard (minCustomMinutes...maxCustomMinutes).contains(minutes) else { return nil }
        return minutes
    }

    func advanceOneSecond() {
        guard isRunning else { return }
        let tickedPhase = phase
        let outcome = Self.tickOutcome(phase: tickedPhase, remaining: remaining)
        if tickedPhase == .work { currentSessionElapsedSeconds += 1 }
        switch outcome {
        case .countdown(let next), .overtime(let next):
            remaining = next
        case .workDeadline:
            remaining = 0
            completePulseToken &+= 1
        case .breakFinished:
            finishBreak(reason: .completed)
        }
    }

    func endCurrentPhase() {
        let endedPhase = phase
        let startedAt = sessionStartedAt
        let endedSessionID = currentSessionID
        timer?.invalidate()
        timer = nil
        isRunning = false
        if startedAt != nil {
            logSession(phase: endedPhase, startedAt: startedAt, end: now(), reason: .stopped)
        }
        if endedPhase == .work {
            lastCompletedSessionID = endedSessionID
            lastCompletedTask = currentTask
            reviewRecordedForCurrentBreak = false
            commitCurrentSession()
        }
        sessionStartedAt = nil
        currentSessionID = nil
        completePulseToken &+= 1
        if endedPhase == .work {
            phase = .shortBreak
            remaining = breakDuration
            start()
        } else {
            returnToWorkIdle()
        }
    }

    private func finishBreak(reason: SessionEndReason) {
        let startedAt = sessionStartedAt
        timer?.invalidate()
        timer = nil
        isRunning = false
        logSession(phase: .shortBreak, startedAt: startedAt, end: now(), reason: reason)
        sessionStartedAt = nil
        currentSessionID = nil
        completePulseToken &+= 1
        returnToWorkIdle()
    }

    private func returnToWorkIdle() {
        phase = .work
        remaining = workDuration
        currentSessionElapsedSeconds = 0
    }

    /// Move the live session's elapsed time into the shared committed total.
    private func commitCurrentSession() {
        guard phase == .work else {
            currentSessionElapsedSeconds = 0
            return
        }
        if currentSessionElapsedSeconds > 0 {
            todayStore.commit(seconds: currentSessionElapsedSeconds, task: currentTask)
        }
        currentSessionElapsedSeconds = 0
    }

    /// Appends a completed/interrupted running interval to the JSONL session
    /// log (see SessionLogger). `startedAt == nil` means there was nothing
    /// actively running to record (e.g. reset from an already-paused state).
    /// Intervals under `SessionLog.minimumLoggedSeconds` are dropped as
    /// noise by SessionLogger itself.
    ///
    /// `reason` is the enum, not a string: `SessionEndReason` owns the
    /// vocabulary written to disk — including the deliberate
    /// `paused = "pause"` spelling kept for backward compatibility — and a
    /// hand-typed literal is exactly what gets that wrong silently.
    ///
    /// NOTE ON CLOCKS: `seconds` here is WALL-CLOCK (end − startedAt), while
    /// `currentSessionElapsedSeconds` (which feeds the Today total) counts
    /// Timer firings. A `Timer` on RunLoop.main does not fire during system
    /// sleep, so a session spanning a one-hour sleep banks a few minutes to
    /// Today while logging ~65 minutes here. The two are deliberately
    /// different measures; nothing reconciles them.
    private func logSession(phase: Phase, startedAt: Date?, end: Date, reason: SessionEndReason) {
        guard let startedAt = startedAt else { return }
        sessionLog.append(SessionEntry(
            start: startedAt,
            end: end,
            seconds: Int(end.timeIntervalSince(startedAt).rounded()),
            phase: phase,
            task: currentTask,
            reason: reason,
            timerID: id,
            sessionID: currentSessionID,
            kind: kind
        ))
    }

    /// Appends a standalone break-time reflection record (pomo-p2-review-
    /// capture, available from the right-click menu during `.shortBreak`).
    /// Independent 1-line JSONL record, NOT a rewrite of the just-completed
    /// work interval — `sessionID` links back to it via `lastCompletedSessionID`.
    /// Empty/whitespace-only input is a silent no-op (task card: "空文字なら
    /// appendしない"). No-op if no work interval has completed yet this run
    /// (`lastCompletedSessionID == nil` — the menu item only appears during a
    /// linked break, so this is a defensive guard, not an expected path).
    func recordReview(note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let sessionID = lastCompletedSessionID else { return }
        let recordedAt = now()
        sessionLog.append(SessionEntry(
            start: recordedAt,
            end: recordedAt,
            seconds: 0,
            // Deliberately "work": the note reflects on the work interval that
            // just finished, not on the break it is written during.
            phase: .work,
            task: lastCompletedTask ?? currentTask,
            reason: .note,
            timerID: id,
            sessionID: sessionID,
            kind: kind,
            note: trimmed
        ))
        reviewRecordedForCurrentBreak = true
    }

    /// Called when the user changes work/break duration while idle:
    /// reset `remaining` to the new duration so the display matches.
    private func applyDurationChangeIfIdle() {
        guard !isRunning else { return }
        // Only update if the current phase matches the changed setting AND
        // the timer is at its old "fresh" value.
        switch phase {
        case .work:
            // Snap to the new work duration when fully idle.
            if currentSessionElapsedSeconds == 0 {
                remaining = workDuration
            }
        case .shortBreak:
            if currentSessionElapsedSeconds == 0 {
                remaining = breakDuration
            }
        }
    }
}
