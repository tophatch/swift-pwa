#if os(Android)
    import CSwiftPWAAndroidJNI

    /// Emit `message` to logcat under the `swift-pwa` tag at INFO
    /// level. Wraps the C shim's `__android_log_print` because
    /// `print` / `FileHandle.standardError` go to `/dev/null` for
    /// app processes on Android by default; a logcat-friendly
    /// channel is what's actually visible via `adb logcat`. Public
    /// because users writing the `@_cdecl` JNI entry boilerplate
    /// (see `docs/android-setup.md`) need a way to surface
    /// diagnostics during bring-up.
    public func swiftPWALog(_ message: String) {
        message.withCString { swiftpwa_android_log($0) }
    }
#endif
