#if canImport(CoreLocation)
    import CoreLocation
    import Foundation
    import SwiftPWACore

    /// CoreLocation-backed ``GeolocationProvider`` for macOS and iOS.
    ///
    /// This is the backend that makes the plugin worth having: on **macOS**,
    /// WKWebView offers an embedder no public way to grant `navigator.geolocation`
    /// at all, so a page there is denied no matter what the app does. CoreLocation
    /// reaches the same hardware directly, and the app carries the usage
    /// description that authorizes it.
    ///
    /// **Info.plist.** `NSLocationWhenInUseUsageDescription` must be present or
    /// the OS refuses the request — and on iOS it *terminates the process*.
    /// `permissions.web`'s `reason` emits it; without a bundle (a bare
    /// `swift run`) there's no Info.plist to read and the request is refused,
    /// which is why location work has to be checked against a real `.app`.
    public final class SystemGeolocation: NSObject, GeolocationProvider, @unchecked Sendable {
        /// Serialises access to the manager and the waiting continuations.
        /// CoreLocation delivers on the main run loop; the bridge calls in from
        /// the cooperative pool, so neither side can be assumed.
        private let lock = NSLock()
        private var manager: CLLocationManager?
        private var oneShots: [(id: UUID, request: GeoRequest, resume: (Result<GeoFix, any Error>) -> Void)] = []
        private var watchers: [UUID: AsyncThrowingStream<GeoFix, any Error>.Continuation] = [:]

        override public init() { super.init() }

        // MARK: - GeolocationProvider

        public func current(_ request: GeoRequest) async throws -> GeoFix {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    var resumed = false
                    let resumeOnce: (Result<GeoFix, any Error>) -> Void = { result in
                        // CoreLocation can report a failure and then a fix (or
                        // several fixes); a continuation may only be resumed once.
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(with: result)
                    }
                    lock.withLock { oneShots.append((id, request, resumeOnce)) }
                    // `MainThread.run` is async and this is a continuation body,
                    // so the hop is a detached task. Safe because the pending
                    // entry is registered above, before the hop.
                    Task { await MainThread.run { self.startOneShot(id: id, request: request) } }
                }
            } onCancel: {
                finishOneShot(id: id, with: .failure(GeoError.timedOut("the request was cancelled")))
            }
        }

        public func watch(_ request: GeoRequest) -> AsyncThrowingStream<GeoFix, any Error> {
            AsyncThrowingStream { continuation in
                let id = UUID()
                lock.withLock { watchers[id] = continuation }
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    lock.withLock { _ = watchers.removeValue(forKey: id) }
                    // Stop the hardware once nothing is listening — a watch the
                    // page can no longer see is pure battery drain.
                    Task { await MainThread.run { self.stopIfIdle() } }
                }
                Task { await MainThread.run { self.startWatching(request) } }
            }
        }

        // MARK: - CoreLocation, on the main thread

        @MainActor
        private func ensureManager(_ request: GeoRequest) -> CLLocationManager {
            let existing = lock.withLock { manager }
            if let existing {
                existing.desiredAccuracy = Self.desiredAccuracy(request.accuracy)
                return existing
            }
            let created = CLLocationManager()
            created.delegate = self
            created.desiredAccuracy = Self.desiredAccuracy(request.accuracy)
            lock.withLock { manager = created }
            return created
        }

        @MainActor
        private func startOneShot(id: UUID, request: GeoRequest) {
            let manager = ensureManager(request)
            guard authorize(manager) else {
                finishOneShot(id: id, with: .failure(GeoError.denied(
                    "location services are off, or this app isn't allowed to use them"
                )))
                return
            }
            // `requestLocation` delivers one fix and stops by itself, which is
            // exactly the one-shot contract — and cheaper than starting updates
            // and remembering to stop them.
            manager.requestLocation()

            if let timeout = request.timeoutSeconds {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self?.finishOneShot(id: id, with: .failure(GeoError.timedOut(
                        "no fix within \(timeout)s"
                    )))
                }
            }
        }

        @MainActor
        private func startWatching(_ request: GeoRequest) {
            let manager = ensureManager(request)
            guard authorize(manager) else {
                let denied = GeoError.denied(
                    "location services are off, or this app isn't allowed to use them"
                ).bridgeError
                let continuations = lock.withLock {
                    let all = Array(watchers.values)
                    watchers.removeAll()
                    return all
                }
                for continuation in continuations { continuation.finish(throwing: denied) }
                return
            }
            manager.startUpdatingLocation()
        }

        /// Ask for authorization if it hasn't been decided, and report whether
        /// proceeding is worthwhile. `notDetermined` is treated as worth trying:
        /// the request is what raises the prompt, and the delegate callback
        /// delivers the answer.
        @MainActor
        private func authorize(_ manager: CLLocationManager) -> Bool {
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
                return true
            case .restricted, .denied:
                return false
            default:
                return true
            }
        }

        @MainActor
        private func stopIfIdle() {
            let idle = lock.withLock { watchers.isEmpty && oneShots.isEmpty }
            guard idle, let manager = lock.withLock({ manager }) else { return }
            manager.stopUpdatingLocation()
        }

        // MARK: - Fan-out

        private func finishOneShot(id: UUID, with result: Result<GeoFix, any Error>) {
            let resume = lock.withLock { () -> ((Result<GeoFix, any Error>) -> Void)? in
                guard let index = oneShots.firstIndex(where: { $0.id == id }) else { return nil }
                return oneShots.remove(at: index).resume
            }
            resume?(result)
        }

        private func deliver(_ fix: GeoFix) {
            let (pending, watching) = lock.withLock {
                let shots = oneShots
                oneShots.removeAll()
                return (shots, Array(watchers.values))
            }
            for shot in pending { shot.resume(.success(fix)) }
            for continuation in watching { continuation.yield(fix) }
        }

        private func deliver(_ error: any Error) {
            let (pending, watching) = lock.withLock {
                let shots = oneShots
                oneShots.removeAll()
                return (shots, Array(watchers.values))
            }
            for shot in pending { shot.resume(.failure(error)) }
            // Watchers survive a transient error: CoreLocation reports
            // `kCLErrorLocationUnknown` while it's still trying, and tearing the
            // stream down there would turn a slow fix into a failed one.
            _ = watching
        }

        private static func desiredAccuracy(_ accuracy: GeoAccuracy) -> CLLocationAccuracy {
            switch accuracy {
            case .high: kCLLocationAccuracyBest
            case .balanced: kCLLocationAccuracyHundredMeters
            }
        }

        fileprivate static func fix(from location: CLLocation) -> GeoFix {
            GeoFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                // CoreLocation reports a negative accuracy for "invalid". The
                // web contract has no such value, so an unknown accuracy becomes
                // a large number rather than 0 — claiming perfection would be
                // the one genuinely dangerous answer.
                accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : 10000,
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                altitudeAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
                heading: location.course >= 0 ? location.course : nil,
                speed: location.speed >= 0 ? location.speed : nil,
                timestamp: location.timestamp.timeIntervalSince1970
            )
        }
    }

    extension SystemGeolocation: CLLocationManagerDelegate {
        public func locationManager(
            _: CLLocationManager, didUpdateLocations locations: [CLLocation]
        ) {
            guard let latest = locations.last else { return }
            deliver(Self.fix(from: latest))
        }

        public func locationManager(_: CLLocationManager, didFailWithError error: any Error) {
            let code = (error as NSError).code
            if code == CLError.denied.rawValue {
                deliver(GeoError.denied("the user or system denied location access"))
            } else if code == CLError.locationUnknown.rawValue {
                // "Still trying" rather than a failure — don't resolve on it.
                return
            } else {
                deliver(GeoError.unavailable("CoreLocation failed: \(error.localizedDescription)"))
            }
        }

        public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            // The answer to a prompt raised by `authorize`. A refusal has to be
            // delivered, or a `geo.current` awaiting consent hangs until its
            // timeout for a question the user already answered.
            switch manager.authorizationStatus {
            case .denied, .restricted:
                deliver(GeoError.denied("the user denied location access"))
            default:
                return
            }
        }
    }
#endif
