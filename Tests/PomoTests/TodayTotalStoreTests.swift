import Combine
import XCTest

@testable import Pomo

/// A hand-cranked clock. Declared at file scope (not nested in the test case)
/// so it does not inherit `@MainActor` isolation — `TodayTotalStore`'s `now`
/// closure has to be callable as a plain function.
private final class TestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

/// Contract tests for `TodayTotalStore`.
///
/// Everything here runs against a throwaway `UserDefaults(suiteName:)` and a
/// hand-cranked clock. Nothing writes to `.standard`, the user's real
/// `pomo.today.*` values, or the filesystem.
@MainActor
final class TodayTotalStoreTests: XCTestCase {

    // MARK: - Isolated store

    /// An in-memory stand-in, not a real `UserDefaults(suiteName:)` — see
    /// `InMemoryStore` for why. Starts provably empty for every test and
    /// leaves nothing behind, so there is no teardown to get wrong.
    private var defaults = InMemoryStore()

    override func setUp() {
        super.setUp()
        defaults = InMemoryStore()
        XCTAssertTrue(defaults.keys.isEmpty, "each test must start from an empty store")
    }

    // MARK: - Fixtures

    /// Builds an exact instant from calendar components. Never `Date()`.
    ///
    /// The default `timeZone` is `.current` on purpose: `dateStamp` formats in
    /// the system zone, so building the instant in that same zone makes the
    /// components -> Date -> string trip exact, and the expected stamp a
    /// literal, on any machine. The hazard being guarded here is the
    /// *locale/calendar*, not the zone.
    private func fixedDate(
        _ year: Int, _ month: Int, _ day: Int,
        hour: Int = 12, minute: Int = 0,
        in timeZone: TimeZone = .current,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return try XCTUnwrap(
            calendar.date(from: components),
            "could not build \(year)-\(month)-\(day) \(hour):\(minute) in \(timeZone.identifier)",
            file: file, line: line
        )
    }

    /// The true first instant of the given local day. `startOfDay` — not
    /// "midnight" arithmetic — so a zone whose DST transition happens at
    /// 00:00 still yields a real instant.
    private func startOfLocalDay(
        _ year: Int, _ month: Int, _ day: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let noon = try fixedDate(year, month, day, file: file, line: line)
        return calendar.startOfDay(for: noon)
    }

    private func makeStore(at date: Date) -> TodayTotalStore {
        TodayTotalStore(defaults: defaults, now: { date })
    }

    private func makeStore(clock: TestClock) -> TodayTotalStore {
        TodayTotalStore(defaults: defaults, now: { clock.date })
    }

