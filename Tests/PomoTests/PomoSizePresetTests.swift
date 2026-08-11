import XCTest
import AppKit
@testable import Pomo

/// `PomoSize` is the window-size preset vocabulary. Three separate contracts
/// live on it, all of them silent when broken:
///   1. `next`/`previous` SATURATE at the ends. If either ever wrapped, a
///      keyboard bump at Large would snap the pill to Small — a plausible
///      value, no crash, no warning.
///   2. `rawValue` is persisted (`pomo.window.size`) and round-tripped through
///      the ⚙ Size submenu's `representedObject`. A rename silently resets
///      every user to the `.medium` fallback.
///   3. `pillSize` is derived from `PillLayout`, never a hand-written table.
///
/// `PomoSizeController` is deliberately NOT touched here — it is a singleton
/// bound to the standard UserDefaults domain. Nothing in this file reads the
/// filesystem, UserDefaults, the clock or any singleton: `pillSize` resolves
/// through `PillLayout` → `Tokens.typeScale` / `spacingScale` / `segScale` /
/// `Decor` constants, all pure arithmetic. (`Tokens.Decor.accentGreenRGB` is
/// the one member backed by `AccentColorStore.shared`, and no layout value
/// reads it.)
final class PomoSizePresetTests: XCTestCase {

    // MARK: - next(after:) — every transition, including the saturating end

    func test_nextAfterSmall_isMedium() {
        XCTAssertEqual(PomoSize.next(after: .small), .medium)
    }

    func test_nextAfterMedium_isLarge() {
        XCTAssertEqual(PomoSize.next(after: .medium), .large)
    }

    /// BOUNDARY / MAX: the documented "saturate" behaviour.
    func test_nextAfterLarge_staysLarge_becauseTheTopEndSaturates() {
        XCTAssertEqual(PomoSize.next(after: .large), .large)
    }

    /// NEGATIVE: bumping up at the maximum must NOT wrap around to the
    /// minimum. Asserted separately from the equality above because "returns
    /// large" and "does not return small" fail for different reasons — an
    /// accidental `.allCases[(i + 1) % count]` rewrite satisfies neither.
    func test_nextAfterLarge_neverWrapsAroundToSmallOrMedium() {
        XCTAssertNotEqual(PomoSize.next(after: .large), .small)
        XCTAssertNotEqual(PomoSize.next(after: .large), .medium)
    }

    /// CORNER (repeated application at the ceiling): bumping up from any size
    /// more times than there are sizes lands on `.large` and stays there.
    func test_bumpingUpRepeatedlyFromAnySize_convergesOnLargeAndStaysThere() {
        for start in PomoSize.allCases {
            var size = start
            for _ in 0..<(PomoSize.allCases.count + 3) {
                size = PomoSize.next(after: size)
            }
            XCTAssertEqual(size, .large, "repeated next(after:) from \(start) did not settle on .large")
        }
    }

    // MARK: - previous(before:) — every transition, including the saturating end

    func test_previousBeforeLarge_isMedium() {
        XCTAssertEqual(PomoSize.previous(before: .large), .medium)
    }

    func test_previousBeforeMedium_isSmall() {
        XCTAssertEqual(PomoSize.previous(before: .medium), .small)
    }

    /// BOUNDARY / MIN: the documented "saturate" behaviour.
    func test_previousBeforeSmall_staysSmall_becauseTheBottomEndSaturates() {
        XCTAssertEqual(PomoSize.previous(before: .small), .small)
    }

    /// NEGATIVE: bumping down at the minimum must NOT wrap around to the
    /// maximum.
    func test_previousBeforeSmall_neverWrapsAroundToLargeOrMedium() {
        XCTAssertNotEqual(PomoSize.previous(before: .small), .large)
        XCTAssertNotEqual(PomoSize.previous(before: .small), .medium)
    }

    /// CORNER (repeated application at the floor).
    func test_bumpingDownRepeatedlyFromAnySize_convergesOnSmallAndStaysThere() {
        for start in PomoSize.allCases {
            var size = start
            for _ in 0..<(PomoSize.allCases.count + 3) {
                size = PomoSize.previous(before: size)
            }
            XCTAssertEqual(size, .small, "repeated previous(before:) from \(start) did not settle on .small")
        }
    }

    // MARK: - next/previous as a pair

    /// Away from the ceiling, up-then-down returns you exactly where you were.
    /// `.large` is excluded on purpose: `next(after: .large)` saturates, so
    /// `previous` then legitimately steps down to `.medium`.
    func test_steppingUpThenDownFromSmallOrMedium_returnsTheOriginalSize() {
        for size in [PomoSize.small, .medium] {
            XCTAssertEqual(PomoSize.previous(before: PomoSize.next(after: size)), size)
        }
    }

