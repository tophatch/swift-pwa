#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// Windows-side runtime. Drives a Win32 message pump.
    ///
    /// The flow mirrors the GTK side rather than AppKit's:
    ///
    /// 1. **Process bootstrap** — DPI awareness, AppUserModelID for
    ///    toasts, OLE init.
    /// 2. **MainThread dispatch hook** — wires `MainThread.run` to a
    ///    hidden message-only window whose WndProc fires queued
    ///    closures off `WM_APP+1`. Without this, `BridgeRuntime` and
    ///    `WindowPlugin` would hang awaiting Swift's MainActor
    ///    executor (which isn't pumped by `GetMessageW`).
    /// 3. **WebView2 environment** — created up front, before the
    ///    `configure` closure runs, because every `Win32Window`
    ///    spawned during configure needs the env to attach a
    ///    controller. The env-creation callback is asynchronous, so
    ///    we pump just enough messages to let it complete before
    ///    handing the context to `configure`.
    /// 4. **`configure` closure** runs synchronously so windows it
    ///    creates are realized before the main pump starts.
    /// 5. The standard `GetMessageW` / `TranslateMessage` /
    ///    `DispatchMessageW` loop runs until `quit()` posts
    ///    `WM_QUIT`.
    public final class WindowsAppRuntime: AppRuntime {
        public init() {}

        @MainActor
        public func run(
            _ configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) throws -> Never {
            // Codegen headless catalog dump (roadmap #6): if SWIFT_PWA_DESCRIBE
            // is set, this writes the command catalog and exits before any
            // Win32 / WebView2 bootstrap; otherwise it returns and we launch
            // normally.
            HeadlessDescribe.dumpIfRequested(configure)

            // Per-Monitor V2 DPI awareness. Has to fire before any
            // window is created, before any HDC is queried — Windows
            // latches the awareness once the process becomes
            // DPI-aware. Failures (e.g. a manifest already declared
            // a different awareness) are non-fatal: the previous
            // awareness sticks and our coordinate conversions will
            // still produce sensible-but-not-pixel-perfect output.
            //
            // We use `SetProcessDpiAwarenessContext` (Win10 1703+)
            // rather than the older `SetProcessDPIAware` / Shcore
            // APIs — V2 is the only mode where non-client area
            // (titlebar, scroll bars) scales correctly with the
            // monitor.
            _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

            // AppUserModelID for WinRT toast notifications. Without an
            // AUMID, `ToastNotificationManager.CreateToastNotifier()`
            // refuses to manufacture a notifier from an unpackaged
            // process. We derive a stable id from the executable
            // basename — apps that want a specific Start-menu-
            // matched AUMID can re-run `SetCurrentProcessExplicitAppUserModelID`
            // before importing Notifications.
            let aumid = derivedAppUserModelID()
            aumid.withCString(encodedAs: UTF16.self) { wcs in
                _ = SetCurrentProcessExplicitAppUserModelID(wcs)
                _ = swiftpwa_toast_init(wcs)
            }

            // OLE init is required by WebView2 (Microsoft's docs say
            // single-threaded apartment); call it before anything else.
            _ = OleInitialize(nil)

            // Friendlier failure if the WebView2 Runtime is missing —
            // surface it before we kick off async env creation.
            let runtimeHR = swiftpwa_w2_check_runtime()
            if runtimeHR != 0 {
                handleMissingWebView2Runtime(hr: runtimeHR)
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
                FileHandle.standardError.writeQuietly(
                    Data("swift-pwa: configure threw: \(error)\n".utf8)
                )
            }

            // Windows file association: the shell launches the app with the
            // opened file as a command-line argument. Emit it (retained) so
            // the WebView receives it once it subscribes to `app.openFile`,
            // matching the macOS/iOS Launch Services path.
            OpenFile.emit(OpenFile.launchFilePaths(), on: context.events)

            // Opt-in dev/test control socket. After `configure` so the app's
            // first window already exists when a driver connects; a no-op
            // unless SWIFT_PWA_DRIVE names a port (and absent entirely from
            // release builds).
            // The agent surface's indicator: a runtime-owned status item, so a user
            // can see access is open (and close it) without the app's cooperation.
            AgentIndicator.installTray { SystemTray() }
            AppDriver.startIfRequested(context, backend: "windows")

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
            // Point WebView2 at a per-user profile folder. Its default when the
            // folder is null is `<exe>.WebView2` *next to the executable*, which
            // pollutes the app bundle (and fails outright on a read-only install
            // location). A resolved %LOCALAPPDATA% path keeps the profile —
            // cache, cookies, IndexedDB/localStorage — where browsers keep
            // theirs and out of the bundle. Falls back to the default (nil) only
            // if %LOCALAPPDATA% can't be resolved.
            if let folder = Self.webView2UserDataFolder() {
                folder.withCString(encodedAs: UTF16.self) { wcs in
                    swiftpwa_w2_create_environment(wcs, envReadyTrampoline, user)
                }
            } else {
                swiftpwa_w2_create_environment(nil, envReadyTrampoline, user)
            }
        }

        /// `%LOCALAPPDATA%\<appID>\WebData`, created if absent. `nil` when
        /// %LOCALAPPDATA% is unavailable (let WebView2 use its default then).
        /// Local (not Roaming) matches where Chromium-based browsers keep their
        /// profiles — it's machine-specific and can be large, so it shouldn't
        /// roam. The leaf is the generic `WebData` (not the backend name) so the
        /// path doesn't telegraph the concrete webview implementation.
        private static func webView2UserDataFolder() -> String? {
            let env = ProcessInfo.processInfo.environment
            guard let local = env["LOCALAPPDATA"], !local.isEmpty else { return nil }
            let base = local.hasSuffix("\\") ? String(local.dropLast()) : local
            let folder = "\(base)\\\(AppPlugin.appID())\\WebData"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            return folder
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

        // MARK: - WebView2 runtime missing

        /// Dispatch the "WebView2 Runtime not found" diagnostic. If the
        /// bundler has dropped `MicrosoftEdgeWebview2Setup.exe`
        /// (the Evergreen Bootstrapper, ~1.7 MB) next to our
        /// executable, prompt to launch it; otherwise fall back to a
        /// stderr install hint.
        private func handleMissingWebView2Runtime(hr: Int32) {
            let bootstrapper = bootstrapperPathAlongsideExecutable()

            if let bootstrapper, FileManager.default.fileExists(atPath: bootstrapper.path) {
                // MessageBoxW returns IDYES (6) when the user clicks Yes.
                let prompt = """
                This app needs the Microsoft Edge WebView2 Runtime, which is not installed.

                Install it now? (~1.7 MB downloader will run with elevation.)
                """
                let title = "WebView2 Runtime required"
                let response: Int32 = prompt.withCString(encodedAs: UTF16.self) { msg in
                    title.withCString(encodedAs: UTF16.self) { ttl in
                        MessageBoxW(nil, msg, ttl, UINT(MB_YESNO | MB_ICONINFORMATION))
                    }
                }
                if response == 6 /* IDYES */ {
                    runBootstrapperAndWait(bootstrapper)
                }
                return
            }

            FileHandle.standardError.writeQuietly(Data("""
            swift-pwa: WebView2 Runtime not found (HRESULT 0x\(String(UInt32(bitPattern: hr), radix: 16))).
            Install the Evergreen Runtime from:
            https://developer.microsoft.com/en-us/microsoft-edge/webview2/

            Tip: bundle the Evergreen Bootstrapper alongside the app
            with `swift run swift-pwa build --target windows
            --bootstrap-webview2`.

            """.utf8))
        }

        /// `MicrosoftEdgeWebview2Setup.exe` co-located with our
        /// executable. Returns nil if we can't determine the exe
        /// path — extremely unusual on Windows.
        private func bootstrapperPathAlongsideExecutable() -> URL? {
            var buf = [WCHAR](repeating: 0, count: 1024)
            let len = buf.withUnsafeMutableBufferPointer { ptr -> DWORD in
                GetModuleFileNameW(nil, ptr.baseAddress, DWORD(ptr.count))
            }
            if len == 0 { return nil }
            let path = String(decoding: buf.prefix(Int(len)).map { UInt16($0) }, as: UTF16.self)
            let exeURL = URL(fileURLWithPath: path)
            return exeURL.deletingLastPathComponent()
                .appendingPathComponent("MicrosoftEdgeWebview2Setup.exe")
        }

        /// Spawn the Evergreen Bootstrapper synchronously. It elevates
        /// itself via UAC and runs to completion in roughly 30s on a
        /// warm machine, then we exit and the user re-launches us. We
        /// don't try to keep our process alive across the install:
        /// WebView2 environment creation has process-wide state that
        /// won't notice a runtime that arrives mid-flight.
        private func runBootstrapperAndWait(_ url: URL) {
            var sei = SHELLEXECUTEINFOW()
            sei.cbSize = UINT(MemoryLayout<SHELLEXECUTEINFOW>.size)
            sei.fMask = DWORD(SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC)
            sei.nShow = Int32(SW_SHOWNORMAL)
            url.path.withCString(encodedAs: UTF16.self) { fileW in
                sei.lpFile = fileW
                "/install".withCString(encodedAs: UTF16.self) { paramsW in
                    sei.lpParameters = paramsW
                    _ = ShellExecuteExW(&sei)
                }
            }
            if let proc = sei.hProcess {
                _ = WaitForSingleObject(proc, INFINITE)
                CloseHandle(proc)
            }
        }
    }

    // MARK: - AppUserModelID derivation

    /// Stable AUMID for this process. Format: `SwiftPWA.<exe basename>`,
    /// the same shape Windows uses for its built-in unpackaged AUMIDs.
    /// Falls back to `SwiftPWA.App` if the exe path can't be read,
    /// which is enough to satisfy `ToastNotificationManager`.
    func derivedAppUserModelID() -> String {
        var buf = [WCHAR](repeating: 0, count: 1024)
        let len = buf.withUnsafeMutableBufferPointer { ptr -> DWORD in
            GetModuleFileNameW(nil, ptr.baseAddress, DWORD(ptr.count))
        }
        guard len > 0 else { return "SwiftPWA.App" }
        let path = String(decoding: buf.prefix(Int(len)).map { UInt16($0) }, as: UTF16.self)
        let basename = (path as NSString).lastPathComponent
        let stem = (basename as NSString).deletingPathExtension
        // AUMIDs disallow whitespace; collapse any to dots. They also
        // have to be < 130 chars; basenames longer than that are
        // unrealistic but truncate for safety.
        let cleaned = stem.replacingOccurrences(of: " ", with: ".")
        return "SwiftPWA." + String(cleaned.prefix(120))
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
            FileHandle.standardError.writeQuietly(Data(
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