    private func decodedPerTaskBlob(
        forKey key: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Int] {
        let data = try XCTUnwrap(
            defaults.data(forKey: key), "no per-task blob at \(key)", file: file, line: line
        )
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    /// Every `pomo.*` key currently present in this test's private suite.
    /// Lets a test assert what was written *and what was not*, rather than
    /// spot-checking two keys it already expected.
    private func pomoKeysInSuite() -> [String] {
        defaults.keys.filter { $0.hasPrefix("pomo.") }.sorted()
    }

    // MARK: - dateStamp: exact format, locale-independent

    /// The whole reason `en_US_POSIX` is pinned: a device-calendar render of
    /// 2026-08-01 on the Japanese calendar is "0008-08-01" (Reiwa 8), a key
    /// nothing ever reads back.
    func test_dateStamp_forFixedAugust2026Instant_isExactlyGregorianYYYYMMDD() throws {
        let instant = try fixedDate(2026, 8, 1)

        let stamp = TodayTotalStore.dateStamp(at: instant)

        XCTAssertEqual(stamp, "2026-08-01")
        XCTAssertNotEqual(
            stamp, "0008-08-01",
            "dateStamp rendered the Japanese era year — the en_US_POSIX pin was dropped"
        )
    }

    /// Same locale guard, but the instant is built in a genuinely FIXED zone,
    /// so the assertion must hold on a machine anywhere on Earth. The offset
    /// range is UTC-12...UTC+14, so 12:00 UTC can only land on Aug 1 or Aug 2;
    /// July 31 is included purely as slack. Every member of that set still
    /// excludes "0008-08-01" and "2026-8-1", which is what is being pinned.
    func test_dateStamp_forInstantBuiltInFixedUTC_isAGregorianStampWithinADayOfAugust1() throws {
        let instant = try fixedDate(2026, 8, 1, hour: 12, in: TimeZone(identifier: "UTC")!)

        let stamp = TodayTotalStore.dateStamp(at: instant)

        XCTAssertTrue(
            ["2026-07-31", "2026-08-01", "2026-08-02"].contains(stamp),
            "expected a zero-padded Gregorian stamp within a day of 2026-08-01, got \(stamp)"
        )
    }

    func test_dateStamp_forSingleDigitMonthAndDay_zeroPadsBothFields() throws {
        let instant = try fixedDate(2026, 1, 5)

        XCTAssertEqual(TodayTotalStore.dateStamp(at: instant), "2026-01-05")
    }

    func test_dateStamp_forMinAndMaxDayOfAMonth_usesTheCalendarDayNotAnOffset() throws {
        let first = try fixedDate(2026, 2, 1)
        let last = try fixedDate(2026, 2, 28)

        XCTAssertEqual(TodayTotalStore.dateStamp(at: first), "2026-02-01")
        XCTAssertEqual(TodayTotalStore.dateStamp(at: last), "2026-02-28")
    }

    func test_dateStamp_forLeapDay_rendersFebruary29() throws {
        let leapDay = try fixedDate(2028, 2, 29)

        XCTAssertEqual(TodayTotalStore.dateStamp(at: leapDay), "2028-02-29")
    }

    func test_dateStamp_forNewYearsEveAndNewYearsDay_rollsTheYearField() throws {
        let eve = try fixedDate(2025, 12, 31, hour: 23)
        let newYear = try fixedDate(2026, 1, 1, hour: 1)

        XCTAssertEqual(TodayTotalStore.dateStamp(at: eve), "2025-12-31")
        XCTAssertEqual(TodayTotalStore.dateStamp(at: newYear), "2026-01-01")
    }

    func test_dateStamp_forTwoInstantsWithinTheSameLocalDay_isIdentical() throws {
        let morning = try fixedDate(2026, 8, 1, hour: 6)
        let evening = try fixedDate(2026, 8, 1, hour: 18)

        XCTAssertEqual(
            TodayTotalStore.dateStamp(at: morning),
            TodayTotalStore.dateStamp(at: evening),
            "two instants in one local day must share one key"
        )
    }

    /// The actual off-by-one on the only range this type has: the local day.
    /// One second apart, on either side of the true day boundary.
    func test_dateStamp_atFirstMomentOfADayAndOneSecondEarlier_straddlesTheLocalDayBoundary()
        throws
    {
        let startOfAugust1 = try startOfLocalDay(2026, 8, 1)
        let lastSecondOfJuly31 = startOfAugust1.addingTimeInterval(-1)

        XCTAssertEqual(TodayTotalStore.dateStamp(at: startOfAugust1), "2026-08-01")
        XCTAssertEqual(
            TodayTotalStore.dateStamp(at: lastSecondOfJuly31), "2026-07-31",
            "the instant one second before the day starts belongs to the previous day"
        )
    }

    func test_dateStamp_calledRepeatedlyForTheSameInstant_isStable() throws {
        let instant = try fixedDate(2026, 8, 1)

        let stamps = (0..<5).map { _ in TodayTotalStore.dateStamp(at: instant) }

        XCTAssertEqual(Set(stamps), ["2026-08-01"])
    }

    // MARK: - Key derivation

    func test_todayKey_forFixedInstant_isNamespacedStampWithNoByTaskSegment() throws {
        let instant = try fixedDate(2026, 8, 1)

        XCTAssertEqual(TodayTotalStore.todayKey(at: instant), "pomo.today.2026-08-01")
    }

    func test_todayByTaskKey_forFixedInstant_isTheByTaskNamespacedStamp() throws {
        let instant = try fixedDate(2026, 8, 1)

        XCTAssertEqual(
            TodayTotalStore.todayByTaskKey(at: instant), "pomo.today.byTask.2026-08-01"
        )
    }

    /// Not just "the two differ for one instant" — no key of either kind may
    /// ever equal a key of the other kind on ANY day, or one day's per-task
    /// blob would land on another day's total.
    func test_todayKeyAndTodayByTaskKey_neverCollideAcrossAnyPairOfDays() throws {
        let days = [
            try fixedDate(2026, 8, 1),
            try fixedDate(2026, 8, 2),
            try fixedDate(2025, 12, 31),
        ]

        let totals = Set(days.map { TodayTotalStore.todayKey(at: $0) })
        let perTasks = Set(days.map { TodayTotalStore.todayByTaskKey(at: $0) })

        XCTAssertEqual(totals.count, days.count, "two different days shared a total key")
        XCTAssertEqual(perTasks.count, days.count, "two different days shared a per-task key")
        XCTAssertTrue(
            totals.isDisjoint(with: perTasks),
            "a total key collided with a per-task key: \(totals.intersection(perTasks))"
        )
    }

    func test_todayKey_forTwoDifferentDays_differs() throws {
        let day1 = try fixedDate(2026, 8, 1)
        let day2 = try fixedDate(2026, 8, 2)

        XCTAssertNotEqual(
            TodayTotalStore.todayKey(at: day1), TodayTotalStore.todayKey(at: day2)
        )
    }

    // MARK: - tracksPerTask (pure rule)

    func test_tracksPerTask_forNamedTaskAtOrAboveTheFiveSecondFloor_returnsTrue() {
        XCTAssertEqual(SessionLog.minimumLoggedSeconds, 5, "floor moved; update these cases")
        XCTAssertTrue(TodayTotalStore.tracksPerTask(task: "Writing", seconds: 5))
        XCTAssertTrue(TodayTotalStore.tracksPerTask(task: "Writing", seconds: 6))
        XCTAssertTrue(TodayTotalStore.tracksPerTask(task: "Writing", seconds: 1500))
        XCTAssertTrue(TodayTotalStore.tracksPerTask(task: "Writing", seconds: .max))
    }

    func test_tracksPerTask_forNamedTaskOneSecondBelowTheFloor_returnsFalse() {
        XCTAssertFalse(TodayTotalStore.tracksPerTask(task: "Writing", seconds: 4))
    }

    func test_tracksPerTask_forNamedTaskAtZeroOrNegativeSeconds_returnsFalse() {
        XCTAssertFalse(TodayTotalStore.tracksPerTask(task: "Writing", seconds: 0))
        XCTAssertFalse(TodayTotalStore.tracksPerTask(task: "Writing", seconds: -1))
        XCTAssertFalse(TodayTotalStore.tracksPerTask(task: "Writing", seconds: -3600))
        XCTAssertFalse(TodayTotalStore.tracksPerTask(task: "Writing", seconds: .min))
    }

    func test_tracksPerTask_forEmptyTaskName_returnsFalseEvenWellAboveTheFloor() {
        XCTAssertFalse(TodayTotalStore.tracksPerTask(task: "", seconds: 1500))
    }

    func test_tracksPerTask_forWhitespaceOnlyTaskNames_returnsFalse() {
        for blank in [" ", "   ", "\t", "\n", " \t\n ", "\r\n"] {
            XCTAssertFalse(
                TodayTotalStore.tracksPerTask(task: blank, seconds: 1500),
                "whitespace-only name \(blank.debugDescription) must not earn a bucket"
            )
        }
    }

    func test_tracksPerTask_forNameWithSurroundingWhitespaceButRealContent_returnsTrue() {
        XCTAssertTrue(TodayTotalStore.tracksPerTask(task: "  Writing  ", seconds: 5))
        XCTAssertTrue(TodayTotalStore.tracksPerTask(task: "\nWriting\n", seconds: 5))
    }

    /// Combined edges: the two clauses of the rule fail together, and the
    /// blank clause still fails alone at the exact floor value.
    func test_tracksPerTask_forBlankNameBelowAtAndAboveTheFloor_returnsFalseEveryTime() {
        XCTAssertFalse(TodayTotalStore.tracksPerTask(task: "   ", seconds: 4))
        XCTAssertFalse(
            TodayTotalStore.tracksPerTask(task: "   ", seconds: 5),
            "at the exact floor, a blank name must still disqualify on its own"
        )
        XCTAssertFalse(TodayTotalStore.tracksPerTask(task: "   ", seconds: 6))
    }

    func test_tracksPerTask_forNonLatinAndEmojiTaskNames_returnsTrue() {
        XCTAssertTrue(TodayTotalStore.tracksPerTask(task: "執筆", seconds: 5))
        XCTAssertTrue(TodayTotalStore.tracksPerTask(task: "🍅", seconds: 5))
    }

    // MARK: - init / load

    func test_init_againstAnEmptySuite_startsAtZeroWithNoPerTaskBuckets() throws {
        let store = makeStore(at: try fixedDate(2026, 8, 1))

        XCTAssertEqual(store.todaySeconds, 0)
        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
    }

    func test_init_withAnExistingTotalUnderTodaysKey_loadsIt() throws {
        let today = try fixedDate(2026, 8, 1)
        defaults.set(1234, forKey: TodayTotalStore.todayKey(at: today))

        let store = makeStore(at: today)

        XCTAssertEqual(store.todaySeconds, 1234)
    }

    func test_init_withAnExistingPerTaskBlobUnderTodaysKey_loadsIt() throws {
        let today = try fixedDate(2026, 8, 1)
        let blob = try JSONEncoder().encode(["Writing": 600, "Review": 300])
        defaults.set(blob, forKey: TodayTotalStore.todayByTaskKey(at: today))

        let store = makeStore(at: today)

        XCTAssertEqual(store.perTaskSecondsSnapshot, ["Writing": 600, "Review": 300])
    }

    func test_init_withAnEmptyPerTaskBlobObject_loadsAnEmptyMap() throws {
        let today = try fixedDate(2026, 8, 1)
        defaults.set(
            try JSONEncoder().encode([String: Int]()),
            forKey: TodayTotalStore.todayByTaskKey(at: today)
        )

        let store = makeStore(at: today)

        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
    }

    func test_init_whenOnlyAnotherDaysValuesArePresent_ignoresThem() throws {
        let yesterday = try fixedDate(2026, 7, 31)
        let today = try fixedDate(2026, 8, 1)
        defaults.set(9999, forKey: TodayTotalStore.todayKey(at: yesterday))
        defaults.set(
            try JSONEncoder().encode(["Old": 9999]),
            forKey: TodayTotalStore.todayByTaskKey(at: yesterday)
        )

        let store = makeStore(at: today)

        XCTAssertEqual(store.todaySeconds, 0, "yesterday's total leaked into today")
        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
    }

    func test_init_withMalformedPerTaskBlob_fallsBackToAnEmptyMapAndKeepsTheTotal() throws {
        let today = try fixedDate(2026, 8, 1)
        defaults.set(600, forKey: TodayTotalStore.todayKey(at: today))
        defaults.set(
            Data("this is not JSON".utf8),
            forKey: TodayTotalStore.todayByTaskKey(at: today)
        )

        let store = makeStore(at: today)

        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
        XCTAssertEqual(store.todaySeconds, 600, "a bad per-task blob must not lose the total")
    }

    func test_init_withPerTaskBlobOfTheWrongJSONShape_fallsBackToAnEmptyMap() throws {
        let today = try fixedDate(2026, 8, 1)
        // Valid JSON, wrong type: [String: String] where [String: Int] is expected.
        defaults.set(
            try JSONEncoder().encode(["Writing": "600"]),
            forKey: TodayTotalStore.todayByTaskKey(at: today)
        )

        let store = makeStore(at: today)

        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
    }

    func test_init_withPerTaskKeyHoldingANonDataValue_fallsBackToAnEmptyMap() throws {
        let today = try fixedDate(2026, 8, 1)
        defaults.set("not data at all", forKey: TodayTotalStore.todayByTaskKey(at: today))

        let store = makeStore(at: today)

        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
    }

    /// The total path has its own malformed-input case: `integer(forKey:)`
    /// coerces, so a non-numeric string must read as 0, not as garbage and
    /// not as a crash.
    func test_init_withANonNumericStringUnderTodaysTotalKey_readsAsZero() throws {
        let today = try fixedDate(2026, 8, 1)
        defaults.set("not a number", forKey: TodayTotalStore.todayKey(at: today))

        let store = makeStore(at: today)

        XCTAssertEqual(store.todaySeconds, 0)
    }

    func test_init_readsOnly_andWritesNoPomoKeyIntoTheSuiteAtAll() throws {
        let today = try fixedDate(2026, 8, 1)

        _ = makeStore(at: today)

        XCTAssertEqual(
            pomoKeysInSuite(), [],
            "constructing a store must not write anything; it wrote \(pomoKeysInSuite())"
        )
        XCTAssertNil(defaults.object(forKey: TodayTotalStore.todayKey(at: today)))
        XCTAssertNil(defaults.object(forKey: TodayTotalStore.todayByTaskKey(at: today)))
    }

    // MARK: - commit: accumulation

    func test_commit_acrossSeveralCommits_accumulatesInMemoryAndInDefaults() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 1500, task: "Writing")
        store.commit(seconds: 300, task: "Review")
        store.commit(seconds: 600, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 2400)
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: today)), 2400)
        XCTAssertEqual(store.perTaskSecondsSnapshot, ["Writing": 2100, "Review": 300])
    }

    func test_commit_thenReadingBackThroughAFreshStore_seesTheSameTotals() throws {
        let today = try fixedDate(2026, 8, 1)
        makeStore(at: today).commit(seconds: 1500, task: "Writing")

        let reloaded = makeStore(at: today)

        XCTAssertEqual(reloaded.todaySeconds, 1500)
        XCTAssertEqual(reloaded.perTaskSecondsSnapshot, ["Writing": 1500])
    }

    /// Also the positive control for `pomoKeysInSuite()`: if the domain
    /// readback silently returned nothing, this assertion fails, which is what
    /// keeps the "wrote nothing" assertions elsewhere from being vacuous.
    func test_commit_writesExactlyTheTwoKeysForToday_andThePerTaskBlobIsDecodableJSON() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 900, task: "Writing")

        XCTAssertEqual(
            pomoKeysInSuite(),
            [
                TodayTotalStore.todayByTaskKey(at: today),
                TodayTotalStore.todayKey(at: today),
            ].sorted(),
            "commit must write today's total and today's per-task blob, and nothing else"
        )
        let onDisk = try decodedPerTaskBlob(
            forKey: TodayTotalStore.todayByTaskKey(at: today)
        )
        XCTAssertEqual(onDisk, ["Writing": 900])
        XCTAssertEqual(onDisk, store.perTaskSecondsSnapshot)
    }

    // MARK: - commit: rejected input

    func test_commit_withZeroSeconds_isIgnoredAndWritesNothing() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 0, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 0)
        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
        XCTAssertEqual(pomoKeysInSuite(), [], "a zero-second commit must not create any key")
    }

    /// One second is the smallest accepted commit — the boundary immediately
    /// above the `> 0` guard, and still far below the per-task floor.
    func test_commit_withOneSecond_isAcceptedIntoTheTotalButEarnsNoBucket() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 1, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 1)
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: today)), 1)
        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
        XCTAssertEqual(
            pomoKeysInSuite(), [TodayTotalStore.todayKey(at: today)],
            "a sub-floor commit must not create the per-task blob at all"
        )
    }

    func test_commit_withNegativeSeconds_isIgnoredAndCannotShrinkAnExistingTotal() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        store.commit(seconds: 1500, task: "Writing")

        store.commit(seconds: -600, task: "Writing")
        store.commit(seconds: -1, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 1500, "a negative commit must never subtract")
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: today)), 1500)
        XCTAssertEqual(store.perTaskSecondsSnapshot, ["Writing": 1500])
    }

    // MARK: - commit: the per-task bucket filter

    func test_commit_atFourFiveAndSixSeconds_bucketsOnlyTheFiveAndSix_butTotalsAllThree() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 4, task: "four")
        store.commit(seconds: 5, task: "five")
        store.commit(seconds: 6, task: "six")

        XCTAssertEqual(store.todaySeconds, 15, "the grand total takes every positive commit")
        XCTAssertEqual(
            store.perTaskSecondsSnapshot, ["five": 5, "six": 6],
            "4s is below the 5s floor and must not get a bucket"
        )
        XCTAssertNil(store.perTaskSecondsSnapshot["four"])
    }

    func test_commit_withEmptyTaskName_addsToTheTotalButCreatesNoBucket() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 1500, task: "")

        XCTAssertEqual(store.todaySeconds, 1500)
        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
        XCTAssertNil(
            defaults.object(forKey: TodayTotalStore.todayByTaskKey(at: today)),
            "an unnamed commit must not write a per-task blob at all"
        )
    }

    func test_commit_withWhitespaceOnlyTaskName_addsToTheTotalButCreatesNoBucket() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 600, task: "   ")
        store.commit(seconds: 600, task: "\n\t")

        XCTAssertEqual(store.todaySeconds, 1200)
        XCTAssertEqual(store.perTaskSecondsSnapshot, [String: Int]())
        XCTAssertNil(defaults.object(forKey: TodayTotalStore.todayByTaskKey(at: today)))
    }

    func test_commit_withPaddedAndUnpaddedFormsOfOneTask_mergesIntoASingleTrimmedBucket() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 600, task: "Deep Work")
        store.commit(seconds: 300, task: "  Deep Work  ")
        store.commit(seconds: 100, task: "\nDeep Work\t")

        XCTAssertEqual(
            store.perTaskSecondsSnapshot, ["Deep Work": 1000],
            "padding must not fork the same task into several buckets"
        )
        XCTAssertEqual(store.perTaskSecondsSnapshot.count, 1)
    }

    func test_commit_withTasksDifferingOnlyByCase_keepsThemAsSeparateBuckets() throws {
        // Negative/regression: the rule trims, it does not case-fold. If this
        // ever starts merging, someone added a `.lowercased()` nobody asked for.
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.commit(seconds: 600, task: "Writing")
        store.commit(seconds: 300, task: "writing")

        XCTAssertEqual(store.perTaskSecondsSnapshot, ["Writing": 600, "writing": 300])
    }

    func test_commit_belowTheFloorForATaskThatAlreadyHasABucket_doesNotTopItUp() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        store.commit(seconds: 600, task: "Writing")

        store.commit(seconds: 4, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 604)
        XCTAssertEqual(
            store.perTaskSecondsSnapshot, ["Writing": 600],
            "a sub-floor commit must not reach an existing bucket either"
        )
    }

    // MARK: - resetToday

    func test_resetToday_zeroesTheGrandTotalButDeliberatelyLeavesPerTaskSecondsIntact() throws {
        // The asymmetry is intentional (see the doc comment on resetToday):
        // "Reset Today Total" wipes the headline number only; the per-task blob
        // is the only non-jsonl record of what the time went to.
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        store.commit(seconds: 1500, task: "Writing")
        store.commit(seconds: 300, task: "Review")

        store.resetToday()

        XCTAssertEqual(store.todaySeconds, 0)
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: today)), 0)
        XCTAssertEqual(
            store.perTaskSecondsSnapshot, ["Writing": 1500, "Review": 300],
            "resetToday must not touch perTaskSeconds"
        )
        XCTAssertEqual(
            try decodedPerTaskBlob(forKey: TodayTotalStore.todayByTaskKey(at: today)),
            ["Writing": 1500, "Review": 300],
            "resetToday must not touch the persisted per-task blob either"
        )
    }

    func test_resetToday_onAnUntouchedStore_persistsAnExplicitZero() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.resetToday()

        XCTAssertEqual(store.todaySeconds, 0)
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: today)), 0)
        XCTAssertEqual(
            pomoKeysInSuite(), [TodayTotalStore.todayKey(at: today)],
            "resetToday must write the total key only, never a per-task blob"
        )
    }

    func test_resetToday_calledTwice_isIdempotent() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        store.commit(seconds: 1500, task: "Writing")

        store.resetToday()
        store.resetToday()

        XCTAssertEqual(store.todaySeconds, 0)
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: today)), 0)
    }

    func test_commitAfterResetToday_accumulatesFromZeroAndIsSeenByAFreshStore() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        store.commit(seconds: 1500, task: "Writing")
        store.resetToday()

        store.commit(seconds: 600, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 600, "the reset total must not come back")
        XCTAssertEqual(makeStore(at: today).todaySeconds, 600)
    }

    // MARK: - Day rollover (the reason the clock is injected)

    func test_commitAfterMidnight_landsOnTheNewDaysKeyAndDoesNotAccumulateOntoDay1() throws {
        let day1 = try fixedDate(2026, 8, 1, hour: 22)
        let day2 = try fixedDate(2026, 8, 2, hour: 9)
        let clock = TestClock(day1)
        let store = makeStore(clock: clock)

        store.commit(seconds: 1500, task: "Writing")
        XCTAssertEqual(store.todaySeconds, 1500)

        clock.date = day2
        store.commit(seconds: 900, task: "Planning")

        XCTAssertEqual(store.todaySeconds, 900, "day 2 must start from day 2's stored value")
        XCTAssertNotEqual(
            store.todaySeconds, 2400,
            "day 1 and day 2 were silently merged into one total"
        )
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: day2)), 900)
    }

    func test_commitAfterMidnight_leavesDay1sStoredTotalExactlyAsItWas() throws {
        let day1 = try fixedDate(2026, 8, 1, hour: 22)
        let day2 = try fixedDate(2026, 8, 2, hour: 9)
        let clock = TestClock(day1)
        let store = makeStore(clock: clock)
        store.commit(seconds: 1500, task: "Writing")

        clock.date = day2
        store.commit(seconds: 900, task: "Planning")

        XCTAssertEqual(
            defaults.integer(forKey: TodayTotalStore.todayKey(at: day1)), 1500,
            "day 1's archived total was overwritten by a day 2 commit"
        )
    }

    /// The rollover boundary itself: one second apart, either side of the true
    /// local day boundary, rather than hours away from it.
    func test_commitOneSecondBeforeAndAtTheStartOfADay_splitsAcrossTheTwoDaysKeys() throws {
        let startOfAugust1 = try startOfLocalDay(2026, 8, 1)
        let lastSecondOfJuly31 = startOfAugust1.addingTimeInterval(-1)
        let clock = TestClock(lastSecondOfJuly31)
        let store = makeStore(clock: clock)

        store.commit(seconds: 1500, task: "Writing")
        clock.date = startOfAugust1
        store.commit(seconds: 900, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 900, "one second past midnight is a new day")
        XCTAssertEqual(defaults.integer(forKey: "pomo.today.2026-07-31"), 1500)
        XCTAssertEqual(defaults.integer(forKey: "pomo.today.2026-08-01"), 900)
        XCTAssertEqual(store.perTaskSecondsSnapshot, ["Writing": 900])
    }

    func test_perTaskBucketsAfterMidnight_startEmptyAndDay1sBlobIsPreserved() throws {
        let day1 = try fixedDate(2026, 8, 1, hour: 22)
        let day2 = try fixedDate(2026, 8, 2, hour: 9)
        let clock = TestClock(day1)
        let store = makeStore(clock: clock)
        store.commit(seconds: 1500, task: "Writing")

        clock.date = day2
        store.commit(seconds: 900, task: "Planning")

        XCTAssertEqual(
            store.perTaskSecondsSnapshot, ["Planning": 900],
            "day 1's buckets carried over into day 2"
        )
        XCTAssertEqual(
            try decodedPerTaskBlob(forKey: TodayTotalStore.todayByTaskKey(at: day1)),
            ["Writing": 1500]
        )
        XCTAssertEqual(
            try decodedPerTaskBlob(forKey: TodayTotalStore.todayByTaskKey(at: day2)),
            ["Planning": 900]
        )
    }

    func test_commitAfterMidnightOnADayThatAlreadyHasAStoredTotal_addsOntoThatDaysValue() throws {
        let day1 = try fixedDate(2026, 8, 1, hour: 22)
        let day2 = try fixedDate(2026, 8, 2, hour: 9)
        defaults.set(300, forKey: TodayTotalStore.todayKey(at: day2))
        let clock = TestClock(day1)
        let store = makeStore(clock: clock)
        store.commit(seconds: 1500, task: "Writing")

        clock.date = day2
        store.commit(seconds: 900, task: "Planning")

        XCTAssertEqual(store.todaySeconds, 1200, "day 2's pre-existing 300s was dropped")
    }

    /// The per-task side of the same corner: rolling onto a day whose blob
    /// already exists must merge into it, not replace it and not ignore it.
    func test_commitAfterMidnightOnADayThatAlreadyHasAPerTaskBlob_mergesIntoThatDaysBuckets()
        throws
    {
        let day1 = try fixedDate(2026, 8, 1, hour: 22)
        let day2 = try fixedDate(2026, 8, 2, hour: 9)
        defaults.set(
            try JSONEncoder().encode(["Email": 300, "Planning": 120]),
            forKey: TodayTotalStore.todayByTaskKey(at: day2)
        )
        let clock = TestClock(day1)
        let store = makeStore(clock: clock)
        store.commit(seconds: 1500, task: "Writing")

        clock.date = day2
        store.commit(seconds: 900, task: "Planning")

        XCTAssertEqual(
            store.perTaskSecondsSnapshot, ["Email": 300, "Planning": 1020],
            "day 2's stored buckets were dropped instead of merged"
        )
        XCTAssertEqual(
            try decodedPerTaskBlob(forKey: TodayTotalStore.todayByTaskKey(at: day2)),
            ["Email": 300, "Planning": 1020]
        )
    }

    func test_commitLaterOnTheSameDay_keepsAccumulatingAndDoesNotFalselyRollOver() throws {
        let morning = try fixedDate(2026, 8, 1, hour: 6)
        let evening = try fixedDate(2026, 8, 1, hour: 23)
        let clock = TestClock(morning)
        let store = makeStore(clock: clock)

        store.commit(seconds: 1500, task: "Writing")
        clock.date = evening
        store.commit(seconds: 900, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 2400, "the same local day must not roll over")
        XCTAssertEqual(store.perTaskSecondsSnapshot, ["Writing": 2400])
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: morning)), 2400)
        XCTAssertEqual(
            pomoKeysInSuite(),
            [
                TodayTotalStore.todayByTaskKey(at: morning),
                TodayTotalStore.todayKey(at: morning),
            ].sorted(),
            "a same-day commit must not create a second day's keys"
        )
    }

    func test_commitAfterTheClockGoesBackToAPreviousDay_reloadsThatDaysStoredTotal() throws {
        // Corner case: clock skew or a timezone change can move `now()`
        // backwards. The rollover guard compares keys, not ordering, so day 1
        // must be re-loaded, not restarted from zero.
        let day1 = try fixedDate(2026, 8, 1, hour: 22)
        let day2 = try fixedDate(2026, 8, 2, hour: 9)
        let clock = TestClock(day1)
        let store = makeStore(clock: clock)
        store.commit(seconds: 600, task: "Writing")

        clock.date = day2
        store.commit(seconds: 300, task: "Planning")
        clock.date = day1
        store.commit(seconds: 100, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 700, "day 1's stored 600s was not reloaded")
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: day1)), 700)
        XCTAssertEqual(
            defaults.integer(forKey: TodayTotalStore.todayKey(at: day2)), 300,
            "day 2's total must survive the clock moving back"
        )
        XCTAssertEqual(store.perTaskSecondsSnapshot, ["Writing": 700])
        XCTAssertEqual(
            try decodedPerTaskBlob(forKey: TodayTotalStore.todayByTaskKey(at: day2)),
            ["Planning": 300],
            "day 2's buckets must survive the clock moving back"
        )
    }

    func test_resetTodayAfterMidnight_zeroesOnlyTheNewDayAndLeavesDay1Intact() throws {
        let day1 = try fixedDate(2026, 8, 1, hour: 22)
        let day2 = try fixedDate(2026, 8, 2, hour: 9)
        let clock = TestClock(day1)
        let store = makeStore(clock: clock)
        store.commit(seconds: 1500, task: "Writing")

        clock.date = day2
        store.resetToday()

        XCTAssertEqual(store.todaySeconds, 0)
        XCTAssertEqual(defaults.integer(forKey: TodayTotalStore.todayKey(at: day2)), 0)
        XCTAssertEqual(
            defaults.integer(forKey: TodayTotalStore.todayKey(at: day1)), 1500,
            "resetting after midnight must not wipe yesterday's archived total"
        )
    }

    func test_commitAcrossAMonthBoundary_usesTheNewMonthsKey() throws {
        let lastDayOfJuly = try fixedDate(2026, 7, 31, hour: 22)
        let firstDayOfAugust = try fixedDate(2026, 8, 1, hour: 9)
        let clock = TestClock(lastDayOfJuly)
        let store = makeStore(clock: clock)
        store.commit(seconds: 1500, task: "Writing")

        clock.date = firstDayOfAugust
        store.commit(seconds: 900, task: "Writing")

        XCTAssertEqual(store.todaySeconds, 900)
        XCTAssertEqual(defaults.integer(forKey: "pomo.today.2026-07-31"), 1500)
        XCTAssertEqual(defaults.integer(forKey: "pomo.today.2026-08-01"), 900)
    }

    func test_commitAcrossAYearBoundary_usesTheNewYearsKey() throws {
        let newYearsEve = try fixedDate(2025, 12, 31, hour: 22)
        let newYearsDay = try fixedDate(2026, 1, 1, hour: 9)
        let clock = TestClock(newYearsEve)
        let store = makeStore(clock: clock)
        store.commit(seconds: 1500, task: "Writing")

        clock.date = newYearsDay
        store.commit(seconds: 900, task: "Writing")

        XCTAssertEqual(defaults.integer(forKey: "pomo.today.2025-12-31"), 1500)
        XCTAssertEqual(defaults.integer(forKey: "pomo.today.2026-01-01"), 900)
    }

    // MARK: - forceSet (QA seam)

    func test_forceSet_changesThePublishedTotalButPersistsNothing() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)

        store.forceSet(4320)

        XCTAssertEqual(store.todaySeconds, 4320)
        XCTAssertEqual(
            pomoKeysInSuite(), [], "a QA forceSet must never write to the defaults suite"
        )
        XCTAssertEqual(
            makeStore(at: today).todaySeconds, 0,
            "a forced value must not survive into a fresh store"
        )
    }

    func test_forceSet_afterRealCommits_leavesThePersistedTotalUntouched() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        store.commit(seconds: 1500, task: "Writing")

        store.forceSet(0)

        XCTAssertEqual(store.todaySeconds, 0)
        XCTAssertEqual(
            defaults.integer(forKey: TodayTotalStore.todayKey(at: today)), 1500,
            "forceSet must not overwrite the committed total on disk"
        )
    }

    // MARK: - ObservableObject contract (the pill's Today readout depends on it)

    func test_commit_notifiesObservers() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        var notifications = 0
        let cancellable = store.objectWillChange.sink { _ in notifications += 1 }
        defer { cancellable.cancel() }

        store.commit(seconds: 1500, task: "Writing")

        XCTAssertGreaterThanOrEqual(notifications, 1)
        XCTAssertEqual(store.todaySeconds, 1500)
    }

    func test_commit_withZeroSeconds_notifiesNobody() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        var notifications = 0
        let cancellable = store.objectWillChange.sink { _ in notifications += 1 }
        defer { cancellable.cancel() }

        store.commit(seconds: 0, task: "Writing")

        XCTAssertEqual(notifications, 0, "a rejected commit must not churn the UI")
    }

    func test_commit_withNegativeSeconds_notifiesNobody() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        var notifications = 0
        let cancellable = store.objectWillChange.sink { _ in notifications += 1 }
        defer { cancellable.cancel() }

        store.commit(seconds: -1500, task: "Writing")

        XCTAssertEqual(notifications, 0, "a rejected commit must not churn the UI")
    }

    func test_resetToday_notifiesObservers() throws {
        let today = try fixedDate(2026, 8, 1)
        let store = makeStore(at: today)
        store.commit(seconds: 1500, task: "Writing")
        var notifications = 0
        let cancellable = store.objectWillChange.sink { _ in notifications += 1 }
        defer { cancellable.cancel() }

        store.resetToday()

        XCTAssertGreaterThanOrEqual(notifications, 1)
    }

    // MARK: - Isolation guard (regression: never touch the user's real data)

    func test_theStoreUnderTest_writesOnlyIntoItsOwnSuiteAndNotIntoStandardDefaults() throws {
        // Read-only against `.standard`; nothing here ever writes to it.
        let today = try fixedDate(2026, 8, 1)
        let key = TodayTotalStore.todayKey(at: today)
        let standardBefore = UserDefaults.standard.object(forKey: key) as? Int

        makeStore(at: today).commit(seconds: 1500, task: "Writing")

        XCTAssertEqual(defaults.integer(forKey: key), 1500)
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? Int, standardBefore,
            "the test suite leaked into the standard domain"
        )
    }
}
