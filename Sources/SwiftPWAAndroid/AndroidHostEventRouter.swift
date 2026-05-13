#if os(Android)
    import Foundation

    /// Dispatcher for host-side events pushed from Kotlin to Swift
    /// outside the JS bridge envelope and the request/response RPC
    /// shape — currently the `PackageInstaller.STATUS_*` broadcasts
    /// the `AndroidUpdater` install pipeline observes, with the
    /// expectation that future asynchronous Activity hooks (intent
    /// extras, lifecycle callbacks) will reuse the same channel.
    ///
    /// Each event is a JSON object with a string `channel` field used
    /// for routing; the remainder of the payload is opaque to the
    /// router and forwarded as-is to whichever subscriber owns the
    /// channel name.
    ///
    /// Subscriptions are single-slot per channel: registering a new
    /// handler for an existing channel replaces the prior one. This
    /// mirrors the rest of the Android backend's single-instance
    /// assumptions (one Activity, one updater, …) and avoids
    /// surprising fan-out behavior.
    public enum AndroidHostEventRouter {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var subscribers: [String: @Sendable (Data) -> Void] = [:]

        /// Subscribe to `channel`. Replaces any prior subscription.
        public static func subscribe(
            channel: String,
            _ handler: @escaping @Sendable (Data) -> Void
        ) {
            lock.withLock { subscribers[channel] = handler }
        }

        /// Drop the subscription for `channel`. No-op if none exists.
        public static func unsubscribe(channel: String) {
            _ = lock.withLock { subscribers.removeValue(forKey: channel) }
        }

        /// Called by the JNI dispatch trampoline registered in
        /// `AndroidAppRuntime.run`. Parses the `channel` field out of
        /// `jsonString` and forwards to the matching subscriber.
        /// Silently drops payloads that don't decode or have no
        /// subscriber — a stale broadcast arriving after the
        /// AndroidUpdater is gone is a no-op rather than a crash.
        static func dispatch(jsonString: String) {
            guard let data = jsonString.data(using: .utf8) else { return }
            struct Envelope: Decodable { let channel: String }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
            let handler = lock.withLock { subscribers[envelope.channel] }
            handler?(data)
        }
    }
#endif
