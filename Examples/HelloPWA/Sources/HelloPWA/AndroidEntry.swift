#if os(Android)
    import Foundation
    import SwiftPWA

    /// JNI entry point for the generated `MainActivity.swiftPwaMain()`
    /// Kotlin declaration. The symbol name is mangled per JNI's rules
    /// (`Java_<package>_<class>_<method>` with dots replaced by
    /// underscores) and must stay in lockstep with `pwa.json`'s
    /// `android.package_id` — change one and the other has to change
    /// too. Codegen for this is on the v0.5.x roadmap; until then,
    /// the boilerplate lives in one file per app.
    ///
    /// Called from the Kotlin worker thread the activity spawns
    /// (see `MainActivity.kt`'s
    /// `thread(name = "swift-pwa-runtime") { swiftPwaMain() }`). On
    /// Android, `AndroidAppRuntime.run` blocks this thread on a
    /// semaphore until `quit(exitCode:)` is invoked, then `exit()`s
    /// the process — so this function never returns under normal
    /// operation.
    @_cdecl("Java_com_swiftpwa_hello_MainActivity_swiftPwaMain")
    public func swiftpwa_helloPWA_android_main(
        _ env: OpaquePointer?,
        _ thiz: OpaquePointer?
    ) {
        _ = env
        _ = thiz

        // `AppRuntime.run(_:)` is `@MainActor`-isolated by the
        // protocol. On Android, Swift's MainActor is backed by
        // libdispatch's main queue — and `MainActor.assumeIsolated`
        // is strictly enforced via `dispatch_assert_queue(main)`,
        // so we can't satisfy the isolation requirement on a fresh
        // worker thread. The fix is to *become* the dispatch main
        // queue: schedule the runtime entry as the first block on
        // the main queue, then call `dispatchMain()` to take over
        // this thread and drain the queue. The block runs on the
        // dispatch main queue (so `assumeIsolated` is happy) and
        // `runtime.run` then blocks the same thread on its
        // semaphore until `quit(exitCode:)` releases it and calls
        // `exit()`.
        //
        // Note: while `runtime.run` is blocking, no other
        // `DispatchQueue.main.async` block can run on this thread.
        // The Android backend is designed to not need them — JNI
        // inbound frames stay on binder threads and call into
        // `AndroidAppContext.routeInbound` directly without a
        // MainActor hop, and UI calls go through `MainThread.run`'s
        // JNI hook to Android's Looper (a different thread from
        // the dispatch main queue).
        // `AndroidAppRuntime.run` is `nonisolated` despite the
        // `AppRuntime` protocol declaring it `@MainActor` — see the
        // implementation comment for why MainActor on Android isn't
        // useful. We construct the concrete type directly so the
        // call uses the type's nonisolated declaration; routing
        // through `SwiftPWA.runtime()` (which returns
        // `any AppRuntime`) would erase the type and the call site
        // would fall back to the protocol's @MainActor witness,
        // which then needs an actor hop the platform can't provide.
        swiftPWALog("entry: swiftPwaMain enter")
        let runtime = AndroidAppRuntime()
        do {
            try runtime.run(configure)
        } catch {
            swiftPWALog("entry: caught error: \(error)")
        }
    }
#endif
