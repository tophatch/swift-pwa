import Foundation

/// Catches a custom-scheme OAuth redirect off the `app.openURL` event channel.
///
/// This half needs almost no new machinery: every backend already routes an
/// OS "open this URL" into ``OpenURL``'s bus channel — a `myapp://…` link from
/// Mail on macOS, an `ACTION_VIEW` intent on Android, a `.desktop`
/// `x-scheme-handler` on Linux, the registered `shell\open\command` on Windows.
/// The receiver subscribes for the length of one flow and resolves on the first
/// URL whose `state` matches. Anything else stays an ordinary deep link and
/// still reaches the page's own `on('app.openURL', …)`, because the bus fans out
/// rather than consuming.
///
/// **It subscribes before the browser opens, and buffers.** A redirect can
/// arrive before the awaiting task is parked — on mobile especially, where the
/// OS may resume the app and deliver the URL in the same breath — so a match
/// that lands early is held rather than dropped. That buffering is why this is
/// an `AsyncStream` rather than a hand-rolled continuation stashed under a lock:
/// `AsyncStream.Continuation` is built to be yielded to from any thread at any
/// time, including before anything is awaiting, which is exactly the shape here.
///
/// The hand-rolled version was also, empirically, the shape two Swift
/// toolchains couldn't survive on Linux: 6.3.1 crashed *compiling* it
/// (`swift-frontend` signal 11 in `ClosureLifetimeFixup`, no diagnostic), and
/// where it did compile, the test suite segfaulted inside
/// `CheckedContinuation.resume(returning:)` on the bus's emit thread. Both are
/// bugs in something other than this file, and neither is worth owning: this
/// version has no continuation bookkeeping to get wrong and is shorter.
///
/// **`state` is what makes a stale retained payload harmless.** The channel is
/// emitted *retained*, so subscribing replays the last URL the app received,
/// which for an app cold-started by a deep link is a URL from before this flow
/// existed. It can't match a `state` generated moments ago, so it is ignored by
/// the check that was going to run anyway rather than by a special case.
package final class SchemeRedirectReceiver: @unchecked Sendable {
    private let matches: AsyncStream<AuthorizationCallback>
    private let sink: AsyncStream<AuthorizationCallback>.Continuation
    private let lock = NSLock()
    private var subscription: EventSubscription?

    /// Subscribe. Call this *before* opening the browser.
    package init(events: EventBus, state: String) {
        (matches, sink) = AsyncStream<AuthorizationCallback>.makeStream()
        let sink = sink
        subscription = events.subscribe(OpenURL.channel) { payload in
            guard let callback = Self.match(payload: payload, state: state) else { return }
            sink.yield(callback)
        }
    }

    deinit { stop() }

    /// Wait for the matching callback, up to `timeout` seconds.
    package func waitForCallback(timeout: TimeInterval) async throws -> AuthorizationCallback {
        try await withThrowingTaskGroup(of: AuthorizationCallback.self) { group in
            group.addTask { [matches] in
                for await callback in matches { return callback }
                throw BridgeError(code: BridgeError.cancelled, message: "the sign-in was cancelled")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                throw BridgeError(
                    code: BridgeError.authTimeout,
                    message: "no redirect arrived on the app's URL scheme within the timeout"
                )
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw BridgeError(code: BridgeError.authTimeout, message: "the sign-in ended with no redirect")
            }
            return first
        }
    }

    /// Stop listening. Idempotent, and safe from any thread — including `deinit`
    /// and a cancelled task.
    package func stop() {
        lock.lock()
        let subscription = subscription
        self.subscription = nil
        lock.unlock()

        subscription?.cancel()
        sink.finish()
    }

    /// Pull the callback out of an `app.openURL` payload if one of its URLs
    /// carries the matching `state`.
    ///
    /// The payload carries `urls` *and* `url` (the first) because one OS event
    /// can open several — so this walks the list rather than reading `url`,
    /// which would miss a redirect that arrived alongside another deep link.
    static func match(payload: Data, state: String) -> AuthorizationCallback? {
        struct Payload: Decodable { let urls: [String]? }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: payload) else { return nil }
        for url in decoded.urls ?? [] {
            let parameters = queryItems(of: url)
            guard let received = parameters["state"], PKCE.constantTimeEquals(received, state) else { continue }
            return AuthorizationCallback(parameters: parameters)
        }
        return nil
    }

    /// Query parameters of a callback URL.
    ///
    /// Hand-rolled for the same reason the loopback receiver's is: these URLs
    /// are odd shapes (`com.googleusercontent.apps.123:/oauth2redirect?…`, a
    /// single-slash scheme-relative reference) that Darwin Foundation and
    /// swift-corelibs disagree about, and the disagreement shows up as "works on
    /// my Mac".
    static func queryItems(of url: String) -> [String: String] {
        guard let mark = url.firstIndex(of: "?") else { return [:] }
        let query = url[url.index(after: mark)...].prefix(while: { $0 != "#" })
        return LoopbackRedirectReceiver.parseFormEncoded(String(query))
    }
}
