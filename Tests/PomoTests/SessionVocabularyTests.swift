import XCTest
@testable import Pomo

/// The strings in `SessionSource.swift` are a DATA CONTRACT with the JSONL file
/// at `~/Library/Application Support/Pomo/sessions.jsonl`. Every line ever
/// written carries them, and nothing migrates old lines. Renaming a case — or,
/// worse, dropping a custom raw value so the Swift identifier leaks onto disk —
/// silently orphans historical data: the app keeps running, new lines look
/// fine, and every past record quietly stops matching.
///
/// These tests are deliberately dumb string equality. That is the point: they
/// are the cheapest possible tripwire on a rename.
///
/// Nothing here touches the filesystem, UserDefaults, the clock or any
/// singleton — these are pure value types.
final class SessionEndReasonWireFormatTests: XCTestCase {

    /// Every case, listed by hand. `SessionEndReason` is not `CaseIterable`, so
    /// this list plus the exhaustive switch in `expectedWireValue(for:)` below
    /// is what forces a new case to be considered here rather than shipped
    /// unexamined.
    private static let allReasons: [SessionEndReason] = [
        .completed, .paused, .reset, .stopped, .closed, .note
    ]

    /// Exhaustive by construction: adding a case to `SessionEndReason` breaks
    /// THIS SWITCH at compile time, which is the guard rail. Do not add a
    /// `default:` arm.
    private func expectedWireValue(for reason: SessionEndReason) -> String {
        switch reason {
        case .completed: return "completed"
        case .paused:    return "pause"
        case .reset:     return "reset"
        case .stopped:   return "stopped"
        case .closed:    return "closed"
        case .note:      return "note"
        }
    }

    func test_everySessionEndReason_hasTheExactRawValueAlreadyOnDiskInSessionsJSONL_soHistoricalLinesKeepMatching() {
        XCTAssertEqual(SessionEndReason.completed.rawValue, "completed")
        XCTAssertEqual(SessionEndReason.paused.rawValue, "pause")
        XCTAssertEqual(SessionEndReason.reset.rawValue, "reset")
        XCTAssertEqual(SessionEndReason.stopped.rawValue, "stopped")
        XCTAssertEqual(SessionEndReason.closed.rawValue, "closed")
        XCTAssertEqual(SessionEndReason.note.rawValue, "note")

        // Same assertion again, driven through the exhaustive switch, so a
        // newly added case cannot slip past this file without a compile error.
        for reason in Self.allReasons {
            XCTAssertEqual(reason.rawValue, expectedWireValue(for: reason),
                           "wire value for \(reason) changed — sessions.jsonl history would be orphaned")
        }
    }

    /// The hand-written census above has to actually be the whole enum. A case
    /// missing from `allReasons` would quietly shrink every loop in this file
    /// into a weaker test, and nothing else would notice.
    func test_theHandWrittenCensus_coversSixDistinctReasonsWithSixDistinctWireValues() {
        XCTAssertEqual(Self.allReasons.count, 6)
        XCTAssertEqual(Set(Self.allReasons.map(\.rawValue)).count, 6,
                       "two reasons share a wire value — they would merge on disk")
    }

