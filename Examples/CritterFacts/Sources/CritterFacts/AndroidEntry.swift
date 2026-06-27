#if os(Android)
    import Foundation
    import SwiftPWA

    /// JNI entry point for the generated `MainActivity.swiftPwaMain()` Kotlin
    /// declaration. The symbol name is JNI-mangled
    /// (`Java_<package>_<class>_<method>`, dots → underscores) and must stay in
    /// lockstep with `pwa.json`'s `android.package_id`
    /// (`com.swiftpwa.critterfacts`). See HelloPWA's `AndroidEntry.swift` for
    /// the full rationale behind the `dispatchMain()` / `AndroidAppRuntime`
    /// dance — it's identical here.
    @_cdecl("Java_com_swiftpwa_critterfacts_MainActivity_swiftPwaMain")
    public func swiftpwa_critterFacts_android_main(
        _ env: OpaquePointer?,
        _ thiz: OpaquePointer?
    ) {
        _ = env
        _ = thiz
        swiftPWALog("entry: swiftPwaMain enter")
        // Construct the concrete runtime directly so the call uses its
        // `nonisolated run(_:)` (the `any AppRuntime` protocol witness is
        // `@MainActor`, which needs an actor hop the platform can't provide on
        // a fresh worker thread).
        let runtime = AndroidAppRuntime()
        do {
            try runtime.run(configure)
        } catch {
            swiftPWALog("entry: caught error: \(error)")
        }
    }
#endif
