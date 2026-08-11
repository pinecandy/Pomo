import XCTest

@testable import Pomo

private final class PomodoroTestClock {
    var date = Date(timeIntervalSince1970: 2_000_000_000)
}

@MainActor
final class PomodoroFlowTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    private func makeSource() -> (PomodoroSource, TodayTotalStore, SessionLog, PomodoroTestClock) {
        let defaults = InMemoryStore()
        let clock = PomodoroTestClock()
        let todayStore = TodayTotalStore(defaults: defaults, now: { clock.date })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomoFlowTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let sessionLog = SessionLog(directory: directory)
        let source = PomodoroSource(
            instanceIndex: 0,
            defaults: defaults,
            todayStore: todayStore,
            sessionLog: sessionLog,
            now: { clock.date }
        )
        return (source, todayStore, sessionLog, clock)
    }

    func test_validatedMinutes_acceptsTrimmedRangeAndRejectsNonIntegerOrOutOfRangeInput() {
        XCTAssertEqual(PomodoroSource.validatedMinutes(" 1 "), 1)
        XCTAssertEqual(PomodoroSource.validatedMinutes("180"), 180)
        XCTAssertNil(PomodoroSource.validatedMinutes(""))
        XCTAssertNil(PomodoroSource.validatedMinutes("0"))
        XCTAssertNil(PomodoroSource.validatedMinutes("181"))
        XCTAssertNil(PomodoroSource.validatedMinutes("-5"))
        XCTAssertNil(PomodoroSource.validatedMinutes("1.5"))
        XCTAssertNil(PomodoroSource.validatedMinutes("five"))
    }

    func test_tickOutcome_workCrossesDeadlineThenContinuesIntoOvertime() {
        XCTAssertEqual(PomodoroSource.tickOutcome(phase: .work, remaining: 2), .countdown(1))
        XCTAssertEqual(PomodoroSource.tickOutcome(phase: .work, remaining: 1), .workDeadline)
        XCTAssertEqual(PomodoroSource.tickOutcome(phase: .work, remaining: 0), .overtime(-1))
        XCTAssertEqual(PomodoroSource.tickOutcome(phase: .work, remaining: -7), .overtime(-8))
    }

    func test_tickOutcome_breakFinishesAtItsLowerBoundary() {
        XCTAssertEqual(
            PomodoroSource.tickOutcome(phase: .shortBreak, remaining: 2), .countdown(1)
        )
        XCTAssertEqual(
            PomodoroSource.tickOutcome(phase: .shortBreak, remaining: 1), .breakFinished
        )
        XCTAssertEqual(
            PomodoroSource.tickOutcome(phase: .shortBreak, remaining: 0), .breakFinished
        )
    }

    func test_workDeadlineKeepsRunningAndTodayGrowingDuringOvertime() {
        let (source, _, _, _) = makeSource()
        source.phase = .work
        source.remaining = 1
        source.isRunning = true

        source.advanceOneSecond()
        XCTAssertTrue(source.isRunning)
        XCTAssertEqual(source.phase, .work)
        XCTAssertEqual(source.remaining, 0)
        XCTAssertEqual(source.currentSessionElapsedSeconds, 1)
        XCTAssertTrue(source.isOvertimeAlerting)

        for _ in 0..<11 { source.advanceOneSecond() }
        XCTAssertEqual(source.remaining, -11)
        XCTAssertEqual(source.currentSessionElapsedSeconds, 12)
        XCTAssertFalse(source.isOvertimeAlerting)
    }

    func test_addFiveMinutesFromOvertimeEitherRestoresCountdownOrReducesOvertime() {
        let (source, _, _, _) = makeSource()
        source.remaining = -120
        source.adjustRemaining(byMinutes: 5)
        XCTAssertEqual(source.remaining, 180)

        source.remaining = -600
        source.adjustRemaining(byMinutes: 5)
        XCTAssertEqual(source.remaining, -300)
    }

    func test_endingRunningWorkCommitsActualTimeOnceAndImmediatelyStartsBreak() throws {
        let (source, todayStore, sessionLog, clock) = makeSource()
        source.currentTask = "UX task"
        source.start()
        source.currentSessionElapsedSeconds = 42
        source.remaining = 18
        clock.date.addTimeInterval(42)

        source.endCurrentPhase()

        XCTAssertEqual(todayStore.todaySeconds, 42)
        XCTAssertEqual(source.phase, .shortBreak)
        XCTAssertEqual(source.remaining, source.breakDuration)
        XCTAssertTrue(source.isRunning)
        sessionLog.waitForPendingWrites()
        let records = try records(in: sessionLog)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].phase, "work")
        XCTAssertEqual(records[0].reason, "stopped")
        XCTAssertEqual(records[0].seconds, 42)
        source.reset()
    }

    func test_endingPausedWorkDoesNotCommitOrLogThePausedSpanTwice() throws {
        let (source, todayStore, sessionLog, clock) = makeSource()
        source.start()
        source.currentSessionElapsedSeconds = 20
        clock.date.addTimeInterval(20)
        source.pause()

        source.endCurrentPhase()

        XCTAssertEqual(todayStore.todaySeconds, 20)
        XCTAssertEqual(source.phase, .shortBreak)
        sessionLog.waitForPendingWrites()
        let records = try records(in: sessionLog)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].reason, "pause")
        XCTAssertEqual(records[0].seconds, 20)
        source.reset()
    }

    func test_breakCompletionReturnsToWorkIdleWithoutAutoStarting() {
        let (source, _, _, _) = makeSource()
        source.phase = .shortBreak
        source.remaining = 1
        source.isRunning = true

        source.advanceOneSecond()

        XCTAssertEqual(source.phase, .work)
        XCTAssertEqual(source.remaining, source.workDuration)
        XCTAssertFalse(source.isRunning)
        XCTAssertTrue(source.isIdleForAdjust)
    }

    private func records(in sessionLog: SessionLog) throws -> [SessionRecord] {
        let fileURL = try XCTUnwrap(sessionLog.fileURL)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(SessionRecord.self, from: Data(line.utf8))
        }
    }
}
