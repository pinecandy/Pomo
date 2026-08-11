import Foundation

// `PomodoroSource` is the only conformer. A second kind (a plain stopwatch)
// was planned and partly scaffolded, then dropped when the app reverted to a
// single pomodoro timer — see `TimerRegistry`. What survives of that work is
// the vocabulary below: `TimerKind` and the two end reasons the current app
// never emits, both retained so historical `sessions.jsonl` lines still decode.

/// Which half of the pomodoro cycle a timer is in.
enum Phase {
    case work
    case shortBreak

    /// The spelling written to sessions.jsonl. "break", not "shortBreak" —
    /// existing data on disk uses this form.
    var logName: String {
        switch self {
        case .work:       return "work"
        case .shortBreak: return "break"
        }
    }
}

enum TimerKind: String, Codable {
    case pomodoro
    /// Never produced by this app — retained so historical JSONL decodes.
    case tracker
}

typealias TimerInstanceID = UUID

enum SessionEndReason: String, Codable {
    case completed
    case paused = "pause"    // existing spelling kept for sessions.jsonl backward compat
    case reset
    /// Never emitted by the current app; retained so historical JSONL decodes.
    case stopped
    /// Never emitted by the current app; retained so historical JSONL decodes.
    case closed
    /// A standalone break-time reflection record (pomo-p2-review-capture) —
    /// NOT a work/break interval. Always paired with `seconds: 0` and a
    /// non-nil `note`; `sessionID` links it back to the work interval it
    /// reflects on. See `PomodoroSource.recordReview(note:)`.
    case note
}

@MainActor
protocol SessionSource: ObservableObject, Identifiable {
    var id: TimerInstanceID { get }
    var kind: TimerKind { get }
    var currentTask: String { get set }
    var isRunning: Bool { get }
    var displayedTodayTotalSeconds: Int { get }
    var currentSessionElapsedSeconds: Int { get }
    var startPulseToken: Int { get }
    var completePulseToken: Int { get }
    func toggle()
    func reset()
    func resetTodayTotal()
}
