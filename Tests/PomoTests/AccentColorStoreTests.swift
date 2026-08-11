import XCTest
@testable import Pomo

/// Tests for `AccentColorStore.parse`, `.format`, `.defaultRGB` and
/// `.defaultsKey` — the pure string <-> RGB rules behind the "Gauge Color…"
/// dialog.
///
/// Deliberately touches nothing else. Every member referenced here is `static`,
/// so these tests read no files, no `UserDefaults` domain and no environment,
/// and never construct `AccentColorStore.shared` (which is the only member that
/// reads `UserDefaults.standard` and `ProcessInfo.environment`). Swift
/// initialises each `static let` independently and lazily, so naming
/// `defaultRGB` or `defaultsKey` does not drag `shared` in.
///
/// Colours are asserted in 0-255 space (`channel * 255`) because that is the
/// unit the dialog, the stored string and the bug reports all speak in; a
/// one-unit error is 1/255 ≈ 0.0039 in the returned representation, far above
/// the 1e-9 tolerance used here.
///
/// No shared mutable state, no `setUp`/`tearDown`, no clock, locale or
/// timezone: `Int(String)` and `Int` interpolation are locale-independent, so
/// every test is order-independent and machine-independent.
final class AccentColorStoreParseTests: XCTestCase {

    // MARK: - Assertion helpers

    private func assertParses(
        _ input: String,
        toRGB255 expected: (Int, Int, Int),
        _ note: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let got = AccentColorStore.parse(input) else {
            XCTFail(
                "parse(\(input.debugDescription)) returned nil; expected \(expected). \(note)",
                file: file, line: line
            )
            return
        }
        XCTAssertEqual(
            got.0 * 255, Double(expected.0), accuracy: 1e-9,
            "red channel of parse(\(input.debugDescription)). \(note)", file: file, line: line
        )
        XCTAssertEqual(
            got.1 * 255, Double(expected.1), accuracy: 1e-9,
            "green channel of parse(\(input.debugDescription)). \(note)", file: file, line: line
        )
        XCTAssertEqual(
            got.2 * 255, Double(expected.2), accuracy: 1e-9,
            "blue channel of parse(\(input.debugDescription)). \(note)", file: file, line: line
        )
    }

    /// Records a real assertion on both branches. An earlier version of this
    /// helper returned early when `parse` produced nil, which meant a passing
    /// rejection test finished having recorded no assertion at all.
    private func assertRejects(
        _ input: String,
        _ note: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let got = AccentColorStore.parse(input)
        let described = got.map { "(\($0.0 * 255), \($0.1 * 255), \($0.2 * 255)) in 0-255 space" }
            ?? "nil"
        XCTAssertNil(
            got.map { [$0.0, $0.1, $0.2] },
            "parse(\(input.debugDescription)) returned \(described); it must return nil "
                + "so the caller can beep and change nothing. \(note)",
            file: file, line: line
        )
    }

    // MARK: - Happy path: hex

    func test_parse_sixDigitUppercaseHexWithoutHash_returnsThatColour() {
        assertParses("FF0000", toRGB255: (255, 0, 0))
        assertParses("00A796", toRGB255: (0, 167, 150))
    }

    func test_parse_sixDigitHexWithHashPrefix_returnsSameColourAsWithoutPrefix() {
        assertParses("#00A796", toRGB255: (0, 167, 150), "the '#' is optional, not part of the value")
        assertParses("#FF0000", toRGB255: (255, 0, 0))
    }

    func test_parse_lowercaseHex_returnsSameColourAsUppercase() {
        assertParses("ff00ff", toRGB255: (255, 0, 255))
        assertParses("#00a796", toRGB255: (0, 167, 150))
    }

    func test_parse_mixedCaseHex_returnsThatColour() {
        assertParses("AbCdEf", toRGB255: (171, 205, 239), "case must not affect any nibble")
    }

    func test_parse_hexChannelsAreOrderedRedGreenBlue() {
        assertParses("010203", toRGB255: (1, 2, 3), "byte order must be RR GG BB, not reversed")
    }

