import XCTest
@testable import Pomo

/// `PomodoroSource`'s duration constants are read by code that cannot see each
/// other: `FloatingWindow` interpolates `minCustomMinutes`/`maxCustomMinutes`
/// into the Custom… dialog's prompt text AND uses the same pair as the accept
/// guard; `TimerInstanceController` falls back to the defaults when no source
/// exists yet; `PillLayout` sizes the window for the widest minute value the
/// maximum implies. Drift between any of those is silent — the prompt says one
/// range and the guard beeps at another, or the pill clips a number it is
/// perfectly happy to count down from.
///
/// No `PomodoroSource` is constructed here: its `init` reads and writes
/// `UserDefaults.standard`, i.e. the user's real domain. Only the static
/// constants are touched. The class is `@MainActor`-isolated, so the test case
/// is too.
@MainActor
final class PomodoroDurationConstantsTests: XCTestCase {

    // MARK: - The literal values

    func test_defaultWorkMinutes_is25_theClassicPomodoroLength() {
        XCTAssertEqual(PomodoroSource.defaultWorkMinutes, 25)
    }

    func test_defaultBreakMinutes_is5_theClassicShortBreakLength() {
        XCTAssertEqual(PomodoroSource.defaultBreakMinutes, 5)
    }

    /// These two numbers are interpolated verbatim into the Custom… dialog's
    /// prompt ("Enter minutes (1–180):") and are also the accept guard. The
    /// prose and the guard read the same constants, so this test pins the pair
    /// that both sides show the user.
    func test_customMinuteBounds_are1And180_theNumbersTheCustomDialogPromptShows() {
        XCTAssertEqual(PomodoroSource.minCustomMinutes, 1)
        XCTAssertEqual(PomodoroSource.maxCustomMinutes, 180)
    }

    func test_overtimeAlertDuration_isTenSeconds() {
        XCTAssertEqual(PomodoroSource.overtimeAlertSeconds, 10)
    }

    // MARK: - The invariants those literals have to keep

    /// BOUNDARY / OFF-BY-ONE: `FloatingWindow.presentCustomDurationAlert` builds
    /// `min...max` and accepts on `range.contains(value)`, so the accepted set
    /// is exactly `1...180` inclusive. Asserted against LITERALS, not against
    /// the constants themselves — `range.contains(min - 1)` would be false for
    /// any `min` whatsoever and so would pin nothing.
    func test_theAcceptedCustomRange_isExactly1Through180Inclusive() {
        let range = PomodoroSource.minCustomMinutes...PomodoroSource.maxCustomMinutes

        XCTAssertFalse(range.contains(0), "0 minutes must be rejected")
        XCTAssertTrue(range.contains(1), "1 minute is the documented minimum and must be accepted")
        XCTAssertTrue(range.contains(2))
        XCTAssertTrue(range.contains(179))
        XCTAssertTrue(range.contains(180), "180 minutes is the documented maximum and must be accepted")
        XCTAssertFalse(range.contains(181), "181 minutes must be rejected")
        XCTAssertFalse(range.contains(1000))
    }

    /// NEGATIVE: zero and negative custom durations are invalid input and must
    /// never reach the countdown state machine.
    func test_zeroAndNegativeMinutes_areOutsideTheAcceptedCustomRange() {
        let range = PomodoroSource.minCustomMinutes...PomodoroSource.maxCustomMinutes
        XCTAssertGreaterThan(PomodoroSource.minCustomMinutes, 0)
        XCTAssertFalse(range.contains(0))
        XCTAssertFalse(range.contains(-1))
        XCTAssertFalse(range.contains(-25))
    }

    /// The bounds must form a valid non-empty range at all. `min...max` with
    /// min > max is a runtime trap the moment the Custom… dialog opens, and
    /// nothing else in the app would notice at build time.
    func test_minCustomMinutes_isStrictlyBelowMaxCustomMinutes_soTheRangeIsConstructible() {
        XCTAssertLessThan(PomodoroSource.minCustomMinutes, PomodoroSource.maxCustomMinutes)
    }

