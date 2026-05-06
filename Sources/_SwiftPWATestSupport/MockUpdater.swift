import Foundation
import SwiftPWACore

/// In-memory `Updater` for unit tests. State is `@MainActor`-isolated
/// so it satisfies `Sendable` without locks; the protocol itself isn't
/// `@MainActor` so tests still exercise the actor hop the real
/// backends rely on.
@MainActor
public final class MockUpdater: Updater {
    public enum Action: Sendable, Equatable {
        case check
        case download(UpdateInfo)
        case installAndRelaunch
    }

    public private(set) var actions: [Action] = []

    /// Result returned by the next `check()` call.
    public var nextCheckResult: UpdateInfo?

    /// Error to throw from the next `check()` call (set to `nil` to
    /// return `nextCheckResult` instead).
    public var nextCheckError: (any Error)?

    /// Events the next `download(_:)` call will yield, in order, before
    /// terminating. Defaults to a single-event stream that yields
    /// `.readyToInstall` straight away — the typical happy path.
    public var nextDownloadEvents: [UpdaterEvent] = [.readyToInstall]

    /// Optional error to terminate the next `download(_:)` stream with
    /// after yielding `nextDownloadEvents`.
    public var nextDownloadError: (any Error)?

    /// Error to throw from the next `installAndRelaunch()` call. The
    /// mock never actually relaunches anything; tests just assert that
    /// the call landed via `actions`.
    public var nextInstallError: (any Error)?

    public init() {}

    public func check() async throws -> UpdateInfo? {
        actions.append(.check)
        if let err = nextCheckError { throw err }
        return nextCheckResult
    }

    public nonisolated func download(_ info: UpdateInfo) -> AsyncThrowingStream<UpdaterEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                self.actions.append(.download(info))
                let events = self.nextDownloadEvents
                let error = self.nextDownloadError
                for event in events {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func installAndRelaunch() async throws {
        actions.append(.installAndRelaunch)
        if let err = nextInstallError { throw err }
    }
}