    // MARK: - Happy path: "R,G,B"

    func test_parse_canonicalCommaTriple_returnsThatColour() {
        assertParses("0,167,96", toRGB255: (0, 167, 96))
    }

    func test_parse_commaTripleWithSurroundingAndInteriorSpaces_returnsSameColourAsCanonical() {
        assertParses("  0 , 167 , 96  ", toRGB255: (0, 167, 96), "whitespace tolerant per the doc comment")
        assertParses("0, 167, 96", toRGB255: (0, 167, 96))
        assertParses("0,167 ,96", toRGB255: (0, 167, 96))
    }

    func test_parse_commaTriplePaddedWithTabsAndNewlines_returnsSameColourAsCanonical() {
        assertParses("\t0,167,96\n", toRGB255: (0, 167, 96), "trimming covers newlines, not just spaces")
    }

    func test_parse_hexPaddedWithWhitespace_returnsSameColourAsTrimmedHex() {
        assertParses(" FF0000 ", toRGB255: (255, 0, 0))
        assertParses("  #FFFFFF  ", toRGB255: (255, 255, 255))
    }

    // MARK: - Boundary, off-by-one, min and max

    func test_parse_hexAllZeros_returnsBlackAtTheMinimum() {
        assertParses("000000", toRGB255: (0, 0, 0))
    }

    func test_parse_hexAllF_returnsWhiteAtTheMaximum() {
        assertParses("ffffff", toRGB255: (255, 255, 255))
        assertParses("FFFFFF", toRGB255: (255, 255, 255))
    }

    func test_parse_commaTripleAtMinAndMaxComponents_isAccepted() {
        assertParses("0,0,0", toRGB255: (0, 0, 0), "0 is inside the inclusive 0...255 range")
        assertParses("255,255,255", toRGB255: (255, 255, 255), "255 is inside the inclusive 0...255 range")
    }

    func test_parse_componentOneAboveMax_returnsNilInEveryPosition() {
        assertRejects("256,0,0", "256 is one past the inclusive upper bound (red)")
        assertRejects("0,256,0", "256 is one past the inclusive upper bound (green)")
        assertRejects("0,0,256", "256 is one past the inclusive upper bound (blue)")
    }

    func test_parse_componentOneBelowMin_returnsNilInEveryPosition() {
        assertRejects("-1,0,0", "-1 is one below the inclusive lower bound (red)")
        assertRejects("0,-1,0", "-1 is one below the inclusive lower bound (green)")
        assertRejects("0,0,-1", "-1 is one below the inclusive lower bound (blue)")
    }

    func test_parse_componentFarOutOfRange_returnsNil() {
        assertRejects("999,0,0", "well past the upper bound")
        assertRejects("0,0,99999999999999999999", "wider than Int, so Int(_:) itself returns nil")
    }

    func test_parse_hexOfFiveOrSevenDigits_returnsNil() {
        assertRejects("FF000", "five hex digits is one short of six")
        assertRejects("FF00000", "seven hex digits is one past six")
        assertRejects("#12345", "five digits after the '#'")
        assertRejects("#1234567", "seven digits after the '#'")
    }

    /// Named for what it actually pins, not for a distinction the code does not
    /// draw. Every ASCII hex digit is exactly one UTF-8 byte and one Unicode
    /// scalar, so once `isHexDigit && isASCII` holds, Character count, scalar
    /// count and byte count all agree — swapping `hex.count` for
    /// `hex.utf8.count` is an equivalent mutation (verified: the whole suite
    /// still passed with it applied). What these two inputs pin is the
    /// rejection itself: a length check alone must never be enough to admit a
    /// string whose Characters are not ASCII hex digits.
    func test_parse_multiByteAndMultiScalarStringsNearSixLong_areRejected() {
        assertRejects("ＦＦ", "two Characters but six UTF-8 bytes — a length-only check would admit it")
        assertRejects(
            "FF00e\u{0301}0",
            "six Characters but seven Unicode scalars; the combining sequence is not a hex digit"
        )
    }