    /// REGRESSION: the case is spelled `paused`, the disk value is `"pause"`.
    /// If someone "tidies up" by deleting `= "pause"`, Swift silently starts
    /// writing `"paused"` and nothing throws. This asserts the mismatch that
    /// makes the custom raw value load-bearing.
    func test_pausedCase_isSpelledPauseOnDisk_andTheSwiftIdentifierIsNotAValidWireValue() {
        XCTAssertEqual(SessionEndReason.paused.rawValue, "pause")
        XCTAssertNil(SessionEndReason(rawValue: "paused"),
                     #"if "paused" ever parses, the custom raw value has been dropped"#)
    }

    func test_everySessionEndReason_roundTripsThroughItsRawValue() {
        for reason in Self.allReasons {
            XCTAssertEqual(SessionEndReason(rawValue: reason.rawValue), reason)
        }
    }

    /// The shape that actually reaches disk is an object field, not a bare
    /// value, so this encodes through a wrapper to assert the real JSON text.
    func test_encodingASessionEndReason_producesTheWireStringAsJSON() throws {
        struct Wrapper: Codable { let reason: SessionEndReason }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for reason in Self.allReasons {
            let data = try encoder.encode(Wrapper(reason: reason))
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(json, "{\"reason\":\"\(expectedWireValue(for: reason))\"}")
        }
    }

    func test_decodingEveryHistoricalReasonString_yieldsTheMatchingCase() throws {
        struct Wrapper: Codable { let reason: SessionEndReason }
        let decoder = JSONDecoder()

        // Written exactly as a historical sessions.jsonl line would carry them,
        // including the two reasons the current app never emits.
        let historical: [(String, SessionEndReason)] = [
            ("completed", .completed),
            ("pause", .paused),
            ("reset", .reset),
            ("stopped", .stopped),
            ("closed", .closed),
            ("note", .note)
        ]
        for (raw, expected) in historical {
            let data = Data("{\"reason\":\"\(raw)\"}".utf8)
            XCTAssertEqual(try decoder.decode(Wrapper.self, from: data).reason, expected,
                           "historical line with reason \"\(raw)\" no longer decodes to \(expected)")
        }
    }

    /// NEGATIVE: the enum must NOT be over-permissive. An unrecognised reason
    /// has to fail loudly rather than fall back to some default case, which
    /// would silently reclassify data.
    func test_decodingAnUnknownReasonString_throwsRatherThanFallingBackToADefaultCase() {
        struct Wrapper: Codable { let reason: SessionEndReason }
        let data = Data("{\"reason\":\"cancelled\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Wrapper.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "expected a DecodingError, got \(error)")
        }
    }

    /// EMPTY / MALFORMED / CASE-SENSITIVITY: raw-value lookup is exact. These
    /// all have to be nil, otherwise a sloppy edit to a log line would parse.
    func test_emptyMalformedOrDifferentlyCasedReasonStrings_doNotParse() {
        XCTAssertNil(SessionEndReason(rawValue: ""))
        XCTAssertNil(SessionEndReason(rawValue: " "))
        XCTAssertNil(SessionEndReason(rawValue: "Completed"))
        XCTAssertNil(SessionEndReason(rawValue: "COMPLETED"))
        XCTAssertNil(SessionEndReason(rawValue: " completed"))
        XCTAssertNil(SessionEndReason(rawValue: "completed "))
        XCTAssertNil(SessionEndReason(rawValue: "complete"))
        XCTAssertNil(SessionEndReason(rawValue: "Break"))
    }
}

final class TimerKindWireFormatTests: XCTestCase {

    private static let allKinds: [TimerKind] = [.pomodoro, .tracker]

    /// Exhaustive by construction — see the note in
    /// `SessionEndReasonWireFormatTests`. No `default:` arm.
    private func expectedWireValue(for kind: TimerKind) -> String {
        switch kind {
        case .pomodoro: return "pomodoro"
        case .tracker:  return "tracker"
        }
    }

    func test_everyTimerKind_hasTheExactRawValueAlreadyOnDiskInSessionsJSONL() {
        XCTAssertEqual(TimerKind.pomodoro.rawValue, "pomodoro")
        // `.tracker` is never produced by this app; it exists so historical
        // lines from the dropped stopwatch still decode. Renaming it would
        // orphan exactly the data it was kept for.
        XCTAssertEqual(TimerKind.tracker.rawValue, "tracker")

        for kind in Self.allKinds {
            XCTAssertEqual(kind.rawValue, expectedWireValue(for: kind))
        }
    }

    func test_theHandWrittenCensus_coversTwoDistinctKindsWithTwoDistinctWireValues() {
        XCTAssertEqual(Self.allKinds.count, 2)
        XCTAssertEqual(Set(Self.allKinds.map(\.rawValue)).count, 2,
                       "the two kinds share a wire value — they would merge on disk")
    }

    func test_everyTimerKind_roundTripsThroughItsRawValue() {
        for kind in Self.allKinds {
            XCTAssertEqual(TimerKind(rawValue: kind.rawValue), kind)
        }
    }

