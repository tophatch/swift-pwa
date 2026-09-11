#!/usr/bin/env bash
#
# Run the Linux Core + CLI test suite immune to a known swift-corelibs
# process-exit hang — WITHOUT masking test failures.
#
# Background: on Linux the swift-testing bundle runs every test, then parks the
# main thread in libdispatch's `dispatch_main()` (`swift_task_asyncMainDrain
# Queue`) waiting for the signal that fires the final `exit()`. That wakeup is
# intermittently lost — a swift-corelibs libdispatch main-queue race — so the
# process never exits even though every test passed. It is a *post-run* hang
# (the tests have all finished), reproduces on 6.0.3 and 6.2 alike, and lately
# runs *hot*: on the hosted gtk runners a majority of runs park. See issue #39.
#
# `swift test` can't be wrapped around this: the hang eats its stdout summary
# (SwiftPM block-buffers, flushing only on the clean exit the hang prevents),
# so a timeout wrapper can't tell "passed then hung" from "hung mid-run", and
# blind retries fail otherwise-green jobs. (Dead ends, all verified: stdbuf
# can't reach SwiftPM's output, --xunit-output is XCTest-only, `| tee`
# deadlocks under `timeout` — see issue #39.)
#
# What we do instead: launch the built test bundle directly and have
# swift-testing write its structured event stream to a FILE
# (`--event-stream-output-path`). Two facts make this robust:
#   * A failed expectation is written as a `"symbol":"fail"` issue event
#     *mid-run*, flushed with the bulk of the stream — so failures are always
#     observed and reported. Never masked.
#   * swift-testing block-buffers the stream, so its final chunk (`runEnded`
#     plus the last few `testEnded`s) is often lost to the exit-hang's kill —
#     the file's trailing verdict is unreliable. But the hang is *post-run*, so
#     once the process has run tests and gone idle (no new events for several
#     seconds while still alive) with no failure recorded, the run passed.
#
# Verdict per attempt, read from the event file:
#   * a `"symbol":"fail"` event                      -> FAIL (report, no retry).
#   * `runEnded`                                     -> PASS (clean flush).
#   * process alive + event file quiescent + tests
#     ran + no failures + no test still in flight    -> PASS (parked at the
#                                                      post-run exit-hang).
#   * process exited with neither runEnded nor a
#     failure (a swift-corelibs crash-at-exit, the
#     other face of the same race)                   -> RETRY; a deterministic
#                                                      crash recrashes and fails.
#
# Telling the post-run park from a test that is merely slow (issue #190): the
# event stream carries `testStarted` / `testEnded` per `testID`, so "a test is
# still in flight" is directly observable rather than inferred from file growth.
#   * Nothing in flight -> a short quiet window (STABLE_POLLS) is enough; every
#     test that started has reported, so the process can only be parked.
#   * Something in flight -> wait INFLIGHT_POLLS instead, far longer than any
#     test in the suite takes. A live test emits its `testEnded` inside that
#     window; a lost block-buffered tail never will.
# The long window is needed because both look the same in the file: swift-testing
# block-buffers, so the park can also *end* with tests that ran but never got
# flushed. Passing on the long window is therefore still a judgement call, and
# it says so on stderr, naming the tests that never reported.
#
# This replaced an 8-second quiescence check that read any quiet gap as the park.
# The GUI-gated GTK suites broke its assumption that every test is "fast and
# event-dense": they pump a GMainContext for seconds at a time emitting nothing,
# so a real mid-run gap looked exactly like the park. Measured on the GTK3 box
# against a suite with a genuine failure, the old rule reported "no failures"
# on 1 run in 5.
#
# Requires the bundle to be built first (CI's "Build test targets" step runs
# `swift build --build-tests`).
#
# Args are swift-testing filters. With none — how CI invokes it — the two
# backend-agnostic CI targets are used, so CI behavior is unchanged. Passing
# filters lets the same verdict logic cover a GUI-gated backend suite run under
# Xvfb (see Scripts/remote-linux.sh), which needs this exact retry handling:
# the crash-at-exit truncates swift-testing's block-buffered tail, so a plain
# `swift test` reports a passing run as a signal-6 failure.
set -uo pipefail

ATTEMPTS="${CI_TEST_ATTEMPTS:-4}"
HARD_TIMEOUT="${CI_TEST_TIMEOUT:-300}"       # ceiling per attempt (rarely hit)
STABLE_POLLS="${CI_TEST_STABLE_POLLS:-16}"   # 16 * 0.5s = 8s quiescent => parked
# Only consulted when a test started and never reported. 120 * 0.5s = 60s, which
# has to clear the slowest single test in the suite by a wide margin — the
# GUI-gated ones pump for seconds in silence, and GTKNavigationPolicyTests takes
# ~18s on its own. Raise it, don't lower it: too short reads a slow test as a
# finished run, which is the bug this exists to stop.
INFLIGHT_POLLS="${CI_TEST_INFLIGHT_POLLS:-120}"