    // MARK: - Empty, nil-ish and missing input

    func test_parse_emptyString_returnsNil() {
        assertRejects("", "the dialog treats empty as 'revert to default' before it ever calls parse")
    }

    func test_parse_whitespaceOnlyString_returnsNil() {
        assertRejects("   ", "trims to empty")
        assertRejects("\n\t ", "trims to empty")
    }

    func test_parse_hashWithNothingAfterIt_returnsNil() {
        assertRejects("#", "no digits follow the prefix")
    }

    func test_parse_commaTripleWithMissingThirdComponent_returnsNil() {
        assertRejects("0,167", "only two components")
        assertRejects("0", "only one component")
    }

    func test_parse_commaTripleWithEmptyComponent_returnsNil() {
        assertRejects("1,,2", "the middle component is missing")
        assertRejects(",,", "no components at all")
        assertRejects(",167,96", "leading component missing")
    }

    // MARK: - Invalid and malformed input

    func test_parse_nonNumericComponents_returnNil() {
        assertRejects("a,b,c", "letters are not decimal components")
        assertRejects("r,g,b", "the placeholder text itself must not parse")
        assertRejects("0,green,96", "one bad component poisons the whole triple")
    }

    func test_parse_fractionalComponents_returnNil() {
        assertRejects("0.0,167,96", "Int(_:) rejects a decimal point — no silent truncation to 0")
        assertRejects("0,167.5,96", "Int(_:) rejects a decimal point")
    }

    func test_parse_hexWithNonHexLetters_returnsNil() {
        assertRejects("GGGGGG", "'G' is not a hex digit")
        assertRejects("00FF0G", "one bad nibble at the end must reject the whole string")
        assertRejects("0x00FF00", "an 0x literal is eight characters and not all hex digits")
    }

    func test_parse_fourOrTwoComponents_returnNil() {
        assertRejects("1,2,3,4", "four components")
        assertRejects("1,2", "two components")
    }

    /// The over-permissive-validator case, and the only thing that pins the
    /// `parts.count == 3` guard separately from the `ints.count == 3` guard
    /// behind it. `"1,2,3,4"` above does not: four numeric components are
    /// rejected downstream either way. Relaxing the first guard to `>= 3` is
    /// only observable when the surplus components are not numbers, because
    /// `compactMap` then silently drops them and leaves exactly three ints — a
    /// plausible wrong colour with nothing to signal it. Verified: with
    /// `parts.count >= 3` every other test in this file still passed and
    /// `"1,2,3,x"` returned (1,2,3).
    func test_parse_surplusNonNumericComponentsAreNotSilentlyDropped() {
        assertRejects("1,2,3,x", "compactMap would drop the 'x' and leave a plausible three-int triple")
        assertRejects("0,167,96,rgba", "a stray trailing token must reject, not be discarded")
        assertRejects("x,0,167,96", "the surplus component is leading here")
        assertRejects("1,2,3,x,y", "five components, exactly three of which survive compactMap")
    }

    // MARK: - Corner cases (two edges at once)

    func test_parse_sixCharacterCommaTripleIsReadAsRGBNotHex() {
        assertParses(
            "12,3,4", toRGB255: (12, 3, 4),
            "exactly six characters, so it reaches the hex length check first; the commas must send it to the R,G,B branch"
        )
    }

    func test_parse_sixDigitAllNumericStringIsReadAsHexNotDecimal() {
        assertParses(
            "255000", toRGB255: (37, 80, 0),
            "0x255000 — a bare six-digit string is hex by definition, since the R,G,B form requires commas"
        )
    }

    func test_parse_hexWithHashAndWhitespaceAndLowercaseTogether_returnsThatColour() {
        assertParses(" #00a796\n", toRGB255: (0, 167, 150), "prefix, padding and case all at once")
    }

    // MARK: - Fullwidth / IME input (the silent-wrong-colour case)

