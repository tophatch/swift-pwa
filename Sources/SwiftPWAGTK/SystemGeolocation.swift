#if os(Linux)
    import CGeoClueShim
    import Foundation
    import SwiftPWACore

    /// GeoClue 2 ``GeolocationProvider`` for both Linux backends.
    ///
    /// GeoClue is push-based: a client is started, and positions arrive as
    /// `LocationUpdated` signals until it's stopped. `watch` is therefore the
    /// natural shape and `current` is built on it — start, take the first fix,
    /// stop — rather than the other way round, which would have meant polling
    /// a service designed not to be polled.
    ///
    /// **`desktopId`** is not decoration. GeoClue refuses to start a client
    /// without one, uses it to tell the user which app is asking, and a
    /// distro's `geoclue.conf` allowlists callers by it. It defaults to the
    /// executable name, which matches the `.desktop` file the AppImage bundler
    /// writes.
    public final class SystemGeolocation: GeolocationProvider, @unchecked Sendable {
        private let desktopId: String

        public init(desktopId: String? = nil) {
            self.desktopId = desktopId
                ?? ProcessInfo.processInfo.processName
        }

        public func current(_ request: GeoRequest) async throws -> GeoFix {
            // The first fix off a watch. GeoClue has no one-shot call, and
            // asking it repeatedly is what its own docs tell you not to do.
            for try await fix in watch(request) {
                return fix
            }
            throw GeoError.unavailable("GeoClue produced no position")
        }

        public func watch(_ request: GeoRequest) -> AsyncThrowingStream<GeoFix, any Error> {
            let desktopId = desktopId
            let accuracy: UInt32 = request.accuracy == .high
                ? SWIFTPWA_GEOCLUE_ACCURACY_EXACT
                : SWIFTPWA_GEOCLUE_ACCURACY_CITY

            return AsyncThrowingStream { continuation in
                let box = Unmanaged.passRetained(GeoSessionBox(continuation)).toOpaque()
                var errorPointer: UnsafeMutablePointer<CChar>?

                let session = desktopId.withCString { id in
                    swiftpwa_geoclue_start(id, accuracy, geoUpdateTrampoline, box, &errorPointer)
                }

                guard let session else {
                    let message = errorPointer.map { pointer -> String in
                        defer { g_free(UnsafeMutableRawPointer(pointer)) }
                        return String(cString: pointer)
                    } ?? "GeoClue is not available"
                    Unmanaged<GeoSessionBox>.fromOpaque(box).release()
                    // "This machine, right now" — no daemon, no agent for this
                    // desktop id, or no source it's allowed to use. Never a
                    // statement about Linux.
                    continuation.finish(throwing: GeoError.unavailable(message).bridgeError)
                    return
                }

                // Laundered through `UInt` for strict concurrency, the same
                // way the backends carry a `GtkWidget*` across an actor
                // boundary: a raw pointer isn't `Sendable`, and this closure
                // escapes.
                let sessionBits = UInt(bitPattern: session)
                let boxBits = UInt(bitPattern: box)
                continuation.onTermination = { _ in
                    // Stops the client on the daemon *and* joins the shim's
                    // thread, so an unsubscribed watch leaves nothing running.
                    if let session = UnsafeMutablePointer<swiftpwa_geo_session>(bitPattern: sessionBits) {
                        swiftpwa_geoclue_stop(session)
                    }
                    if let box = UnsafeMutableRawPointer(bitPattern: boxBits) {
                        Unmanaged<GeoSessionBox>.fromOpaque(box).release()
                    }
                }
            }
        }
    }

    /// Heap box carrying the stream's continuation across the C boundary.
    /// `@unchecked Sendable` because an `AsyncThrowingStream.Continuation` is
    /// itself thread-safe, and the shim calls back from its own thread.
    final class GeoSessionBox: @unchecked Sendable {
        let continuation: AsyncThrowingStream<GeoFix, any Error>.Continuation
        init(_ continuation: AsyncThrowingStream<GeoFix, any Error>.Continuation) {
            self.continuation = continuation
        }
    }

    /// `@convention(c)` callback for `swiftpwa_geoclue_start`, invoked on the
    /// shim's GeoClue thread for each `LocationUpdated`.
    let geoUpdateTrampoline: @convention(c) (
        UnsafePointer<swiftpwa_geo_fix>?, UnsafeMutableRawPointer?
    ) -> Void = { raw, userData in
        guard let raw, let userData else { return }
        let fix = raw.pointee
        let box = Unmanaged<GeoSessionBox>.fromOpaque(userData).takeUnretainedValue()
        box.continuation.yield(GeoFix(
            latitude: fix.latitude,
            longitude: fix.longitude,
            accuracy: fix.accuracy,
            altitude: fix.has_altitude != 0 ? fix.altitude : nil,
            // GeoClue reports no vertical-accuracy figure at all, so claiming
            // one would be inventing precision.
            altitudeAccuracy: nil,
            heading: fix.has_heading != 0 ? fix.heading : nil,
            speed: fix.has_speed != 0 ? fix.speed : nil,
            timestamp: fix.timestamp
        ))
    }
#endif
