import Foundation
@testable import SwiftPWACLISupport
import Testing

/// `Shell.capture` reads a child's stdout through a pipe, and a pipe holds a
/// finite amount (64 KiB on macOS). Draining only *after* `waitUntilExit()`
/// therefore deadlocks on any command that says more than that: the child
/// blocks in `write`, the parent blocks in `wait`, forever.
///
/// It shipped that way, and `xcrun simctl list runtimes -j` is over the line on
/// a machine with several runtimes installed — so `build --target ios
/// --simulator` hung before printing anything on exactly the machines where
/// nobody could attach a debugger. Three CI jobs died at their step timeout
/// (39, 30, 45 minutes) looking like slow compiles.
///
/// These tests take a couple of seconds when the drain is correct and hang
/// forever when it isn't, which is the honest shape of the bug.
@Suite(.timeLimit(.minutes(1)))
struct ShellCaptureTests {
    #if !os(Windows)
        /// The regression: output far past any pipe buffer must still come back
        /// whole.
        @Test func capturesOutputLargerThanThePipeBuffer() async throws {
            let bytes = 1_000_000
            let out = try await Shell.capture(
                "/usr/bin/env", ["sh", "-c", "yes abcdefghij | head -c \(bytes)"]
            )
            #expect(out.utf8.count == bytes)
        }

        /// The same, with a timeout set: a bound must not turn a big-but-healthy
        /// command into a failure.
        @Test func aTimeoutDoesNotTruncateALargeButPromptCommand() async throws {
            let bytes = 300_000
            let out = try await Shell.capture(
                "/usr/bin/env", ["sh", "-c", "yes abcdefghij | head -c \(bytes)"],
                timeout: 30
            )
            #expect(out.utf8.count == bytes)
        }

        /// A child that writes and then never exits is what the timeout is for,
        /// and it must report *that* rather than a bare non-zero status — the
        /// difference between "your tool is wedged" and "your tool failed".
        @Test func aWedgedChildTimesOutWithATimedOutError() async throws {
            await #expect(throws: BundlerError.self) {
                try await Shell.capture(
                    "/usr/bin/env", ["sh", "-c", "echo hello; sleep 60"],
                    timeout: 1
                )
            }
            do {
                _ = try await Shell.capture(
                    "/usr/bin/env", ["sh", "-c", "echo hello; sleep 60"],
                    timeout: 1
                )
                Issue.record("expected the wedged child to time out")
            } catch let error as BundlerError {
                guard case let .timedOut(command, seconds) = error else {
                    Issue.record("expected .timedOut, got \(error)")
                    return
                }
                #expect(command.contains("sleep 60"))
                #expect(seconds == 1)
            }
        }
    #endif
}
