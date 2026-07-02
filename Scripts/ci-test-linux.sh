#!/usr/bin/env bash
#
# Run the Linux Core + CLI test suite immune to a known swift-corelibs
# process-exit hang — WITHOUT masking real failures.
#
# Background: on Linux the swift-testing bundle finishes every test, then parks
# the main thread in libdispatch's `dispatch_main()` (`swift_task_async
# MainDrainQueue`) waiting for the wakeup that fires the final `exit()`. That
# wakeup is intermittently lost — a swift-corelibs libdispatch main-queue race
# — so the process never exits even though every test passed. It reproduces on
# 6.0.3 and 6.2 alike, independent of which tests run, and lately runs *hot*
# (a majority of runs on the gtk runners). See the CI-flake memo / issue #39.
#
# Why not `swift test`: on the hang, `swift test`'s stdout summary never
# flushes (SwiftPM block-buffers and only flushes on the clean exit the hang
# prevents), so a wrapper can't tell "passed then hung" from "hung mid-run".
# stdbuf can't reach SwiftPM's output; `--xunit-output` is XCTest-only; a
# `| tee` deadlocks under `timeout`. (All dead ends — see issue #39.)
#
# What works: launch the built test bundle directly and have swift-testing
# write its structured **event stream to a file** (`--event-stream-output-path`).
# The authoritative `runEnded` verdict — and every per-issue `"symbol":"fail"`
# — is written to that file as the run proceeds. We read the verdict from the
# file and kill the (possibly parked) process instead of waiting on the lost
# wakeup:
#   * a `"symbol":"fail"` event (issue recorded, flushed mid-run) -> FAIL now.
#   * a `runEnded` event                                          -> PASS.
#   * neither within the per-attempt timeout -> swift-testing block-buffers the
#     event stream too, so its final chunk (incl. `runEnded`) is occasionally
#     lost to the same SIGKILL. The run is deterministic, so RETRY; a real
#     failure re-emits its `"symbol":"fail"` and is never masked.
#
# Requires the test bundle to be built first (CI's "Build test targets" step
# runs `swift build --build-tests`).
#
# Usage: Scripts/ci-test-linux.sh   (extra args are ignored — kept for the
#        historical `--verbose` call site)
set -uo pipefail

# The run itself finishes in seconds; the per-attempt timeout only bounds how
# long we wait for `runEnded` before treating the attempt as a lost-tail and
# retrying. The exit-hang runs hot on the gtk runners (~1/3 of attempts lose
# the tail), so keep a healthy attempt ceiling — retries only cost wall-clock
# on an actual miss; a completed run returns immediately.
ATTEMPTS="${CI_TEST_ATTEMPTS:-8}"
PER_ATTEMPT_TIMEOUT="${CI_TEST_TIMEOUT:-60}"
FILTERS=(--filter SwiftPWACoreTests --filter SwiftPWACLITests)

BUNDLE=$(find .build -maxdepth 4 -name '*PackageTests.xctest' -type f 2>/dev/null | head -1)
if [ -z "${BUNDLE:-}" ]; then
    echo "::error::test bundle not found under .build — run 'swift build --build-tests' first."
    exit 1
fi

events=$(mktemp)
trap 'rm -f "$events"' EXIT

for attempt in $(seq 1 "$ATTEMPTS"); do
    : > "$events"
    echo "::group::test bundle (attempt ${attempt}/${ATTEMPTS}, per-attempt timeout ${PER_ATTEMPT_TIMEOUT}s)"

    # Run the bundle directly; swift-testing streams structured events to the
    # file. Console output still goes to the log for humans.
    "$BUNDLE" --testing-library swift-testing \
        --event-stream-version 0 --event-stream-output-path "$events" \
        "${FILTERS[@]}" &
    pid=$!

    verdict=""
    end=$(( SECONDS + PER_ATTEMPT_TIMEOUT ))
    while [ "$SECONDS" -lt "$end" ]; do
        # A recorded issue is flushed with the bulk of the stream, so a real
        # failure is caught even when the trailing runEnded is lost to the hang.
        if grep -q '"symbol":"fail"' "$events" 2>/dev/null; then verdict=fail; break; fi
        if grep -q '"kind":"runEnded"' "$events" 2>/dev/null; then verdict=pass; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then
            # Process exited on its own (rare clean exit, or a crash). Give the
            # stream a moment to settle, then read whatever verdict landed.
            sleep 0.3
            grep -q '"symbol":"fail"' "$events" 2>/dev/null && verdict=fail
            [ -z "$verdict" ] && grep -q '"kind":"runEnded"' "$events" 2>/dev/null && verdict=pass
            break
        fi
        sleep 0.5
    done

    # Reap the (usually parked) process before the next attempt / exit.
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "::endgroup::"

    case "$verdict" in
        pass)
            echo "swift-testing run completed and passed (attempt ${attempt})."
            exit 0
            ;;
        fail)
            echo "::error::swift-testing reported a test failure:"
            grep -o '"symbol":"fail","text":"[^"]*"' "$events" | sed 's/.*"text":"/  - /; s/"$//' | head -20
            exit 1
            ;;
        *)
            echo "::warning::no completion (runEnded) within ${PER_ATTEMPT_TIMEOUT}s on attempt ${attempt} — the event-stream tail was lost to the swift-corelibs exit-hang; retrying."
            ;;
    esac
done

echo "::error::the test run never reported completion across ${ATTEMPTS} attempts — this is not the benign tail-loss (a genuine mid-run hang or crash). Failing."
exit 1
