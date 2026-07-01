#!/usr/bin/env bash
#
# Run the Linux Core + CLI test suite, tolerating a known swift-corelibs
# process-exit hang — WITHOUT masking real failures.
#
# Background: on Linux, the swift-testing bundle's async `@main` finishes
# all tests, then parks the main thread in libdispatch's `dispatch_main()`
# (`swift_task_asyncMainDrainQueue`) waiting for the wakeup that fires the
# final `exit()`. That wakeup is intermittently lost — a swift-corelibs
# libdispatch main-queue race — so the process never exits even though
# every test passed. It reproduces ~15-25% of runs on Swift 6.0.3 *and*
# 6.2.0 (so it is not toolchain-specific), independent of which tests run
# and of `--no-parallel`. It always clears on a fresh run. See the design
# note / CI-flake memo for the full investigation.
#
# Strategy: bound each run with `timeout`. Exit-code policy:
#   * 0            -> tests passed; done.
#   * 124 / 137    -> the run TIMED OUT (the benign exit-hang). Reap any
#                     orphaned test process and retry.
#   * anything else-> a genuine test failure, build error, or crash
#                     (e.g. 1 = issues recorded, 134 = abort, 139 = segv).
#                     Fail the job IMMEDIATELY — never retried, never hidden.
#
# Because only a clean timeout is retried, a real failure can never be
# masked: it surfaces on the first attempt with its own exit code. Three
# attempts take the residual flake from ~20% to <1%, and the residual is a
# timeout (visible, not a false pass), not a silent success.
#
# Usage: Scripts/ci-test-linux.sh [extra swift-test args...]
#   e.g. Scripts/ci-test-linux.sh --verbose
set -uo pipefail

ATTEMPTS="${CI_TEST_ATTEMPTS:-3}"
PER_ATTEMPT_TIMEOUT="${CI_TEST_TIMEOUT:-300}"

for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "::group::swift test (attempt ${attempt}/${ATTEMPTS}, per-attempt timeout ${PER_ATTEMPT_TIMEOUT}s)"
    # -s TERM then SIGKILL 30s later if it ignores TERM (the hung process does).
    timeout -s TERM -k 30 "$PER_ATTEMPT_TIMEOUT" \
        swift test --filter SwiftPWACoreTests --filter SwiftPWACLITests "$@"
    rc=$?
    echo "::endgroup::"

    if [ "$rc" -eq 0 ]; then
        echo "swift test passed on attempt ${attempt}."
        exit 0
    fi

    # 124 = timed out (TERM); 137 = 128+9, timed out then SIGKILL'd by -k.
    if [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ]; then
        echo "::error::swift test exited ${rc} — a genuine failure/crash, not the exit-hang. Failing the job."
        exit "$rc"
    fi

    echo "::warning::swift test timed out after ${PER_ATTEMPT_TIMEOUT}s on attempt ${attempt} — the known swift-corelibs process-exit hang (all tests had passed). Reaping orphans and retrying."
    pkill -9 -f 'swift-pwaPackageTests.xctest' 2>/dev/null || true
    pkill -9 -f 'swift-test' 2>/dev/null || true
    sleep 3
done

echo "::error::swift test timed out on all ${ATTEMPTS} attempts. The exit-hang normally clears within a retry or two, so this is unexpected — failing rather than looping forever."
exit 1
