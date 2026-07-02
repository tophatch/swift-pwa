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
#     ran + no failures                              -> PASS (parked at the
#                                                      post-run exit-hang).
#   * process exited with neither runEnded nor a
#     failure (a swift-corelibs crash-at-exit, the
#     other face of the same race)                   -> RETRY; a deterministic
#                                                      crash recrashes and fails.
#
# Caveat (documented in issue #39 / docs/linux-setup.md): a hypothetical test
# that hangs *mid-run* with no output would be indistinguishable from the
# post-run park and reported as passed. The suite has no such test (all are
# fast and event-dense); a real failing assertion or crash is still caught.
#
# Requires the bundle to be built first (CI's "Build test targets" step runs
# `swift build --build-tests`). Extra args are ignored.
set -uo pipefail

ATTEMPTS="${CI_TEST_ATTEMPTS:-4}"
HARD_TIMEOUT="${CI_TEST_TIMEOUT:-300}"       # ceiling per attempt (rarely hit)
STABLE_POLLS="${CI_TEST_STABLE_POLLS:-16}"   # 16 * 0.5s = 8s quiescent => parked

BUNDLE=$(find .build -maxdepth 4 -name '*PackageTests.xctest' -type f 2>/dev/null | head -1)
if [ -z "${BUNDLE:-}" ]; then
    echo "::error::test bundle not found under .build — run 'swift build --build-tests' first."
    exit 1
fi

ev=$(mktemp)
log=$(mktemp)
trap 'rm -f "$ev" "$log"' EXIT

VERDICT=""   # set by run_once: pass | fail | crash

run_once() {
    VERDICT=""
    : > "$ev"
    # Bundle console -> $log (surfaced to the step log by the caller); the
    # structured verdict comes from the event file, never from stdout.
    "$BUNDLE" --testing-library swift-testing \
        --event-stream-version 0 --event-stream-output-path "$ev" \
        --filter SwiftPWACoreTests --filter SwiftPWACLITests >"$log" 2>&1 &
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
            VERDICT=pass; break   # parked at the post-run exit-hang, no failures
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