    /// The Custom… dialog prefills the field with the CURRENT setting and then
    /// validates it against the same range. If a default sat outside the range,
    /// a user who opened the dialog on a fresh install and pressed OK unchanged
    /// would just get a beep.
    func test_bothDefaultDurations_lieInsideTheAcceptedCustomRange() {
        let range = PomodoroSource.minCustomMinutes...PomodoroSource.maxCustomMinutes
        XCTAssertTrue(range.contains(PomodoroSource.defaultWorkMinutes),
                      "default work \(PomodoroSource.defaultWorkMinutes) is outside \(range)")
        XCTAssertTrue(range.contains(PomodoroSource.defaultBreakMinutes),
                      "default break \(PomodoroSource.defaultBreakMinutes) is outside \(range)")
    }

    /// `PomodoroSource.init` treats a stored value of 0 as "nothing stored" and
    /// substitutes the default, so both defaults must be strictly positive or a
    /// fresh install would start at 0:00.
    func test_bothDefaultDurations_areStrictlyPositive() {
        XCTAssertGreaterThan(PomodoroSource.defaultWorkMinutes, 0)
        XCTAssertGreaterThan(PomodoroSource.defaultBreakMinutes, 0)
    }

    /// A break at least as long as a work phase is not a pomodoro; this pins
    /// the intended relationship rather than just the two numbers.
    func test_defaultBreak_isShorterThanDefaultWork() {
        XCTAssertLessThan(PomodoroSource.defaultBreakMinutes, PomodoroSource.defaultWorkMinutes)
    }

    /// CROSS-FILE INVARIANT: the pill reserves at most 3 minute digits, and
    /// that upper bound is justified in `PomodoroSource.minuteDigits` purely by
    /// "Custom duration is capped at `maxCustomMinutes`". Raising the cap to
    /// 1000+ would clip the countdown with nothing else failing.
    func test_maxCustomMinutes_stillFitsThePillsThreeDigitCountdownBudget() {
        XCTAssertLessThan(PomodoroSource.maxCustomMinutes, 1000,
                          "a 4-digit maximum would clip the pill's countdown")
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: PomodoroSource.maxCustomMinutes), 3)
    }

    /// BOUNDARY / OFF-BY-ONE on the digit threshold itself. 99 minutes renders
    /// as "99:00" (2 slots) and 100 as "100:00" (3). One step either way is the
    /// classic silent failure here: a `> 100` test would size 100 minutes for
    /// two digits and clip it, and a `>= 99` test would waste a slot forever.
    func test_minuteDigits_switchesFromTwoToThreeExactlyAt100Minutes() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 98), 2)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 99), 2)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 100), 3)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 101), 3)
    }

    /// EMPTY / MIN / NEGATIVE input to the same pure function: a 0-minute or
    /// nonsensical negative maximum must still ask for 2 slots, never 0 or a
    /// negative slot count that would collapse the countdown column.
    func test_minuteDigits_forZeroOrNegativeMaximums_stillReservesTwoSlots() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 0), 2)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: 1), 2)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: -1), 2)
    }

    /// Both defaults, and every preset the ⚙ menu offers below the cap, sit in
    /// the 2-digit regime — that is why the pill's resting size is the 2-digit
    /// baseline (`PomoSize.pillSize`) rather than the widest layout.
    func test_bothDefaultDurations_sitInTheTwoDigitRegime_matchingThePillsRestingSize() {
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: PomodoroSource.defaultWorkMinutes), 2)
        XCTAssertEqual(PillLayout.minuteDigits(forMaxMinutes: PomodoroSource.defaultBreakMinutes), 2)
    }

    func test_maxDisplayedOvertime_staysWithinTheThreeDigitMinuteBudget() {
        XCTAssertEqual(PomodoroSource.maxDisplayedOvertimeSeconds, 999 * 60 + 59)
        XCTAssertLessThan(PomodoroSource.maxDisplayedOvertimeSeconds / 60, 1000)
    }
}
