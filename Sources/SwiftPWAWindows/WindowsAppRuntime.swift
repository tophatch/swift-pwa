#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// Windows-side runtime. Drives a Win32 message pump.
    ///
    /// The flow mirrors the GTK side rather than AppKit's:
    ///
    /// 1. **MainThread dispatch hook** — wires `MainThread.run` to a
    ///    hidden message-only window whose WndProc fires queued
    ///    closures off `WM_APP+1`. Without this, `BridgeRuntime` and
    ///    `WindowPlugin` would hang awaiting Swift's MainActor
    ///    executor (which isn't pumped by `GetMessageW`).
    /// 2. **WebView2 environment** — created up front, before the
    ///    `configure` closure runs, because every `Win32Window`
    ///    spawned during configure needs the env to attach a
    ///    controller. The env-creation callback is asynchronous, so
    ///    we pump just enough messages to let it complete before
    ///    handing the context to `configure`.
    /// 3. **`configure` closure** runs synchronously so windows it
    ///    creates are realized before the main pump starts.
    /// 4. The standard `GetMessageW` / `TranslateMessage` /
    ///    `DispatchMessageW` loop runs until `quit()` posts
    ///    `WM_QUIT`.
    public final class WindowsAppRuntime: AppRuntime {
        public init() {}

        @MainActor
        public func run(
            _ configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) throws -> Never {
            // OLE init is required by WebView2 (Microsoft's docs say
            // single-threaded apartment); call it before anything else.
            _ = OleInitialize(nil)

            // Friendlier failure if the WebView2 Runtime is missing —
            // surface it before we kick off async env creation.
            let runtimeHR = swiftpwa_w2_check_runtime()
            if runtimeHR != 0 {
                FileHandle.standardError.write(Data("""
                swift-pwa: WebView2 Runtime not found (HRESULT 0x\(String(UInt32(bitPattern: runtimeHR), radix: 16))).
                Install the Evergreen Runtime from:
                https://developer.microsoft.com/en-us/microsoft-edge/webview2/

                """.utf8))
                exit(1)
            }

            installMainThreadHook()

            let context = WindowsAppContext.shared
            // Bootstrap the WebView2 environment. The callback fires on
            // the same thread we're running on, so we just need to pump
            // until the context's `environment` is populated.
            createEnvironment(into: context)
            pumpUntil { context.environmentReady }

            do {
                try configure(context)
            } catch {
                FileHandle.standardError.write(
                    Data("swift-pwa: configure threw: \(error)\n".utf8)
                )
            }

            var msg = MSG()
            // Swift's WinSDK overlay imports `GetMessageW` as
            // returning `Bool` rather than the C `BOOL` (Int32). We
            // lose the distinction between the WM_QUIT (returns 0)
            // and error (returns -1) cases, but for our purposes
            // both terminate the loop.
            while GetMessageW(&msg, nil, 0, 0) {
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }

            OleUninitialize()
            exit(context.pendingExitCode ?? 0)
        }

        // MARK: - WebView2 environment bootstrap

        private func createEnvironment(into context: WindowsAppContext) {
            let user = Unmanaged.passRetained(EnvBox(context: context)).toOpaque()
            // `nil` = default user-data folder under %LOCALAPPDATA%.
            swiftpwa_w2_create_environment(nil, envReadyTrampoline, user)
        }

        /// Pump messages until `cond` returns true. Used during startup
        /// to wait on async COM completion without blocking the calling
        /// thread (which would deadlock the WebView2 callback chain).
        private func pumpUntil(_ cond: () -> Bool) {
            var msg = MSG()
            while !cond() {
                if !GetMessageW(&msg, nil, 0, 0) { break }
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
        }

        // MARK: - MainThread hook

        /// The main-thread dispatcher is a hidden message-only window
        /// owned by this runtime. We post `WM_APP+1` to it carrying a
        /// heap-boxed closure pointer; its WndProc unboxes and fires.
        private func installMainThreadHook() {
            // HWND imports as `UnsafeMutablePointer<HWND__>` (a
            // pointer to an opaque tag struct), which isn't
            // `Sendable`. Wrap it in a class we mark
            // `@unchecked Sendable` ourselves: the dispatcher
            // window lives for the lifetime of the process and is
            // never written to, so capturing it across the hook's
            // closure boundary is safe.
            let box = HWNDBox(MainThreadDispatcher.create())
            MainThread.setHook { body in
                MainThreadDispatcher.post(to: box.hwnd, body: body)
            }
        }
    }

    // MARK: - Env-ready boxing

    final class EnvBox {
        weak var context: WindowsAppContext?
        init(context: WindowsAppContext) { self.context = context }
    }

    /// `@unchecked Sendable` wrapper for an HWND we need to capture
    /// across a Sendable closure boundary. The Win32 HWND type imports
    /// as `UnsafeMutablePointer<HWND__>`, which isn't `Sendable`; the
    /// safety here comes from the dispatcher window living for the
    /// lifetime of the process and being treated as immutable.
    final class HWNDBox: @unchecked Sendable {
        let hwnd: HWND
        init(_ hwnd: HWND) { self.hwnd = hwnd }
    }

    /// `@convention(c)` callback fired by the WebView2 shim once the
    /// environment is created. Always runs on the same thread that
    /// called `swiftpwa_w2_create_environment` — i.e. the UI thread.
    let envReadyTrampoline: @convention(c) (
        OpaquePointer?, Int32, UnsafeMutableRawPointer?
    ) -> Void = { envPtr, hr, userData in
        guard let userData else { return }
        let box = Unmanaged<EnvBox>.fromOpaque(userData).takeRetainedValue()
        guard let context = box.context else {
            if let envPtr { swiftpwa_w2_env_release(envPtr) }
            return
        }
        if hr != 0 || envPtr == nil {
            FileHandle.standardError.write(Data(
                "swift-pwa: CreateCoreWebView2Environment failed: 0x\(String(UInt32(bitPattern: hr), radix: 16))\n".utf8
            ))
            context.environmentReady = true
            return
        }
        // `nonisolated(unsafe)` on the local because Swift 6.3's
        // strict-concurrency check otherwise refuses to capture the
        // `OpaquePointer?` env handle into the
        // `MainActor.assumeIsolated` closure.
        nonisolated(unsafe) let env = envPtr
        MainActor.assumeIsolated {
            context.installEnvironment(env)
        }
    }
#endif