    /// Away from the floor, down-then-up returns you exactly where you were.
    /// `.small` is excluded for the mirror-image reason.
    func test_steppingDownThenUpFromMediumOrLarge_returnsTheOriginalSize() {
        for size in [PomoSize.medium, .large] {
            XCTAssertEqual(PomoSize.next(after: PomoSize.previous(before: size)), size)
        }
    }

    /// REGRESSION guard against a case being added to the enum without the
    /// step functions being updated: both must agree with `allCases` order,
    /// clamped at both ends. (The `switch`es in `next`/`previous` are
    /// exhaustive, so a new case also breaks compilation — this catches the
    /// other half, an arm that compiles but returns the wrong neighbour.)
    func test_stepFunctions_matchAllCasesOrderClampedAtBothEnds() {
        let cases = PomoSize.allCases
        XCTAssertFalse(cases.isEmpty)
        for (index, size) in cases.enumerated() {
            let expectedNext = cases[min(index + 1, cases.count - 1)]
            let expectedPrevious = cases[max(index - 1, 0)]
            XCTAssertEqual(PomoSize.next(after: size), expectedNext,
                           "next(after: .\(size.rawValue)) disagrees with allCases order")
            XCTAssertEqual(PomoSize.previous(before: size), expectedPrevious,
                           "previous(before: .\(size.rawValue)) disagrees with allCases order")
        }
    }

    // MARK: - displayName

    func test_displayNameForEachSize_isTheTitleCasedMenuLabel() {
        XCTAssertEqual(PomoSize.small.displayName, "Small")
        XCTAssertEqual(PomoSize.medium.displayName, "Medium")
        XCTAssertEqual(PomoSize.large.displayName, "Large")
    }

    /// The ⚙ Size submenu builds one item per case titled `displayName`; two
    /// cases sharing a label would render an unpickable duplicate row.
    func test_displayNames_areNonEmptyTrimmedAndDistinctAcrossAllSizes() {
        let names = PomoSize.allCases.map(\.displayName)
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(Set(names).count, PomoSize.allCases.count)
    }

    // MARK: - rawValue: persistence + menu round-trip

    /// The raw values are written to UserDefaults ("pomo.window.size") and
    /// carried as the Size menu item's `representedObject`. Renaming one silently
    /// drops the user back to the `.medium` fallback on next launch.
    func test_rawValueForEachSize_isTheLowercasePersistedToken() {
        XCTAssertEqual(PomoSize.small.rawValue, "small")
        XCTAssertEqual(PomoSize.medium.rawValue, "medium")
        XCTAssertEqual(PomoSize.large.rawValue, "large")
    }

    func test_everySize_roundTripsThroughItsRawValue_asTheSizeMenuDoes() {
        for size in PomoSize.allCases {
            XCTAssertEqual(PomoSize(rawValue: size.rawValue), size)
        }
    }

    /// EMPTY / NIL / MALFORMED / CASE SENSITIVITY. `PomoSizeController` reads
    /// the stored string and falls back to `.medium` on nil, so an
    /// over-permissive lookup here (or a mismatched case) is the difference
    /// between "restores the user's size" and "silently resets it".
    func test_unknownEmptyOrDifferentlyCasedRawValues_returnNil_soCallersCanFallBack() {
        XCTAssertNil(PomoSize(rawValue: ""))
        XCTAssertNil(PomoSize(rawValue: " "))
        XCTAssertNil(PomoSize(rawValue: "Small"))
        XCTAssertNil(PomoSize(rawValue: "SMALL"))
        XCTAssertNil(PomoSize(rawValue: " small"))
        XCTAssertNil(PomoSize(rawValue: "small "))
        XCTAssertNil(PomoSize(rawValue: "extraLarge"))
        XCTAssertNil(PomoSize(rawValue: "0"))
    }

    /// The submenu is built by iterating `allCases`, so its order IS this
    /// order. Users read it as a size ladder; a reshuffle would put Large
    /// between Small and Medium with nothing failing.
    func test_allCases_isOrderedSmallestToLargest_matchingTheSizeSubmenu() {
        XCTAssertEqual(PomoSize.allCases, [.small, .medium, .large])
    }

    // MARK: - pillSize

    /// The FROZEN S/M/L pill table (the spec's §4 numbers, re-derived from the
    /// live tokens at the time of writing). This is the only assertion in the
    /// file that pins actual dimensions rather than a relationship, and it is
    /// what makes the derivation test below mean something: without it, every
    /// `pillSize` assertion could be satisfied by a `PillLayout` that had
    /// itself gone wrong.
    ///
    /// If you deliberately retune a token, this table is SUPPOSED to fail —
    /// update it in the same commit and say so.
    func test_pillSizeForEachPreset_matchesTheFrozenSMLDimensionTable() {
        XCTAssertEqual(PomoSize.small.pillSize,  NSSize(width: 238, height: 82))
        XCTAssertEqual(PomoSize.medium.pillSize, NSSize(width: 296, height: 98))
        XCTAssertEqual(PomoSize.large.pillSize,  NSSize(width: 352, height: 116))
    }

