#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `LocationManager`-backed ``GeolocationProvider``, over the Kotlin RPC
    /// bridge.
    ///
    /// **Not `FusedLocationProviderClient`.** Fused lives in Play Services, and
    /// pulling a Google dependency into every generated project to reach what
    /// is otherwise a framework API is a poor trade — worse on a device with no
    /// Play Services at all, where fused simply isn't there. `LocationManager`
    /// is in the platform, on every device.
    ///
    /// Android needs the OS runtime permission on top of the app's own
    /// declaration, and only an Activity can ask for it — so the Kotlin side
    /// requests it, exactly as it does for a WebView capture request.
    public final class SystemGeolocation: GeolocationProvider, @unchecked Sendable {
        public init() {}

        private struct Args: Encodable {
            var accuracy: String
            var timeoutSeconds: Double?
            var maximumAgeSeconds: Double?
            var channel: String?
        }

        /// Kotlin answers with a fix or a classified failure, rather than a
        /// bare error string — so the three `GeoError` cases survive the trip
        /// instead of being re-derived by sniffing a message.
        private struct Reply: Decodable {
            var ok: Bool
            var fix: GeoFix?
            var kind: String?
            var message: String?
            var id: Int?
        }

        private static func error(from reply: Reply) -> GeoError {
            let message = reply.message ?? "location failed"
            return switch reply.kind {
            case "denied": .denied(message)
            case "timeout": .timedOut(message)
            default: .unavailable(message)
            }
        }

        public func current(_ request: GeoRequest) async throws -> GeoFix {
            let reply: Reply = try await AndroidRPC.call("geo.current", Args(
                accuracy: request.accuracy.rawValue,
                timeoutSeconds: request.timeoutSeconds ?? 20,
                maximumAgeSeconds: request.maximumAgeSeconds,
                channel: nil
            ))
            guard reply.ok, let fix = reply.fix else { throw Self.error(from: reply) }
            return fix
        }

        public func watch(_ request: GeoRequest) -> AsyncThrowingStream<GeoFix, any Error> {
            AsyncThrowingStream { continuation in
                // Each watch gets its own channel, so two subscribers don't
                // land in each other's stream.
                let channel = "geo.watch.\(UUID().uuidString)"
                struct Update: Decodable { let fix: GeoFix }
                AndroidHostEventRouter.subscribe(channel: channel) { data in
                    guard let update = try? JSONDecoder().decode(Update.self, from: data) else { return }
                    continuation.yield(update.fix)
                }

                // `start` is a round trip, so an unsubscribe can land before
                // there's an id to stop. One piece of shared state decides
                // which side does the stopping, and `onTermination` is
                // assigned exactly once — assigning it twice would leave the
                // winner up to timing, and a lost stop means the sensor keeps
                // running with nobody listening.
                let state = WatchState()

                let task = Task {
                    do {
                        let reply: Reply = try await AndroidRPC.call("geo.watch.start", Args(
                            accuracy: request.accuracy.rawValue,
                            timeoutSeconds: nil,
                            maximumAgeSeconds: nil,
                            channel: channel
                        ))
                        guard reply.ok, let id = reply.id else {
                            throw Self.error(from: reply).bridgeError
                        }
                        if state.adopt(id: id) {
                            // Already unsubscribed while we were starting.
                            try? await AndroidRPC.call(
                                "geo.watch.stop", ["id": id], as: NoResult.self
                            )
                        }
                    } catch {
                        AndroidHostEventRouter.unsubscribe(channel: channel)
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { _ in
                    AndroidHostEventRouter.unsubscribe(channel: channel)
                    task.cancel()
                    if let id = state.cancel() {
                        // Fire-and-forget: nothing is left to report to, but
                        // the sensor has to stop.
                        Task { try? await AndroidRPC.call(
                            "geo.watch.stop", ["id": id], as: NoResult.self
                        ) }
                    }
                }
            }
        }
    }

    /// Decides whether the starting task or the unsubscribe performs the stop,
    /// so exactly one of them does and neither has to guess about timing.
    private final class WatchState: @unchecked Sendable {
        private let lock = NSLock()
        private var id: Int?
        private var cancelled = false

        /// Record the started watch. Returns true when the subscriber already
        /// went away, meaning the caller must stop it immediately.
        func adopt(id: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return true }
            self.id = id
            return false
        }

        /// Mark the watch cancelled, returning the id to stop when one exists.
        func cancel() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            let started = id
            id = nil
            return started
        }
    }
#endif
