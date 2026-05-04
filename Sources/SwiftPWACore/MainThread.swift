import Foundation

/// Platform-aware "run this on the UI thread" abstraction.
///
/// **Why not just `MainActor.run`?** On Apple platforms `NSApplication.run`
/// / `UIApplicationMain` integrate with Swift's main-actor executor, so
/// awaiting a `MainActor.run` from a background task works as expected.
/// On Linux, `gtk_main()` doesn't pump libdispatch's main queue — which
/// is what Swift's `MainActor` is backed by — so any `await MainActor.run`
/// from a non-main thread hangs forever once `gtk_main` is running.
///
/// `MainThread.run` solves this by routing the closure through a
/// platform-specific *dispatch hook* that backends register at startup.
/// The closure is still `@MainActor`-annotated (so the compile-time
/// safety on `Window`, `NSWindow`, etc. is preserved), and the hook
/// uses `MainActor.assumeIsolated` to satisfy Swift's runtime check
/// once it's actually running on the UI thread.
public enum MainThread {
    public typealias Dispatcher = @Sendable (@escaping @Sendable () -> Void) -> Void

    private static let lock = NSLock()
    private nonisolated(unsafe) static var _hook: Dispatcher?

    /// Register the platform's UI-thread dispatcher. Apple backends
    /// register a `DispatchQueue.main`-based hook; the GTK backend
    /// registers one that schedules via `g_idle_add`.
    public static func setHook(_ hook: @escaping Dispatcher) {
        lock.lock(); defer { lock.unlock() }
        _hook = hook
    }

    private static func currentHook() -> Dispatcher {
        lock.lock(); defer { lock.unlock() }
        return _hook ?? defaultHook
    }

    /// Safe default for environments that haven't installed a hook yet
    /// (e.g. unit tests). On Apple platforms `DispatchQueue.main`
    /// integrates with Swift's MainActor executor, so this works under
    /// XCTest. On Linux under `gtk_main()` the GTK runtime overrides
    /// this with a `g_idle_add`-based hook because libdispatch's main
    /// queue isn't being drained.
    private static let defaultHook: Dispatcher = { body in
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async { body() }
        }
    }

    /// Run `body` on the UI thread and return its result.
    public static func run<T: Sendable>(
        _ body: @escaping @MainActor @Sendable () throws -> T
    ) async throws -> T {
        let hook = currentHook()
        return try await withCheckedThrowingContinuation { continuation in
            hook {
                MainActor.assumeIsolated {
                    do {
                        try continuation.resume(returning: body())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Convenience for non-throwing closures.
    public static func run<T: Sendable>(
        _ body: @escaping @MainActor @Sendable () -> T
    ) async -> T {
        let hook = currentHook()
        return await withCheckedContinuation { continuation in
            hook {
                MainActor.assumeIsolated {
                    continuation.resume(returning: body())
                }
            }
        }
    }
}
