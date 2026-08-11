import XCTest
@testable import Pomo

/// Tests for `SessionLog`: the pure decisions (`shouldLog` / `record(for:)` /
/// `line(for:)`), the backward-compatibility contract with `sessions.jsonl`
/// lines already on disk, and the real append path.
///
/// SAFETY: every instance under test is built with an explicit temp
/// `directory:`. `SessionLog.shared` — which points at the user's real
/// `~/Library/Application Support/Pomo/sessions.jsonl` — is never appended to,
/// and `test_temporaryDirectory_isNeverInsideTheUsersRealApplicationSupportDirectory`
/// asserts that invariant rather than assuming it.
final class SessionLogTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed instant, so nothing here depends on wall-clock time.
    private static let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)
    /// 11111111-2222-3333-4444-555555555555, built from bytes because the
    /// repo forbids force-unwrapping `UUID(uuidString:)`. The spelling is
    /// pinned by `test_fixtureUUIDs_haveTheExpectedStringForm`.
    private static let fixedTimerID = UUID(uuid: (
        0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33,
        0x44, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55
    ))
    /// AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.
    private static let fixedSessionID = UUID(uuid: (
        0xAA, 0xAA, 0xAA, 0xAA, 0xBB, 0xBB, 0xCC, 0xCC,
        0xDD, 0xDD, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
    ))

    /// Unique per test instance; nothing creates it until a test needs it to
    /// exist on disk.
    private var tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PomoTests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomoTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    /// A normal work-or-break interval. `end` defaults to `start + seconds`.
    private func interval(
        seconds: Int,
        phase: Phase = .work,
        reason: SessionEndReason = .completed,
        task: String = "deep work",
        start: Date = SessionLogTests.fixedStart,
        end: Date? = nil
    ) -> SessionEntry {
        SessionEntry(
            start: start,
            end: end ?? start.addingTimeInterval(TimeInterval(seconds)),
            seconds: seconds,
            phase: phase,
            task: task,
            reason: reason,
            timerID: SessionLogTests.fixedTimerID,
            sessionID: SessionLogTests.fixedSessionID,
            kind: .pomodoro,
            note: nil
        )
    }

    /// An interval whose `kind` differs from the default fixture.
    private func interval(seconds: Int, kind: TimerKind) -> SessionEntry {
        SessionEntry(
            start: SessionLogTests.fixedStart,
            end: SessionLogTests.fixedStart.addingTimeInterval(TimeInterval(seconds)),
            seconds: seconds,
            phase: .work,
            task: "deep work",
            reason: .completed,
            timerID: SessionLogTests.fixedTimerID,
            sessionID: SessionLogTests.fixedSessionID,
            kind: kind,
            note: nil
        )
    }

    /// An interval whose `sessionID` differs from the default fixture —
    /// notably `nil`, for a timer that has not completed a session yet.
    private func interval(seconds: Int, sessionID: TimerInstanceID?) -> SessionEntry {
        SessionEntry(
            start: SessionLogTests.fixedStart,
            end: SessionLogTests.fixedStart.addingTimeInterval(TimeInterval(seconds)),
            seconds: seconds,
            phase: .work,
            task: "deep work",
            reason: .completed,
            timerID: SessionLogTests.fixedTimerID,
            sessionID: sessionID,
            kind: .pomodoro,
            note: nil
        )
    }

    /// A `.note` record: a moment rather than a duration, so `seconds` is 0
    /// and `start == end`.
    private func noteRecord(
        note: String?,
        seconds: Int = 0,
        task: String = "deep work"
    ) -> SessionEntry {
        SessionEntry(
            start: SessionLogTests.fixedStart,
            end: SessionLogTests.fixedStart,
            seconds: seconds,
            phase: .work,
            task: task,
            reason: .note,
            timerID: SessionLogTests.fixedTimerID,
            sessionID: SessionLogTests.fixedSessionID,
            kind: .pomodoro,
            note: note
        )
    }

    /// Decodes the newline-terminated payload `line(for:)` produces.
    private func decodeRecord(from lineData: Data) throws -> SessionRecord {
        try JSONDecoder().decode(SessionRecord.self, from: lineData)
    }

    /// The raw JSON object a line serializes to, so absent-vs-present keys and
    /// JSON *types* can be inspected without going through `SessionRecord`'s
    /// own decoding (which would paper over a number written as a string).
    private func jsonObject(from lineData: Data) throws -> [String: Any] {
        let body = lineData.dropLast(lineData.last == UInt8(ascii: "\n") ? 1 : 0)
        let object = try JSONSerialization.jsonObject(with: Data(body))
        return try XCTUnwrap(object as? [String: Any], "a session line must be a JSON object")
    }

    /// Every complete line in the log file, with the terminator removed.
    /// Fails if the file does not end in a newline (i.e. a torn last line).
    private func readLines(
        at fileURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let pieces = contents.components(separatedBy: "\n")
        XCTAssertEqual(pieces.last, "",
                       "sessions.jsonl must end with a newline, never a partial line",
                       file: file, line: line)
        return Array(pieces.dropLast())
    }

    private func decodeAll(_ lines: [String]) throws -> [SessionRecord] {
        try lines.map { try JSONDecoder().decode(SessionRecord.self, from: Data($0.utf8)) }
    }

    func test_fixtureUUIDs_haveTheExpectedStringForm() {
        XCTAssertEqual(Self.fixedTimerID.uuidString, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(Self.fixedSessionID.uuidString, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    // MARK: - shouldLog: boundary, off-by-one, min, max

    func test_shouldLog_intervalOfZeroSecondsWithNoNote_isDroppedAsNoise() {
        XCTAssertFalse(SessionLog.shouldLog(interval(seconds: 0)))
    }

    func test_shouldLog_intervalOneSecondBelowTheNoiseFloorWithNoNote_isDropped() {
        XCTAssertEqual(SessionLog.minimumLoggedSeconds, 5,
                       "the noise floor these boundary cases are pinned to")
        XCTAssertFalse(SessionLog.shouldLog(interval(seconds: 4)))
    }

    func test_shouldLog_intervalExactlyAtTheNoiseFloorWithNoNote_isLogged() {
        // The off-by-one that matters: `>=`, not `>`. 5 seconds must survive.
        XCTAssertTrue(SessionLog.shouldLog(interval(seconds: 5)))
    }

    func test_shouldLog_intervalOneSecondAboveTheNoiseFloorWithNoNote_isLogged() {
        XCTAssertTrue(SessionLog.shouldLog(interval(seconds: 6)))
    }

    func test_shouldLog_negativeSecondsWithNoNote_isDropped() {
        XCTAssertFalse(SessionLog.shouldLog(interval(seconds: -1, end: Self.fixedStart)))
        XCTAssertFalse(SessionLog.shouldLog(interval(seconds: Int.min, end: Self.fixedStart)))
    }

    func test_shouldLog_implausiblyLongIntervalWithNoNote_isStillLogged() {
        XCTAssertTrue(SessionLog.shouldLog(interval(seconds: Int.max, end: Self.fixedStart)))
    }

    func test_shouldLog_noteRecordAtAnyDuration_isAlwaysLoggedBecauseANoteIsAMomentNotADuration() {
        for seconds in [0, 4, 5, 6] {
            XCTAssertTrue(
                SessionLog.shouldLog(noteRecord(note: "felt focused", seconds: seconds)),
                "a note record with seconds == \(seconds) must bypass the 5s noise floor"
            )
        }
    }

    func test_shouldLog_noteRecordWithNegativeSeconds_isStillLogged() {
        XCTAssertTrue(SessionLog.shouldLog(noteRecord(note: "n", seconds: -3)))
    }

    func test_shouldLog_emptyStringNote_isLoggedBecausePresenceNotEmptinessIsTheRule() {
        // Emptiness is the *caller's* guard (`PomodoroSource.recordReview`
        // trims and bails); `shouldLog` keys off nil-ness only.
        XCTAssertTrue(SessionLog.shouldLog(noteRecord(note: "")))
    }

    func test_shouldLog_entryWithNoteReasonButNoNote_fallsBackToTheNoiseFloorBecauseTheBypassKeysOnTheNoteNotTheReason() {
        // Combined-edge / corner case: `reason == .note` is *not* what opens
        // the bypass — a non-nil `note` is. A malformed pairing (the reason
        // without the note) must therefore be judged as an ordinary interval,
        // and a 0-second one is noise.
        XCTAssertFalse(SessionLog.shouldLog(noteRecord(note: nil, seconds: 0)))
        XCTAssertFalse(SessionLog.shouldLog(noteRecord(note: nil, seconds: 4)))
        XCTAssertNil(SessionLog.line(for: noteRecord(note: nil, seconds: 0)))
        XCTAssertTrue(SessionLog.shouldLog(noteRecord(note: nil, seconds: 5)))
    }

    // MARK: - record(for:): field by field

    func test_record_forACompletedWorkInterval_copiesEverySourceFieldOntoTheSerializedShape() throws {
        let start = Self.fixedStart
        let end = start.addingTimeInterval(1500)
        let record = SessionLog.record(
            for: interval(seconds: 1500, task: "write tests", start: start, end: end)
        )

        XCTAssertEqual(record.seconds, 1500)
        XCTAssertEqual(record.task, "write tests")
        XCTAssertEqual(record.phase, "work")
        XCTAssertEqual(record.reason, "completed")
        XCTAssertEqual(record.kind, "pomodoro")
        XCTAssertEqual(record.timerID, Self.fixedTimerID.uuidString)
        XCTAssertEqual(record.sessionID, Self.fixedSessionID.uuidString)
        XCTAssertEqual(record.schemaVersion, 2)
        XCTAssertNil(record.note, "a normal work interval carries no note")
        try assertLocalISO8601(record.start, denotes: start)
        try assertLocalISO8601(record.end, denotes: end)
    }

    func test_record_forShortBreakPhase_serializesAsBreakAndNeverAsShortBreak() {
        // Regression / backward compatibility: the on-disk vocabulary is
        // "work" and "break". The Swift case is `shortBreak`, and letting the
        // case name leak into the file would silently fork the data format.
        let record = SessionLog.record(for: interval(seconds: 300, phase: .shortBreak))
        XCTAssertEqual(record.phase, "break")
        XCTAssertNotEqual(record.phase, "shortBreak")
    }

    func test_record_forWorkPhase_serializesAsWork() {
        XCTAssertEqual(SessionLog.record(for: interval(seconds: 60, phase: .work)).phase, "work")
    }

    func test_record_forBothPhases_usesOnlyTheTwoLogNamesTheReadersKnow() {
        let names = [Phase.work, Phase.shortBreak].map {
            SessionLog.record(for: interval(seconds: 60, phase: $0)).phase
        }
        XCTAssertEqual(names, ["work", "break"])
    }

    func test_record_forPausedEndReason_serializesAsPause_backwardCompatibilityWithSessionsJsonlOnDisk() {
        // `SessionEndReason.paused` has rawValue "pause" — deliberately not
        // "paused". Lines written by earlier builds already use that spelling,
        // so anything reading the log filters on "pause". Changing it would
        // throw nowhere; it would just make old and new records disagree.
        let record = SessionLog.record(for: interval(seconds: 900, reason: .paused))
        XCTAssertEqual(record.reason, "pause")
        XCTAssertNotEqual(record.reason, "paused")
    }

    func test_record_forEveryEndReason_serializesTheLiteralSpellingTheLogReadersFilterOn() {
        let expected: [(SessionEndReason, String)] = [
            (.completed, "completed"),
            (.paused, "pause"),
            (.reset, "reset"),
            (.stopped, "stopped"),
            (.closed, "closed"),
            (.note, "note")
        ]
        for (reason, spelling) in expected {
            let record = SessionLog.record(for: interval(seconds: 60, reason: reason))
            XCTAssertEqual(record.reason, spelling, "\(reason) must serialize as \"\(spelling)\"")
        }
    }

    func test_record_forEveryTimerKind_serializesTheRawValue() {
        XCTAssertEqual(SessionLog.record(for: interval(seconds: 60, kind: .pomodoro)).kind,
                       "pomodoro")
        XCTAssertEqual(SessionLog.record(for: interval(seconds: 60, kind: .tracker)).kind,
                       "tracker")
    }

    func test_record_forAnyEntry_stampsTheCurrentSchemaVersion() {
        XCTAssertEqual(SessionLog.schemaVersion, 2, "records this binary writes are v2")
        XCTAssertEqual(SessionLog.record(for: interval(seconds: 60)).schemaVersion, 2)
        XCTAssertEqual(SessionLog.record(for: noteRecord(note: "n")).schemaVersion, 2)
    }

    func test_record_withNilSessionID_producesANilFieldAndNeverAStringifiedOptional() throws {
        let entry = interval(seconds: 60, sessionID: nil)
        XCTAssertNil(SessionLog.record(for: entry).sessionID)

        // The silent failure guarded against: interpolating an Optional would
        // put "nil" / "Optional(...)" on disk, and a nil-check on the domain
        // object alone would still pass.
        let lineData = try XCTUnwrap(SessionLog.line(for: entry))
        let json = try jsonObject(from: lineData)
        XCTAssertNil(json["sessionID"] as? String,
                     "sessionID must not serialize as any string when the entry has none")
        let text = try XCTUnwrap(String(data: lineData, encoding: .utf8))
        XCTAssertFalse(text.contains("Optional("),
                       "a stringified Optional must never reach the file: \(text)")
        XCTAssertNil(try decodeRecord(from: lineData).sessionID)
        // timerID is non-optional and must still be there — proves the nil
        // above is about sessionID, not about IDs generally going missing.
        XCTAssertEqual(json["timerID"] as? String, Self.fixedTimerID.uuidString)
    }

    func test_record_withSessionID_serializesTheUUIDStringExactly() {
        let record = SessionLog.record(for: interval(seconds: 60))
        XCTAssertEqual(record.sessionID, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(record.timerID, "11111111-2222-3333-4444-555555555555")
    }

    func test_record_forANoteEntry_carriesTheNoteZeroSecondsAndTheNoteReason() {
        let record = SessionLog.record(
            for: noteRecord(note: "shipped the parser", task: "write tests")
        )
        XCTAssertEqual(record.note, "shipped the parser")
        XCTAssertEqual(record.seconds, 0)
        XCTAssertEqual(record.reason, "note")
        XCTAssertEqual(record.task, "write tests")
    }

    func test_record_withEmptyTask_keepsTheEmptyStringRatherThanSubstitutingAPlaceholder() {
        XCTAssertEqual(SessionLog.record(for: interval(seconds: 60, task: "")).task, "")
    }

    func test_record_withMultiByteTask_preservesEveryCharacterRatherThanTruncatingByByteCount() throws {
        let task = "日本語のタスク 🍅🍅 café"
        let lineData = try XCTUnwrap(SessionLog.line(for: interval(seconds: 60, task: task)))
        XCTAssertEqual(try decodeRecord(from: lineData).task, task)
    }

    // MARK: - record(for:): timestamps (timezone / DST)

    private func pad(_ value: Int, to width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    /// Parses the offset half of an ISO 8601 timestamp: "Z" or "+09:00".
    /// Returns nil for anything else, so a malformed tail fails the assertion
    /// rather than silently comparing equal.
    private func offsetSeconds(inSuffix suffix: String) -> Int? {
        if suffix == "Z" { return 0 }
        let sign: Int
        switch suffix.first {
        case "+": sign = 1
        case "-": sign = -1
        default:  return nil
        }
        let parts = suffix.dropFirst().split(separator: ":")
        guard parts.count == 2,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]) else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// `start`/`end` must be local-wall-clock ISO 8601 with a real offset: the
    /// digits are what the user's clock said, and the offset is the one the
    /// local zone actually had *on that date*. A wrong offset is the classic
    /// silent failure — the string still parses, it just points at a different
    /// hour. Nothing here hardcodes a zone, so it is correct on any machine.
    private func assertLocalISO8601(
        _ string: String,
        denotes date: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let parsed = try XCTUnwrap(parser.date(from: string),
                                   "\"\(string)\" is not an internet date-time",
                                   file: file, line: line)
        XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.5,
                       "\"\(string)\" must denote the same instant as the entry",
                       file: file, line: line)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: date)
        let expectedPrefix = try [
            pad(XCTUnwrap(parts.year, file: file, line: line), to: 4),
            "-", pad(XCTUnwrap(parts.month, file: file, line: line), to: 2),
            "-", pad(XCTUnwrap(parts.day, file: file, line: line), to: 2),
            "T", pad(XCTUnwrap(parts.hour, file: file, line: line), to: 2),
            ":", pad(XCTUnwrap(parts.minute, file: file, line: line), to: 2),
            ":", pad(XCTUnwrap(parts.second, file: file, line: line), to: 2)
        ].joined()
        XCTAssertTrue(string.hasPrefix(expectedPrefix),
                      "expected local wall clock \(expectedPrefix), got \(string)",
                      file: file, line: line)
        XCTAssertEqual(offsetSeconds(inSuffix: String(string.dropFirst(expectedPrefix.count))),
                       TimeZone.current.secondsFromGMT(for: date),
                       "\"\(string)\" must carry the offset the local zone had on that date",
                       file: file, line: line)
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return try XCTUnwrap(calendar.date(from: components))
    }

    func test_record_startAndEnd_areLocalISO8601StringsDenotingTheEntrysOwnInstants() throws {
        let start = Self.fixedStart
        let end = start.addingTimeInterval(1500)
        let record = SessionLog.record(for: interval(seconds: 1500, start: start, end: end))
        try assertLocalISO8601(record.start, denotes: start)
        try assertLocalISO8601(record.end, denotes: end)
        XCTAssertNotEqual(record.start, record.end,
                          "a 25-minute interval must not stamp the same string twice")
    }

    func test_record_forDatesInJanuaryAndJuly_stampsTheOffsetTheLocalZoneActuallyHadOnEachDate() throws {
        // The formatter holds ONE TimeZone for the whole process, so it must
        // still resolve the right offset per date. `assertLocalISO8601`
        // compares against `TimeZone.current.secondsFromGMT(for: date)`, which
        // is DST-aware, so a formatter pinned to a fixed offset or to UTC goes
        // red here on any machine whose zone is not UTC. The extra check below
        // only fires where the two dates genuinely straddle a DST change.
        let winter = try utcDate(year: 2024, month: 1, day: 15, hour: 12)
        let summer = try utcDate(year: 2024, month: 7, day: 15, hour: 12)
        let winterString = SessionLog.record(
            for: interval(seconds: 60, start: winter, end: winter.addingTimeInterval(60))
        ).start
        let summerString = SessionLog.record(
            for: interval(seconds: 60, start: summer, end: summer.addingTimeInterval(60))
        ).start
        try assertLocalISO8601(winterString, denotes: winter)
        try assertLocalISO8601(summerString, denotes: summer)

        if TimeZone.current.secondsFromGMT(for: winter)
            != TimeZone.current.secondsFromGMT(for: summer) {
            XCTAssertNotEqual(String(winterString.suffix(6)), String(summerString.suffix(6)),
                              "this zone observes DST, so the two offsets must differ on disk")
        }
    }

    func test_record_forTwoInstantsOneSecondApart_producesDistinctSecondPrecisionStrings() {
        let earlier = SessionLog.record(for: interval(seconds: 60, start: Self.fixedStart))
        let later = SessionLog.record(for: interval(seconds: 60,
                                                    start: Self.fixedStart.addingTimeInterval(1)))
        XCTAssertNotEqual(earlier.start, later.start,
                          "second-resolution timestamps must not collapse adjacent seconds")
    }

    // MARK: - line(for:)

    func test_line_forEachDurationAndNotePairing_producesALineOnlyForTheOnesThatMustBeLogged() {
        // Absolute expectations, not "line() agrees with shouldLog()": the two
        // could be broken together and a relative check would stay green.
        let cases: [(seconds: Int, note: String?, expectsLine: Bool)] = [
            (Int.min, nil, false), (-1, nil, false), (0, nil, false), (4, nil, false),
            (5, nil, true), (6, nil, true), (1500, nil, true), (Int.max, nil, true),
            (-3, "n", true), (0, "n", true), (4, "n", true), (5, "n", true), (0, "", true)
        ]
        for testCase in cases {
            let entry = testCase.note == nil
                ? interval(seconds: testCase.seconds, end: Self.fixedStart)
                : noteRecord(note: testCase.note, seconds: testCase.seconds)
            let label = "seconds=\(testCase.seconds) note=\(String(describing: testCase.note))"
            XCTAssertEqual(SessionLog.line(for: entry) != nil, testCase.expectsLine,
                           "line(for:) is wrong for \(label)")
            XCTAssertEqual(SessionLog.shouldLog(entry), testCase.expectsLine,
                           "shouldLog is wrong for \(label)")
        }
    }

    func test_line_forAnEntryBelowTheNoiseFloor_returnsNil() {
        XCTAssertNil(SessionLog.line(for: interval(seconds: 4)))
    }

    func test_line_forAnIntervalExactlyAtTheNoiseFloor_returnsALine() {
        XCTAssertNotNil(SessionLog.line(for: interval(seconds: 5)))
    }

    func test_line_forALoggedEntry_endsWithExactlyOneNewlineAndEmbedsNoOthers() throws {
        let lineData = try XCTUnwrap(SessionLog.line(for: interval(seconds: 1500)))
        XCTAssertEqual(lineData.last, UInt8(ascii: "\n"), "a JSONL line must be newline-terminated")
        XCTAssertEqual(lineData.filter { $0 == UInt8(ascii: "\n") }.count, 1,
                       "one entry must occupy exactly one line")
    }

    func test_line_forATaskContainingNewlinesAndQuotes_escapesThemSoOneEntryStaysOneLine() throws {
        // A raw newline inside `task` would split one record across two JSONL
        // lines, and every line-oriented reader would then see one truncated
        // record plus one unparseable fragment.
        let hostile = "first\nsecond\r\nthird \"quoted\" \\ backslash\ttab"
        let lineData = try XCTUnwrap(SessionLog.line(for: interval(seconds: 60, task: hostile)))
        XCTAssertEqual(lineData.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        XCTAssertEqual(lineData.filter { $0 == UInt8(ascii: "\r") }.count, 0)
        XCTAssertEqual(try decodeRecord(from: lineData).task, hostile,
                       "escaping must round-trip losslessly")
    }

    func test_line_forANoteContainingANewline_stillProducesASingleLine() throws {
        let lineData = try XCTUnwrap(SessionLog.line(for: noteRecord(note: "line one\nline two")))
        XCTAssertEqual(lineData.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        XCTAssertEqual(try decodeRecord(from: lineData).note, "line one\nline two")
    }

    func test_line_forALoggedEntry_decodesBackIntoTheSameRecord() throws {
        let entry = interval(seconds: 1500, task: "round trip")
        let lineData = try XCTUnwrap(SessionLog.line(for: entry))
        XCTAssertEqual(try decodeRecord(from: lineData), SessionLog.record(for: entry))
    }

    func test_line_forALoggedEntry_carriesEveryV2KeyWithTheJSONTypeReadersExpect() throws {
        let lineData = try XCTUnwrap(SessionLog.line(for: interval(seconds: 1500, task: "t")))
        let json = try jsonObject(from: lineData)

        XCTAssertEqual(json["seconds"] as? Int, 1500,
                       "seconds must be a JSON number, not a quoted string")
        XCTAssertEqual(json["schemaVersion"] as? Int, 2,
                       "schemaVersion must be a JSON number, not a quoted string")
        XCTAssertEqual(json["phase"] as? String, "work")
        XCTAssertEqual(json["reason"] as? String, "completed")
        XCTAssertEqual(json["kind"] as? String, "pomodoro")
        XCTAssertEqual(json["task"] as? String, "t")
        XCTAssertEqual(json["timerID"] as? String, Self.fixedTimerID.uuidString)
        XCTAssertEqual(json["sessionID"] as? String, Self.fixedSessionID.uuidString)
        XCTAssertNotNil(json["start"] as? String)
        XCTAssertNotNil(json["end"] as? String)
        XCTAssertNil(json["note"], "a normal interval must not emit a note key")
    }

    // MARK: - Decode compatibility with pre-v2 lines already on disk

    func test_decode_preV2LineWithOnlyTheSixOriginalFields_yieldsNilForEveryV2Field() throws {
        // The historical shape, written out verbatim: lines like this are
        // already in users' sessions.jsonl and must never stop decoding.
        let historicalLine = """
        {"start":"2025-04-01T09:00:00+09:00","end":"2025-04-01T09:25:00+09:00","seconds":1500,\
        "phase":"work","task":"draft the proposal","reason":"completed"}
        """
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(historicalLine.utf8))

        XCTAssertEqual(record.start, "2025-04-01T09:00:00+09:00")
        XCTAssertEqual(record.end, "2025-04-01T09:25:00+09:00")
        XCTAssertEqual(record.seconds, 1500)
        XCTAssertEqual(record.phase, "work")
        XCTAssertEqual(record.task, "draft the proposal")
        XCTAssertEqual(record.reason, "completed")

        XCTAssertNil(record.kind)
        XCTAssertNil(record.timerID)
        XCTAssertNil(record.sessionID)
        XCTAssertNil(record.schemaVersion, "an unstamped line is pre-v2, not v2")
        XCTAssertNil(record.note)
    }

    func test_decode_preV2LineUsingThePauseAndBreakSpellings_mapsBackOntoTheSameEnumCases() throws {
        let historicalLine = """
        {"start":"2025-04-01T09:25:00+09:00","end":"2025-04-01T09:30:00+09:00","seconds":300,\
        "phase":"break","task":"","reason":"pause"}
        """
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(historicalLine.utf8))
        XCTAssertEqual(record.phase, "break")
        XCTAssertEqual(SessionEndReason(rawValue: record.reason), .paused,
                       "\"pause\" on disk must still map onto SessionEndReason.paused")
        XCTAssertEqual(record.task, "",
                       "an empty historical task must stay empty, not become nil or a placeholder")
    }

    func test_decode_lineWithExplicitNullsForTheV2Fields_yieldsNilRatherThanThrowing() throws {
        let line = """
        {"start":"2025-04-01T09:00:00+09:00","end":"2025-04-01T09:25:00+09:00","seconds":1500,\
        "phase":"work","task":"t","reason":"completed","kind":null,"timerID":null,\
        "sessionID":null,"schemaVersion":null,"note":null}
        """
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(line.utf8))
        XCTAssertNil(record.kind)
        XCTAssertNil(record.timerID)
        XCTAssertNil(record.sessionID)
        XCTAssertNil(record.schemaVersion)
        XCTAssertNil(record.note)
        XCTAssertEqual(record.seconds, 1500, "the required fields must survive the nulls")
    }

    func test_decode_lineMissingARequiredField_throwsRatherThanDefaultingSilently() {
        let missingSeconds = """
        {"start":"2025-04-01T09:00:00+09:00","end":"2025-04-01T09:25:00+09:00",\
        "phase":"work","task":"t","reason":"completed"}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionRecord.self, from: Data(missingSeconds.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError, "expected a DecodingError, got \(error)")
        }
    }

    func test_decode_malformedJSON_throwsRatherThanProducingAnEmptyRecord() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionRecord.self, from: Data("{not json".utf8))
        )
        XCTAssertThrowsError(try JSONDecoder().decode(SessionRecord.self, from: Data("".utf8)))
    }

    func test_decode_misspelledReason_isNotAcceptedAsAKnownEndReason() {
        // Over-permissive parsing check: a near-miss must not quietly map onto
        // a real case.
        XCTAssertNil(SessionEndReason(rawValue: "paused"))
        XCTAssertNil(SessionEndReason(rawValue: "Pause"))
        XCTAssertNil(SessionEndReason(rawValue: "PAUSE"))
        XCTAssertNil(SessionEndReason(rawValue: " pause"))
        XCTAssertEqual(SessionEndReason(rawValue: "pause"), .paused)
    }

    func test_decode_misspelledTimerKind_isNotAcceptedAsAKnownKind() {
        XCTAssertNil(TimerKind(rawValue: "Pomodoro"))
        XCTAssertNil(TimerKind(rawValue: "pomo"))
        XCTAssertEqual(TimerKind(rawValue: "pomodoro"), .pomodoro)
        XCTAssertEqual(TimerKind(rawValue: "tracker"), .tracker)
    }

    // MARK: - I/O: the real append path

    func test_fileURL_withADirectory_pointsAtSessionsJsonlInsideIt() {
        let log = SessionLog(directory: tempDirectory)
        XCTAssertEqual(log.fileURL?.lastPathComponent, "sessions.jsonl")
        XCTAssertEqual(log.fileURL?.deletingLastPathComponent().standardizedFileURL,
                       tempDirectory.standardizedFileURL)
    }

    func test_temporaryDirectory_isNeverInsideTheUsersRealApplicationSupportDirectory() throws {
        // The whole point of the injectable `directory:` — assert it, do not
        // assume it. A prefix check, not just inequality: a temp directory
        // *nested under* the real one would be just as dangerous.
        let real = try XCTUnwrap(SessionLog.applicationSupportDirectory).standardizedFileURL
        XCTAssertNotEqual(tempDirectory.standardizedFileURL, real)
        XCTAssertFalse(tempDirectory.standardizedFileURL.path.hasPrefix(real.path),
                       "the test directory must live outside Application Support/Pomo entirely")
        XCTAssertNotEqual(SessionLog(directory: tempDirectory).fileURL, SessionLog.shared.fileURL)
    }

    func test_sharedLog_pointsAtTheApplicationSupportPomoFolder() {
        XCTAssertEqual(SessionLog.shared.directory?.lastPathComponent, "Pomo")
        XCTAssertEqual(SessionLog.shared.fileURL?.lastPathComponent, "sessions.jsonl")
        XCTAssertEqual(SessionLog.shared.directory?.standardizedFileURL,
                       SessionLog.applicationSupportDirectory?.standardizedFileURL)
    }

    func test_append_threeEntriesToAFreshDirectory_writesOneJSONObjectPerLineInAppendOrder() throws {
        let log = SessionLog(directory: tempDirectory)
        let tasks = ["first task", "second task", "third task"]
        for (index, task) in tasks.enumerated() {
            log.append(interval(seconds: 600 + index, task: task))
        }
        log.waitForPendingWrites()

        let lines = try readLines(at: try XCTUnwrap(log.fileURL))
        XCTAssertEqual(lines.count, 3)

        let records = try decodeAll(lines)
        XCTAssertEqual(records.map(\.task), tasks, "append order must be preserved")
        XCTAssertEqual(records.map(\.seconds), [600, 601, 602])
        for line in lines {
            XCTAssertNotNil(
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "every line must be exactly one JSON object"
            )
        }
    }

    func test_append_aDroppedSubNoiseFloorEntryBetweenTwoLoggedOnes_addsNoLineAtAll() throws {
        let log = SessionLog(directory: tempDirectory)
        log.append(interval(seconds: 600, task: "kept before"))
        log.append(interval(seconds: 4, task: "dropped"))
        log.append(interval(seconds: 600, task: "kept after"))
        log.waitForPendingWrites()

        let records = try decodeAll(try readLines(at: try XCTUnwrap(log.fileURL)))
        XCTAssertEqual(records.count, 2, "the 4-second interval must not reach the file")
        XCTAssertEqual(records.map(\.task), ["kept before", "kept after"])
        XCTAssertFalse(records.contains { $0.task == "dropped" })
    }

    func test_append_toADirectoryThatDoesNotExistYet_createsTheDirectoryAndTheFile() throws {
        let nested = tempDirectory.appendingPathComponent("not/created/yet", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path),
                       "precondition: nothing on disk yet")

        let log = SessionLog(directory: nested)
        log.append(interval(seconds: 600))
        log.waitForPendingWrites()

        let fileURL = try XCTUnwrap(log.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try readLines(at: fileURL).count, 1)
    }

    func test_append_toAFileThatAlreadyHasAPreV2Line_appendsRatherThanTruncating() throws {
        // Exercises the FileHandle/seekToEnd branch: the first append creates
        // the file, everything after must extend it. Truncating here would
        // silently destroy the user's history.
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent("sessions.jsonl")
        let historicalLine = """
        {"start":"2025-04-01T09:00:00+09:00","end":"2025-04-01T09:25:00+09:00","seconds":1500,\
        "phase":"work","task":"yesterday","reason":"completed"}

        """
        try Data(historicalLine.utf8).write(to: fileURL)

        let log = SessionLog(directory: tempDirectory)
        log.append(interval(seconds: 600, task: "today"))
        log.waitForPendingWrites()

        let records = try decodeAll(try readLines(at: fileURL))
        XCTAssertEqual(records.map(\.task), ["yesterday", "today"])
        guard records.count == 2 else { return }
        XCTAssertNil(records[0].schemaVersion, "the historical line must survive untouched")
        XCTAssertEqual(records[1].schemaVersion, 2)
    }

    func test_append_onlySubNoiseFloorEntries_neverCreatesTheFileOrTheDirectory() throws {
        let log = SessionLog(directory: tempDirectory)
        log.append(interval(seconds: 0))
        log.append(interval(seconds: 4))
        log.waitForPendingWrites()

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(log.fileURL).path),
                       "dropped entries must not even create sessions.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path),
                       "a dropped entry must not reach the filesystem at all")
    }

    func test_append_aNoteRecord_writesItAsItsOwnIndependentLine() throws {
        let log = SessionLog(directory: tempDirectory)
        log.append(interval(seconds: 1500, task: "deep work"))
        log.append(noteRecord(note: "felt focused"))
        log.waitForPendingWrites()

        let records = try decodeAll(try readLines(at: try XCTUnwrap(log.fileURL)))
        XCTAssertEqual(records.count, 2,
                       "a note is an extra record, not a rewrite of the work interval")
        guard records.count == 2 else { return }
        XCTAssertEqual(records[0].reason, "completed")
        XCTAssertNil(records[0].note)
        XCTAssertEqual(records[1].reason, "note")
        XCTAssertEqual(records[1].note, "felt focused")
        XCTAssertEqual(records[1].seconds, 0)
    }

    func test_append_toTwoLogsSharingOneDirectory_interleavesWholeLinesOnly() throws {
        // The serial ioQueue's whole job: two appends must never tear a line.
        // The appends are enqueued from this thread in a fixed order, so the
        // expected sequence is deterministic — no sleeps, no racing.
        let logOne = SessionLog(directory: tempDirectory)
        let logTwo = SessionLog(directory: tempDirectory)
        for index in 0..<10 {
            logOne.append(interval(seconds: 600, task: "one-\(index)"))
            logTwo.append(interval(seconds: 600, task: "two-\(index)"))
        }
        logOne.waitForPendingWrites()
        logTwo.waitForPendingWrites()

        let records = try decodeAll(try readLines(at: try XCTUnwrap(logOne.fileURL)))
        XCTAssertEqual(records.count, 20)
        XCTAssertEqual(records.map(\.task), (0..<10).flatMap { ["one-\($0)", "two-\($0)"] })
    }

    // MARK: - I/O: nil directory and unwritable paths

    func test_fileURL_withNilDirectory_isNil() {
        XCTAssertNil(SessionLog(directory: nil).fileURL)
    }

    func test_append_withNilDirectory_isASilentNoOpThatWritesNothingAnywhere() {
        let log = SessionLog(directory: nil)
        log.append(interval(seconds: 1500))
        log.append(noteRecord(note: "n"))
        log.waitForPendingWrites()

        XCTAssertNil(log.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path),
                       "a nil-directory log must not fall back to any other location")
    }

    func test_ensureDirectoryExists_withNilDirectory_returnsNilAndCreatesNothing() {
        XCTAssertNil(SessionLog(directory: nil).ensureDirectoryExists())
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
    }

    func test_ensureDirectoryExists_withAMissingDirectory_createsItAndReturnsIt() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path), "precondition")
        let returned = SessionLog(directory: tempDirectory).ensureDirectoryExists()
        XCTAssertEqual(returned?.standardizedFileURL, tempDirectory.standardizedFileURL)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func test_ensureDirectoryExists_calledTwice_isIdempotentAndStillReturnsTheDirectory() {
        let log = SessionLog(directory: tempDirectory)
        XCTAssertEqual(log.ensureDirectoryExists()?.standardizedFileURL,
                       tempDirectory.standardizedFileURL)
        XCTAssertEqual(log.ensureDirectoryExists()?.standardizedFileURL,
                       tempDirectory.standardizedFileURL)
    }

    func test_ensureDirectoryExists_whenAFileBlocksThePath_returnsNilBecauseTheDirectoryIsUnavailable() throws {
        // Regression: creation used to run under `try?`, so a genuine failure
        // still returned the URL of a directory that does not exist. The only
        // caller — "Open Logs Folder" in FloatingWindow — beeps on nil but
        // otherwise hands the path to NSWorkspace, so the menu item silently
        // did nothing instead of reporting the problem.
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let blocker = tempDirectory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let log = SessionLog(directory: blocker.appendingPathComponent("sub", isDirectory: true))

        let returned = log.ensureDirectoryExists()

        // Unambiguous half of the contract: best-effort must damage nothing.
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "not a directory")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: blocker.appendingPathComponent("sub", isDirectory: true).path
        ))

        XCTAssertNil(returned,
                     "an uncreatable directory is unavailable, so nil is the documented answer")
    }

    func test_append_whenTheDirectoryCannotBeCreated_swallowsTheFailureAndWritesNoFile() throws {
        // Never-crash contract: a bad path must not throw out of `append`, and
        // must not leave a half-written file behind.
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let blocker = tempDirectory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)

        let log = SessionLog(directory: blocker.appendingPathComponent("sub", isDirectory: true))
        log.append(interval(seconds: 1500))
        log.waitForPendingWrites()

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(log.fileURL).path))
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "not a directory",
                       "the blocking file must be left untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path),
                       ["blocked"],
                       "a failed append must not create anything anywhere near the target")
    }

    func test_waitForPendingWrites_withNothingQueued_returnsWithoutCreatingAnything() {
        let log = SessionLog(directory: tempDirectory)
        log.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
    }
}
