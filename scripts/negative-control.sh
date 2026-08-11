#!/bin/bash
# Negative control for the regression tests (testing.md "品質" MUST).
#
# For each mutation: confirm green, introduce ONLY that defect without touching
# any test, confirm the intended tests go red, restore exactly via git, confirm
# the tree is clean and green again.
#
# A mutation that produces a COMPILE error is not evidence — the procedure
# requires the test to fail on its assertion. Those are reported as INVALID.

set -uo pipefail
cd "$(dirname "$0")/.."

# Restoration is `git checkout -- <file>`, which reverts to HEAD. On a dirty
# tree that silently DISCARDS uncommitted work — it ate an in-progress source
# change the first time this ran. Refuse rather than risk it.
if [ -n "$(git status --porcelain)" ]; then
    echo "REFUSING: working tree is dirty."
    echo "This script restores mutations with 'git checkout --', which would"
    echo "discard the changes below. Commit or stash them first."
    git status --short
    exit 2
fi

pass=0
fail=0

run_tests() {
    swift test 2>&1
}

failing_names() {
    grep -oE "^Test Case '-\[[^ ]+ ([a-zA-Z0-9_]+)\]' failed" \
        | sed -E "s/.*\[[^ ]+ ([a-zA-Z0-9_]+)\].*/\1/" | sort -u
}

mutate() {
    local label="$1" file="$2" from="$3" to="$4" expect="$5"

    printf '\n────────────────────────────────────────────────────────\n'
    printf 'MUTATION: %s\n  %s\n' "$label" "$file"

    if ! grep -qF -- "$from" "$file"; then
        printf '  INVALID: anchor text not found — mutation not applied\n'
        fail=$((fail + 1))
        return
    fi

    # Apply with perl so the replacement is literal, not a regex.
    FROM="$from" TO="$to" perl -0777 -i -pe '
        my $f = $ENV{FROM}; my $t = $ENV{TO};
        my $i = index($_, $f);
        substr($_, $i, length($f)) = $t if $i >= 0;
    ' "$file"

    local out
    out=$(run_tests)

    # A compile failure means the binary never ran, so there is no "Executed N
    # tests" line at all. Two traps, both of which bit here:
    #
    #   - Do NOT spot compile errors by grepping for "error:". XCTest reports
    #     every failed assertion in exactly that format, with a leading path,
    #     so it misclassifies real red tests as build failures.
    #   - Do NOT use `grep -q` on a pipe under `set -o pipefail`. grep exits
    #     the instant it matches, the writer takes SIGPIPE and returns 141,
    #     and pipefail then fails the whole pipeline — so a MATCH reads as a
    #     miss. Count instead.
    if [ "$(printf '%s' "$out" | grep -cE "Executed [0-9]+ test")" -eq 0 ]; then
        printf '  INVALID: mutation did not build — not evidence\n'
        echo "$out" | grep -E "^/.*error:" | head -3 | sed 's/^/    /'
        git checkout -- "$file"
        fail=$((fail + 1))
        return
    fi

    local reds
    reds=$(echo "$out" | failing_names)
    local count
    count=$(echo "$reds" | grep -c . )

    printf '  tests turned red: %s\n' "$count"
    if [ "$count" -gt 0 ]; then
        echo "$reds" | head -6 | sed 's/^/    - /'
        [ "$count" -gt 6 ] && printf '    … and %d more\n' "$((count - 6))"
    fi

    # Counted, not `grep -q` — see the pipefail/SIGPIPE note above.
    if [ "$(printf '%s' "$reds" | grep -c "$expect")" -gt 0 ]; then
        printf '  ✅ expected test %s went red\n' "$expect"
        pass=$((pass + 1))
    else
        printf '  ❌ expected %s to go red, it did not\n' "$expect"
        fail=$((fail + 1))
    fi

    git checkout -- "$file"
    if [ -n "$(git status --porcelain "$file")" ]; then
        printf '  ❌ RESTORE FAILED — %s still dirty\n' "$file"
        fail=$((fail + 1))
    fi
}

printf '=== baseline: must be green before mutating ===\n'
run_tests | grep -E "Executed [0-9]+ tests" | tail -1

