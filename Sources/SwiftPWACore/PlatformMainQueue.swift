import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    // Bionic, not glibc — `canImport(Glibc)` is false on Android.
    import Android
#elseif canImport(WinSDK)
    import WinSDK
#endif

// Off Apple, these two symbols are libdispatch's integration point for a host
// that owns the main thread. They are the same ones CoreFoundation's run loop
// uses on Linux and Windows, declared here rather than behind a C shim because
// each backend already has its own shim and none of them is shared.
#if os(Linux) || os(Android)
    /// The eventfd libdispatch signals when the main queue goes from empty to
    /// non-empty. Level-triggered, and opened `O_NONBLOCK` by libdispatch.
    @_silgen_name("_dispatch_get_main_queue_handle_4CF")
    private func dispatchMainQueueHandle() -> Int32

    @_silgen_name("_dispatch_main_queue_callback_4CF")
    private func dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)
#elseif os(Windows)
    /// An auto-reset event, so waiting on it acknowledges the wakeup.
    @_silgen_name("_dispatch_get_main_queue_handle_4CF")
    private func dispatchMainQueueHandle() -> HANDLE?

    @_silgen_name("_dispatch_main_queue_callback_4CF")
    private func dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)
#endif

/// libdispatch's main queue, made reachable from a platform event loop.
///
/// **Why this exists.** ``MainThread`` routes *swift-pwa's own* UI work around
/// the problem; this is the other half, for the code swift-pwa doesn't own.
/// Off Apple, `MainActor` is backed by libdispatch's main queue, and that queue
/// is drained by exactly one thing: `dispatch_main()`. `gtk_main()`,
/// `GetMessageW` and Android's `Looper` each own the main thread instead and
/// drain nothing, so an adopting app's `@MainActor` class, `MainActor.run`, or
/// `Task { @MainActor in … }` is enqueued and never runs — no error, no
/// timeout, no stderr, just an `await` that never returns (#216).
///
/// An app written on macOS first *will* have main-actor code: it is what
/// Swift's concurrency model steers you toward for state that outlives a page
/// navigation. So the fix is to make it work rather than to document a rule.
///
/// **How.** libdispatch hands out a handle it signals whenever the main queue
/// has work. Each backend waits on that handle alongside its own events and
/// calls ``drain()`` when it fires, which is the same integration CoreFoundation
/// performs on Linux and Windows.
///
/// This also fixes `DispatchQueue.main.async`, which has the same single cause.
///
/// > Note: Apple backends need none of this — `NSApplicationMain` /
/// > `UIApplicationMain` drain the main queue themselves — so the whole type is
/// > compiled out there.
public enum PlatformMainQueue {
    #if os(Linux) || os(Android)
        /// The file descriptor to watch for readability. `nil` when libdispatch
        /// has no main-queue handle to offer.
        public static var handle: Int32? {
            let fd = dispatchMainQueueHandle()
            return fd < 0 ? nil : fd
        }
    #elseif os(Windows)
        /// The event to wait on. `nil` when libdispatch has no main-queue
        /// handle to offer.
        public static var handle: HANDLE? {
            dispatchMainQueueHandle()
        }
    #endif

    #if os(Linux) || os(Android) || os(Windows)
        /// Run everything libdispatch has queued on the main queue. Call this
        /// from the platform's event loop, on the main thread, when ``handle``
        /// signals.
        public static func drain() {
            #if os(Linux) || os(Android)
                // The eventfd is level-triggered, so it stays readable until
                // someone reads it — a watch that only drains the queue spins
                // the loop at 100% CPU (measured: 2.9M iterations in 2 s).
                // Acknowledge *before* draining, so work enqueued while we
                // drain re-signals the fd instead of being lost.
                if let fd = handle {
                    var value: UInt64 = 0
                    _ = withUnsafeMutableBytes(of: &value) { buffer in
                        read(fd, buffer.baseAddress, buffer.count)
                    }
                }
            #endif
            dispatchMainQueueCallback(nil)
        }
    #endif
}
