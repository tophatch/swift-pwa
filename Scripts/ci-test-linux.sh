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
# Strategy: bound each run with `timeout` and capture its output. Exit-code
# policy:
#   * 0            -> tests passed; done.
#   * 124 / 137    -> the run TIMED OUT. Distinguish two cases by whether the
#                     output already contains swift-testing's passed-completion
#                     line ("Test run with N tests ... passed"):
#                       - present  -> every test ran and passed; only the final
#                                     exit() was lost to the dispatch_main race.
#                                     Accept as SUCCESS immediately (no point
#                                     burning more attempts on a hang that has
#                                     already reported success).
#                       - absent   -> the process hung mid-run (a real deadlock
#                                     would look like this too). Reap orphans
#                                     and retry; fail if every attempt hangs
#                                     before completing.
#   * anything else-> a genuine test failure, build error, or crash
#                     (e.g. 1 = issues recorded, 134 = abort, 139 = segv).
#                     Fail the job IMMEDIATELY — never retried, never hidden.
#
# Because only a timeout is ever tolerated — and only once the suite has
# printed its *passed*-completion line — a real failure can't be masked: a
# failing run exits non-timeout (surfaced at once), and a "failed"-completion
# run exits 1 (also surfaced). The completion-line check is what makes the
# gtk4 job reliable: the exit-hang runs hot enough that 3 blind retries can
# all land on it, but the passed line is emitted before the hang.
#
# Buffering caveat: swift-testing's stdout is block-buffered on a non-TTY, so
# the final ~60-byte summary line is normally flushed only by the process's
# clean exit — which never happens when it hangs, so a SIGKILL would discard
# it and the check would miss a genuinely-passed run. We force line buffering
# with `stdbuf -oL -eL` (inherited by the test binary via libstdbuf) so every
# line, summary included, flushes the instant it's written — before the hang.
# If stdbuf can't influence the output, we're no worse off than plain retries.
#
# Usage: Scripts/ci-test-linux.sh [extra swift-test args...]
#   e.g. Scripts/ci-test-linux.sh --verbose
set -uo pipefail

ATTEMPTS="${CI_TEST_ATTEMPTS:-3}"
PER_ATTEMPT_TIMEOUT="${CI_TEST_TIMEOUT:-300}"

# swift-testing prints this once the whole run has finished with every test
# passing (e.g. "✔ Test run with 410 tests in 58 suites passed after 1.2s").
# A "failed" run prints "... failed" instead and exits non-zero, so matching
# only `passed` cannot swallow a real failure.
COMPLETION_RE='Test run with .* passed'

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

reap_orphans() {
    pkill -9 -f 'swift-pwaPackageTests.xctest' 2>/dev/null || true
    pkill -9 -f 'swift-test' 2>/dev/null || true
}

for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "::group::swift test (attempt ${attempt}/${ATTEMPTS}, per-attempt timeout ${PER_ATTEMPT_TIMEOUT}s)"
    # Redirect (don't pipe) to a fresh per-attempt log. A pipe would make bash
    # wait on the reader (`tee`), which only sees EOF once every process
    # holding the pipe's write end exits — but `timeout` kills only its direct
    # child (`swift test`), not the compiler/linker grandchildren that inherit
    # the fd, so a `| tee` deadlocks the step past the job limit. With a file
    # bash waits solely on `timeout`, which returns as soon as it kills its
    # child. `> "$log"` truncates so the completion-line check is per-attempt.
    # -s TERM then SIGKILL 30s later if it ignores TERM (the hung process does).
    # stdbuf -oL -eL: line-buffer so the passed-summary flushes before any hang.
    timeout -s TERM -k 30 "$PER_ATTEMPT_TIMEOUT" \
        stdbuf -oL -eL \
        swift test --filter SwiftPWACoreTests --filter SwiftPWACLITests "$@" > "$log" 2>&1
    rc=$?
    cat "$log"
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

    # A timeout AFTER the suite printed its passed-completion line is the
    # benign dispatch_main exit-hang: every test ran and passed, only the
    # final exit() was lost. Accept it rather than gambling on a retry.
    if grep -Eq "$COMPLETION_RE" "$log"; then
        echo "swift test completed and passed on attempt ${attempt}; the process then hung on exit (known swift-corelibs dispatch_main race). Treating as success."
        reap_orphans
        exit 0
    fi

    echo "::warning::swift test timed out after ${PER_ATTEMPT_TIMEOUT}s on attempt ${attempt} before printing a completion line — reaping orphans and retrying."
    reap_orphans
    sleep 3
done

echo "::error::swift test timed out on all ${ATTEMPTS} attempts without ever printing a passed-completion line — this is not the benign post-run exit-hang. Failing."
exit 1