    /// The documented contract: a preset's canonical size is its 2-digit
    /// baseline (minutes < 100) computed by `PillLayout`, never a written-down
    /// table that could drift from what the pill actually renders. Paired with
    /// the frozen table above, so "stays derived" and "derives the right
    /// numbers" are two separate failures.
    func test_pillSizeForEachPreset_staysDerivedFromThePillLayoutTwoDigitBaseline() {
        for size in PomoSize.allCases {
            XCTAssertEqual(size.pillSize, PillLayout(sizeClass: size, minuteDigits: 2).pillSize,
                           "\(size.rawValue).pillSize is no longer derived from PillLayout")
        }
    }

    /// NEGATIVE: the preset must be the 2-digit baseline specifically, not
    /// whatever the widest (3-digit) layout would be — otherwise every window
    /// would be sized for a 100+ minute countdown it almost never shows.
    func test_pillSizeForEachPreset_isNarrowerThanTheThreeDigitLayout() {
        for size in PomoSize.allCases {
            let threeDigit = PillLayout(sizeClass: size, minuteDigits: 3).pillSize
            XCTAssertLessThan(size.pillSize.width, threeDigit.width,
                              "\(size.rawValue).pillSize looks like the 3-digit layout, not the 2-digit baseline")
        }
    }

    /// Crossing the 100-minute threshold widens the pill and must leave its
    /// HEIGHT alone — the countdown's own line height is set by the type scale,
    /// not the digit count. A height that moved with the digit count would make
    /// the pill jump vertically mid-session on a 100+ minute custom duration.
    func test_theThreeDigitLayout_isTallerByNothing_onlyWider() {
        for size in PomoSize.allCases {
            let two = PillLayout(sizeClass: size, minuteDigits: 2).pillSize
            let three = PillLayout(sizeClass: size, minuteDigits: 3).pillSize
            XCTAssertEqual(two.height, three.height,
                           "\(size.rawValue) changes height with digit count — the pill would jump vertically")
            XCTAssertNotEqual(two.width, three.width,
                              "\(size.rawValue) does not widen for a 3-digit countdown — it would clip")
        }
    }

    /// The whole point of three presets: bigger preset, bigger pill — in BOTH
    /// dimensions. A token edit that grew width while shrinking height (or left
    /// two presets identical) would produce a "Large" that is not larger, with
    /// nothing to catch it but the eye.
    func test_pillSize_increasesStrictlyInBothDimensionsFromSmallToMediumToLarge() {
        let sizes = PomoSize.allCases.map(\.pillSize)
        for (a, b) in zip(sizes, sizes.dropFirst()) {
            XCTAssertLessThan(a.width, b.width, "pill width is not strictly increasing: \(sizes)")
            XCTAssertLessThan(a.height, b.height, "pill height is not strictly increasing: \(sizes)")
        }
        // Spelled out for the two ends as well, so a failure names the pair.
        XCTAssertLessThan(PomoSize.small.pillSize.width, PomoSize.large.pillSize.width)
        XCTAssertLessThan(PomoSize.small.pillSize.height, PomoSize.large.pillSize.height)
    }

    func test_pillSizeForEachPreset_hasStrictlyPositiveFiniteDimensions() {
        for size in PomoSize.allCases {
            let pill = size.pillSize
            XCTAssertGreaterThan(pill.width, 0, "\(size.rawValue) pill width")
            XCTAssertGreaterThan(pill.height, 0, "\(size.rawValue) pill height")
            XCTAssertTrue(pill.width.isFinite && pill.height.isFinite,
                          "\(size.rawValue) pill size is not finite: \(pill)")
        }
    }

    /// `PillLayout.ceil2` is documented as "the only rounding point in the
    /// whole system", so every pill dimension lands on the 2pt grid — at both
    /// digit counts. A fractional width is how the VEV mask ends up centred on
    /// a half pixel and the glass edge goes soft, which no other assertion here
    /// would notice.
    func test_everyPillDimension_landsOnTheTwoPointGrid_atBothDigitCounts() {
        for size in PomoSize.allCases {
            for digits in [2, 3] {
                let pill = PillLayout(sizeClass: size, minuteDigits: digits).pillSize
                XCTAssertEqual(pill.width.truncatingRemainder(dividingBy: 2), 0,
                               "\(size.rawValue)/\(digits)-digit width \(pill.width) is off the 2pt grid")
                XCTAssertEqual(pill.height.truncatingRemainder(dividingBy: 2), 0,
                               "\(size.rawValue)/\(digits)-digit height \(pill.height) is off the 2pt grid")
            }
        }
    }
}