    // The dialog's own prompt is Japanese, so an IME left in fullwidth mode
    // types exactly these. `Character.isHexDigit` is Unicode-aware and says
    // yes to all of them; only the `isASCII` conjunct rejects them.

    func test_parse_fullwidthHexDigits_returnsNilRatherThanBlack() {
        assertRejects(
            "ＦＦ００００",
            "fullwidth hex digits: the pre-fix parser returned black (0,0,0) here with no error"
        )
    }

    func test_parse_mixedWidthHexDigits_returnsNilRatherThanAPlausibleWrongColour() {
        assertRejects(
            "00A79６",
            "one fullwidth '６': the pre-fix parser returned (0,10,121), a wrong colour with no hint anything failed"
        )
    }

    func test_parse_fullwidthHexWithHashPrefix_returnsNil() {
        assertRejects("#ＦＦ００００", "ASCII '#' followed by fullwidth digits")
    }

    func test_parse_fullwidthHashPrefix_returnsNil() {
        assertRejects("＃FF0000", "U+FF03 is not the '#' the parser strips, so seven characters remain")
    }

    func test_parse_fullwidthDigitsInCommaTriple_returnsNil() {
        assertRejects("0,１６７,96", "Int(_:) is ASCII-only; a fullwidth component must not silently become 0")
        assertRejects("１２,3,4", "fullwidth leading component")
    }

    func test_parse_fullwidthCommaSeparators_returnNil() {
        assertRejects("0，167，96", "U+FF0C is not the ASCII ',' the parser splits on")
    }

    // MARK: - Regression: leading sign accepted by UInt64(_:radix:)

    // `FixedWidthInteger.init?(_:radix:)` permits one leading sign, so a
    // six-character string that starts with '+' or '-' parsed after Scanner
    // was replaced. Each of the five inputs below is a measured regression
    // from commit 347f622 ("Restore the hex parser's character-class guard").
    // Reachable from the Gauge Color… dialog: the field has no formatter and
    // the prompt only trims whitespace.

    func test_regression_plusPrefixedSixCharHex_returnsNil() {
        assertRejects("+FF000", "regression: parsed as (15,240,0) once Scanner was replaced by UInt64(_:radix:)")
    }

    func test_regression_minusPrefixedAllZeroHex_returnsNilRatherThanBlack() {
        assertRejects(
            "-00000",
            "regression: parsed as (0,0,0) — turned the gauge pure black and persisted \"0,0,0\""
        )
    }

    func test_regression_plusPrefixedSixCharNumericHex_returnsNil() {
        assertRejects("+12345", "regression: parsed as (1,35,69)")
    }

    func test_regression_hashThenPlusPrefixedHex_returnsNil() {
        assertRejects("#+12345", "regression: the '#' is stripped first, so this parsed as (1,35,69) too")
    }

    func test_regression_whitespacePaddedPlusPrefixedHex_returnsNil() {
        assertRejects(
            "  +12345  ",
            "regression: trimming happens before the length check, so padding did not save it — parsed as (1,35,69)"
        )
    }

    func test_regression_anySignPrefixedSixCharacterStringIsRejected() {
        for input in ["+FF000", "-FF000", "+00000", "-00000", "+12345", "-12345", "+abcde", "-abcde",
                      "#+FF000", "#-00000", " -00000 ", "+FFFFF", "-FFFFF"] {
            assertRejects(input, "a sign must never count as one of the six hex digits")
        }
    }

    func test_parse_unicodeMinusSignPrefixedHex_returnsNil() {
        assertRejects("\u{2212}00000", "U+2212 MINUS SIGN, which an IME can produce, is not a hex digit either")
    }

    // MARK: - Negative: what parse must never do