mutate "hex parser accepts a leading sign again (the fixed regression)" \
    Sources/Pomo/AccentColorStore.swift \
    'if hex.count == 6, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }),
           let v = UInt64(hex, radix: 16) {' \
    'if hex.count == 6, let v = UInt64(hex, radix: 16) {' \
    "Sign"

mutate "noise floor off-by-one (>= becomes >)" \
    Sources/Pomo/SessionLog.swift \
    'entry.seconds >= minimumLoggedSeconds || entry.note != nil' \
    'entry.seconds > minimumLoggedSeconds || entry.note != nil' \
    "NoiseFloor"

mutate "on-disk reason spelling renamed (pause -> paused)" \
    Sources/Pomo/SessionSource.swift \
    'case paused = "pause"' \
    'case paused = "paused"' \
    "ause"

mutate "phase spelling renamed (break -> shortBreak)" \
    Sources/Pomo/SessionSource.swift \
    'case .shortBreak: return "break"' \
    'case .shortBreak: return "shortBreak"' \
    "reak"

mutate "ensureDirectoryExists swallows the create failure again" \
    Sources/Pomo/SessionLog.swift \
    '        } catch {
            // Previously `try?`, which returned the URL of a directory that
            // does not exist. The only caller beeps on nil but otherwise hands
            // the path straight to NSWorkspace, so "Open Logs Folder" did
            // nothing at all instead of reporting the problem.
            NSLog("Pomo: could not create log directory — %@", String(describing: error))
            return nil
        }' \
    '        } catch {
        }' \
    "ensureDirectoryExists"

mutate "day rollover check removed from commit" \
    Sources/Pomo/TodayTotalStore.swift \
    'guard seconds > 0 else { return }
        reloadIfDayChanged()' \
    'guard seconds > 0 else { return }' \
    "AfterMidnight"

mutate "minuteDigits threshold off-by-one (>= 100 becomes > 100)" \
    Sources/Pomo/DesignTokens.swift \
    'minutes >= 100 ? 3 : 2' \
    'minutes > 100 ? 3 : 2' \
    "inuteDigits"

mutate "hover task slot sends the title down instead of up" \
    Sources/Pomo/PomoView.swift \
    'if isEditing { return TaskSlotOffsets(display: -distance, editor: 0) }' \
    'if isEditing { return TaskSlotOffsets(display: distance, editor: 0) }' \
    "taskSlotOffsets_whenEditing"

mutate "work deadline incorrectly ends the phase instead of entering overtime" \
    Sources/Pomo/PomodoroSource.swift \
    'if remaining == 1 { return .workDeadline }' \
    'if remaining == 1 { return .breakFinished }' \
    "tickOutcome_workCrossesDeadline"

mutate "custom duration rejects the documented 180-minute upper boundary" \
    Sources/Pomo/PomodoroSource.swift \
    'guard (minCustomMinutes...maxCustomMinutes).contains(minutes) else { return nil }' \
    'guard minutes >= minCustomMinutes && minutes < maxCustomMinutes else { return nil }' \
    "validatedMinutes_acceptsTrimmedRange"

mutate "manual work end drops the accumulated Today time" \
    Sources/Pomo/PomodoroSource.swift \
    '            lastCompletedTask = currentTask
            reviewRecordedForCurrentBreak = false
            commitCurrentSession()' \
    '            lastCompletedTask = currentTask
            reviewRecordedForCurrentBreak = false' \
    "endingRunningWorkCommitsActualTimeOnce"

mutate "natural break completion auto-starts another work session" \
    Sources/Pomo/PomodoroSource.swift \
    '        completePulseToken &+= 1
        returnToWorkIdle()
    }

    private func returnToWorkIdle()' \
    '        completePulseToken &+= 1
        returnToWorkIdle()
        start()
    }

    private func returnToWorkIdle()' \
    "breakCompletionReturnsToWorkIdleWithoutAutoStarting"

printf '\n════════════════════════════════════════════════════════\n'
printf 'negative controls: %d passed, %d failed\n' "$pass" "$fail"
printf '\nfinal tree state: '
if [ -z "$(git status --porcelain)" ]; then printf 'clean (no mutation residue)\n'; else printf 'DIRTY\n'; git status --short; fi
printf 'final test run: '
run_tests | grep -E "Executed [0-9]+ tests" | tail -1