    func test_encodingAndDecodingATimerKind_roundTripsThroughTheWireString() throws {
        struct Wrapper: Codable { let kind: TimerKind }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for kind in Self.allKinds {
            let data = try encoder.encode(Wrapper(kind: kind))
            XCTAssertEqual(String(decoding: data, as: UTF8.self),
                           "{\"kind\":\"\(expectedWireValue(for: kind))\"}")
            XCTAssertEqual(try JSONDecoder().decode(Wrapper.self, from: data).kind, kind)
        }
    }

    /// NEGATIVE: an unknown kind must throw, not silently become `.pomodoro`.
    func test_decodingAnUnknownKindString_throwsRatherThanDefaultingToPomodoro() {
        struct Wrapper: Codable { let kind: TimerKind }
        let data = Data("{\"kind\":\"stopwatch\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Wrapper.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "expected a DecodingError, got \(error)")
        }
    }

    func test_emptyOrDifferentlyCasedKindStrings_doNotParse() {
        XCTAssertNil(TimerKind(rawValue: ""))
        XCTAssertNil(TimerKind(rawValue: "Pomodoro"))
        XCTAssertNil(TimerKind(rawValue: "POMODORO"))
        XCTAssertNil(TimerKind(rawValue: "pomo"))
        XCTAssertNil(TimerKind(rawValue: "Tracker"))
    }
}

final class PhaseLogNameTests: XCTestCase {

    private static let allPhases: [Phase] = [.work, .shortBreak]

    /// Exhaustive by construction. No `default:` arm — adding a phase must
    /// break compilation here so its disk spelling gets decided deliberately.
    private func expectedLogName(for phase: Phase) -> String {
        switch phase {
        case .work:       return "work"
        case .shortBreak: return "break"
        }
    }

    /// REGRESSION: the Swift case is `shortBreak`, the disk value is `"break"`.
    /// Writing the case name instead would split every historical break
    /// interval away from every future one.
    func test_shortBreakPhase_logsAsBreakNotShortBreak_becauseExistingDataUsesThatSpelling() {
        XCTAssertEqual(Phase.shortBreak.logName, "break")
        XCTAssertNotEqual(Phase.shortBreak.logName, "shortBreak")
    }

    func test_everyPhase_hasTheExactLogNameAlreadyOnDiskInSessionsJSONL() {
        XCTAssertEqual(Phase.work.logName, "work")
        XCTAssertEqual(Phase.shortBreak.logName, "break")

        for phase in Self.allPhases {
            XCTAssertEqual(phase.logName, expectedLogName(for: phase))
        }
    }

    /// The two phases must not collapse onto one spelling — a copy-paste slip
    /// in the switch would make every break look like work in the log, which no
    /// type checker catches.
    func test_theTwoPhases_haveDistinctLogNames() {
        XCTAssertNotEqual(Phase.work.logName, Phase.shortBreak.logName)
        XCTAssertEqual(Set(Self.allPhases.map(\.logName)).count, Self.allPhases.count)
        XCTAssertEqual(Self.allPhases.count, 2, "a phase was added or removed without updating this file")
    }

    /// `logName` is a pure, total mapping: no empty strings, no whitespace, no
    /// casing surprises for a downstream reader grouping by this field.
    /// `lowercased()` (not `lowercased(with:)`) is locale-independent, so this
    /// holds identically on a Turkish-locale machine.
    func test_everyLogName_isNonEmptyLowercaseAsciiAndFreeOfWhitespace() {
        for phase in Self.allPhases {
            let name = phase.logName
            XCTAssertFalse(name.isEmpty)
            XCTAssertEqual(name, name.lowercased())
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertTrue(name.allSatisfy { $0.isASCII && $0.isLetter },
                          "\(name) is not plain ASCII letters — JSONL readers group on this field")
        }
    }

    /// NEGATIVE: neither phase may log under the OTHER phase's spelling, nor
    /// under any near-miss a reader would have to special-case.
    func test_neitherPhase_logsUnderTheOtherPhasesSpellingOrANearMiss() {
        XCTAssertNotEqual(Phase.work.logName, "break")
        XCTAssertNotEqual(Phase.work.logName, "shortBreak")
        XCTAssertNotEqual(Phase.shortBreak.logName, "work")
        XCTAssertNotEqual(Phase.work.logName, "Work")
        XCTAssertNotEqual(Phase.shortBreak.logName, "Break")
    }
}