BUNDLE=$(find .build -maxdepth 4 -name '*PackageTests.xctest' -type f 2>/dev/null | head -1)
if [ -z "${BUNDLE:-}" ]; then
    echo "::error::test bundle not found under .build — run 'swift build --build-tests' first."
    exit 1
fi

FILTERS=()
if [ "$#" -gt 0 ]; then
    for f in "$@"; do FILTERS+=(--filter "$f"); done
else
    FILTERS=(--filter SwiftPWACoreTests --filter SwiftPWACLITests)
fi

ev=$(mktemp)
log=$(mktemp)
trap 'rm -f "$ev" "$log"' EXIT

VERDICT=""     # set by run_once: pass | fail | crash
STRANDED=""    # testIDs that started and never reported, when we pass anyway

# Tests that emitted `testStarted` and never the matching `testEnded`.
#
# One event per line, each carrying its own `testID`, so set subtraction over
# the two kinds is the whole job. Suites emit the pair too and are included
# deliberately: a suite is in flight exactly while one of its tests is.
in_flight() {
    comm -23 \
        <(grep '"kind":"testStarted"' "$ev" 2>/dev/null | grep -o '"testID":"[^"]*"' | sort -u) \
        <(grep '"kind":"testEnded"' "$ev" 2>/dev/null | grep -o '"testID":"[^"]*"' | sort -u) \
        | sed 's/"testID":"//; s/"$//'
}

run_once() {
    VERDICT=""
    : > "$ev"
    # Bundle console -> $log (surfaced to the step log by the caller); the
    # structured verdict comes from the event file, never from stdout.
    "$BUNDLE" --testing-library swift-testing \
        --event-stream-version 0 --event-stream-output-path "$ev" \
        "${FILTERS[@]}" >"$log" 2>&1 &
    local pid=$! last=-1 stable=0 sz end=$(( SECONDS + HARD_TIMEOUT ))
    while [ "$SECONDS" -lt "$end" ]; do
        if grep -q '"symbol":"fail"' "$ev" 2>/dev/null; then VERDICT=fail; break; fi
        if grep -q '"kind":"runEnded"' "$ev" 2>/dev/null; then VERDICT=pass; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then
            sleep 0.3
            if grep -q '"symbol":"fail"' "$ev" 2>/dev/null; then VERDICT=fail
            elif grep -q '"kind":"runEnded"' "$ev" 2>/dev/null; then VERDICT=pass
            else VERDICT=crash; fi   # exited with no verdict = swift-corelibs crash-at-exit
            break
        fi
        sz=$(wc -c <"$ev" 2>/dev/null || echo 0)
        if [ "$sz" = "$last" ] && [ "$sz" -gt 0 ]; then stable=$((stable+1)); else stable=0; last=$sz; fi
        if [ "$stable" -ge "$STABLE_POLLS" ] && grep -q '"kind":"testEnded"' "$ev" 2>/dev/null; then
            # A quiet file is not a finished run while a test is still in
            # flight: the GUI suites go silent for seconds mid-test. Give those
            # the long window — a live test reports inside it, a tail lost to
            # block buffering never does.
            stranded=$(in_flight)
            if [ -z "$stranded" ]; then
                VERDICT=pass; break   # parked at the post-run exit-hang, no failures
            fi
            if [ "$stable" -ge "$INFLIGHT_POLLS" ]; then
                STRANDED="$stranded"
                VERDICT=pass; break
            fi
        fi
        sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -z "$VERDICT" ] && VERDICT=crash
}

for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "::group::test bundle (attempt ${attempt}/${ATTEMPTS})"
    run_once
    cat "$log"
    echo "::endgroup::"
    case "$VERDICT" in
        pass)
            if [ -n "$STRANDED" ]; then
                # Passing, but say what we couldn't account for. These are
                # usually a block-buffered tail the exit-hang ate; a test that
                # genuinely wedged mid-run would look the same, and that is the
                # one case this verdict can still get wrong (issue #190).
                echo "::warning::passed on quiescence with $(printf '%s\n' "$STRANDED" | grep -c .) test(s) that started and never reported:"
                printf '%s\n' "$STRANDED" | sed 's/^/  - /'
            fi
            echo "swift-testing run completed with no failures (attempt ${attempt})."
            exit 0
            ;;
        fail)
            echo "::error::swift-testing reported a test failure:"
            grep -o '"symbol":"fail","text":"[^"]*"' "$ev" | sed 's/.*"text":"/  - /; s/"$//' | head -20
            exit 1
            ;;
        *)
            echo "::warning::test process exited without a verdict (swift-corelibs crash-at-exit) on attempt ${attempt} — retrying."
            ;;
    esac
done

echo "::error::the test process crashed without completing on all ${ATTEMPTS} attempts — treating as a genuine failure."
exit 1