    func test_parse_invalidInputNeverYieldsAColour() {
        let invalid = [
            "", "   ", "#", "##FF0000", "FF00", "FF0000FF", "+FF000", "-00000", "#+12345",
            "ＦＦ００００", "00A79６", "＃FF0000", "0，167，96", "GGGGGG", "0x00FF00",
            "1,2", "1,2,3,4", "1,2,3,x", "a,b,c", "0.0,167,96", "256,0,0", "-1,0,0", "0,167", "1,,2",
            "rgb(0,167,96)", "green", "#00A796;", "0;167;96", "0 167 96"
        ]
        for input in invalid {
            assertRejects(input, "invalid input must fail closed, never fall back to a colour")
        }
    }

    func test_parse_isPureAcrossRepeatedAndInterleavedCalls() {
        // Guards against any future caching/memoisation returning stale state,
        // and makes the suite independent of test execution order.
        let first = AccentColorStore.parse("0,167,96")
        assertRejects("nonsense", "sanity: an invalid call between two valid ones")
        let second = AccentColorStore.parse("0,167,96")
        assertParses("#00A796", toRGB255: (0, 167, 150))
        let third = AccentColorStore.parse("0,167,96")
        for (index, value) in [first, second, third].enumerated() {
            guard let value = value else {
                XCTFail("call #\(index + 1) of parse(\"0,167,96\") returned nil")
                continue
            }
            XCTAssertEqual(value.0 * 255, 0, accuracy: 1e-9, "call #\(index + 1) red")
            XCTAssertEqual(value.1 * 255, 167, accuracy: 1e-9, "call #\(index + 1) green")
            XCTAssertEqual(value.2 * 255, 96, accuracy: 1e-9, "call #\(index + 1) blue")
        }
    }

    // MARK: - Defaults

    /// `Tokens.Decor.accentGreenRGB` resolves to this whenever nothing is
    /// stored, so it is pinned directly in 0...1 space rather than only through
    /// `format` — otherwise a change to `defaultRGB` and a change to `format`
    /// could cancel each other out.
    func test_defaultRGB_isTheDocumentedGreenNormalisedToZeroThroughOne() {
        XCTAssertEqual(AccentColorStore.defaultRGB.0 * 255, 0, accuracy: 1e-9, "red of the default")
        XCTAssertEqual(AccentColorStore.defaultRGB.1 * 255, 167, accuracy: 1e-9, "green of the default")
        XCTAssertEqual(AccentColorStore.defaultRGB.2 * 255, 96, accuracy: 1e-9, "blue of the default")
    }

    /// The one literal in this file deliberately restated from the source: a
    /// persisted key is a compatibility contract, not an implementation detail.
    /// `set` writes under it and `init` reads it back, so renaming it neither
    /// throws nor warns — every colour a user has already saved just silently
    /// reverts to green on the next launch. Verified: renaming the key broke
    /// no other test in this file.
    ///
    /// Reading this constant is inert; it does not touch `UserDefaults`.
    func test_defaultsKey_matchesTheKeyAlreadyWrittenToDisk() {
        XCTAssertEqual(
            AccentColorStore.defaultsKey, "pomo.accent.rgb",
            "changing this key orphans every gauge colour users have already saved"
        )
    }

    // MARK: - format

    func test_format_minAndMaxTriple_producesTheCanonicalEndpointStrings() {
        XCTAssertEqual(AccentColorStore.format((0, 0, 0)), "0,0,0")
        XCTAssertEqual(AccentColorStore.format((1, 1, 1)), "255,255,255")
    }

    func test_format_defaultRGB_producesTheDocumentedDefaultString() {
        XCTAssertEqual(
            AccentColorStore.format(AccentColorStore.defaultRGB), "0,167,96",
            "167.0/255 * 255 must not drift to 166 through floating point"
        )
    }

