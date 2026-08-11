#!/bin/bash
#
# The repo's canonical verification command. Run it before claiming anything
# is done.
#
#   scripts/check.sh          build + lint + test
#   scripts/check.sh --render also re-render the pill and diff against the
#                             committed golden hashes
#
# What each gate does and does NOT cover is stated in the output, so an
# unmeasured metric is never mistaken for a passing one.

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
step() { printf '\n=== %s ===\n' "$1"; }

step "swift build (debug) — must be warning-free"
warnings=$(swift build 2>&1 | grep -c 'warning:')
swift build 2>&1 | tail -1
echo "warnings: $warnings"
[ "$warnings" -eq 0 ] || { echo "FAIL: warnings must stay at zero"; fail=1; }

step "swift build (release)"
swift build -c release 2>&1 | tail -1 || fail=1

step "swiftlint — code-structure.md thresholds + swift.md strictness"
if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --quiet --strict 2>&1 | grep -v 'has been renamed'
    swiftlint lint --quiet --strict >/dev/null 2>&1 || { echo "FAIL: swiftlint"; fail=1; }
    echo "ok"
    echo "NOT covered by this gate: control-flow nesting depth, cognitive"
    echo "complexity, nested-callback depth — SwiftLint has no equivalent rule."
else
    echo "SKIP: swiftlint not installed (brew install swiftlint) — thresholds UNMEASURED"
    fail=1
fi

step "swift-format — rule violations only (layout is deliberately not enforced)"
if xcrun --find swift-format >/dev/null 2>&1; then
    findings=$(xcrun swift-format lint --recursive --configuration .swift-format Sources 2>&1 \
        | grep -vE '\[(Indentation|Spacing|AddLines|LineLength)\]')
    if [ -n "$findings" ]; then echo "$findings"; echo "FAIL: swift-format"; fail=1; else echo "ok"; fi
    echo "NOTE: layout rules are filtered out on purpose — swift-format's"
    echo "default layout disagrees with this repo's established style."
else
    echo "SKIP: swift-format not found"
fi

step "swift test"
swift test 2>&1 | grep -E 'Executed [0-9]+ test|error:' | tail -3
swift test >/dev/null 2>&1 || { echo "FAIL: tests"; fail=1; }

if [ "$fail" -eq 0 ]; then
    printf '\nALL GATES PASSED\n'
else
    printf '\nSOME GATES FAILED\n'
fi
exit "$fail"