    /// Pins "nearest" against "truncate", which is the reachable mistake.
    /// It does not try to pin away-from-zero against to-even: 127.5 rounds to
    /// 128 under both, and the only channel values `format` ever sees in
    /// production are exact k/255 from `parse` (or `defaultRGB`), which never
    /// land on a tie. Pinning a tie-break rule the app cannot reach would
    /// cement an accident rather than a contract.
    func test_format_roundsToNearestRatherThanTruncating() {
        XCTAssertEqual(
            AccentColorStore.format((0.5, 0.5, 0.5)), "128,128,128",
            "0.5 * 255 == 127.5; truncation would give 127"
        )
        XCTAssertEqual(
            AccentColorStore.format((0.999, 0.001, 0.5019607843137255)), "255,0,128",
            "254.745 rounds up to 255 and 0.255 rounds down to 0; truncation would give 254 and 0"
        )
    }

    func test_format_channelsAreEmittedInRedGreenBlueOrder() {
        XCTAssertEqual(AccentColorStore.format((1.0 / 255, 2.0 / 255, 3.0 / 255)), "1,2,3")
    }

    func test_format_ofAHexParsedColour_producesTheCommaTripleTheDialogShows() {
        // FloatingWindow seeds the Gauge Color… field with format(store.rgb),
        // so a hex input has to come back out in the "R,G,B" form.
        guard let parsed = AccentColorStore.parse("#00A796") else {
            return XCTFail("parse(\"#00A796\") returned nil")
        }
        XCTAssertEqual(AccentColorStore.format(parsed), "0,167,150")
    }

    /// `format` does not clamp. It is only ever handed `parse` output or
    /// `defaultRGB` in production, but if that ever changes the malformed
    /// string must fail closed rather than round-trip into a colour. The exact
    /// strings are asserted too, so a `format` that silently returned "" for
    /// out-of-range input could not satisfy the rejection half by accident.
    func test_format_ofOutOfRangeTriple_doesNotClampAndProducesAStringParseRejects() {
        XCTAssertEqual(AccentColorStore.format((-1, 0, 0)), "-255,0,0", "a negative channel is not clamped to 0")
        XCTAssertEqual(AccentColorStore.format((2, 0, 0)), "510,0,0", "an over-range channel is not clamped to 255")
        assertRejects(AccentColorStore.format((-1, 0, 0)), "a negative channel must not round-trip into a colour")
        assertRejects(AccentColorStore.format((2, 0, 0)), "an over-range channel must not round-trip into a colour")
    }

    // MARK: - Round trip

    func test_formatOfParse_returnsTheOriginalStringForEveryCanonicalCommaTriple() {
        for n in 0...255 {
            let input = "\(n),\(255 - n),\((n * 7) % 256)"
            guard let parsed = AccentColorStore.parse(input) else {
                XCTFail("parse(\(input.debugDescription)) returned nil")
                continue
            }
            XCTAssertEqual(
                AccentColorStore.format(parsed), input,
                "format(parse(x)) must equal x for canonical \"R,G,B\" input"
            )
        }
    }

    func test_parseOfFormat_returnsTheOriginalTripleForEveryComponentValue() {
        for n in 0...255 {
            let triple = (Double(n) / 255, Double(255 - n) / 255, Double((n * 3) % 256) / 255)
            let text = AccentColorStore.format(triple)
            guard let parsed = AccentColorStore.parse(text) else {
                XCTFail("parse(format(\(triple))) == parse(\(text.debugDescription)) returned nil")
                continue
            }
            XCTAssertEqual(parsed.0, triple.0, accuracy: 1e-12, "red channel round trip for n = \(n)")
            XCTAssertEqual(parsed.1, triple.1, accuracy: 1e-12, "green channel round trip for n = \(n)")
            XCTAssertEqual(parsed.2, triple.2, accuracy: 1e-12, "blue channel round trip for n = \(n)")
        }
    }

    func test_formatOfParse_isStableWhenAppliedTwice() {
        guard let once = AccentColorStore.parse("0,167,96") else {
            return XCTFail("parse(\"0,167,96\") returned nil")
        }
        let text = AccentColorStore.format(once)
        guard let twice = AccentColorStore.parse(text) else {
            return XCTFail("parse(\(text.debugDescription)) returned nil")
        }
        XCTAssertEqual(AccentColorStore.format(twice), text, "a second round trip must not drift")
    }
}
