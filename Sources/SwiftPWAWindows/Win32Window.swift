#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// Win32 + WebView2 implementation of `Window`.
    ///
    /// Lifecycle:
    ///
    ///  1. `CreateWindowExW` — owned HWND with our class.
    ///  2. `WebView2Adapter.attach` — async; spins up a controller,
    ///     wires the bridge user-script, subscribes to web messages,
    ///     and registers a `pwa://` resource interceptor for bundled
    ///     content. We pump messages until it reports ready, mirroring
    ///     the WebKitGTK adapter's synchronous-feel API.
    ///  3. `BridgeRuntime.start` — once the adapter is ready, the
    ///     bridge can pump frames into the registry.
    ///
    /// Threading: `Window` requires `@MainActor`. We're created from
    /// the `configure` closure which runs on the UI thread, so the
    /// init runs there. Win32 messages dispatched into `wndProc` also
    /// fire on the UI thread (DispatchMessageW invokes synchronously).
    @MainActor
    public final class Win32Window: Window {
        public let id = WindowID()
        public let webView: any PWAWebView

        private let hwnd: HWND

        /// Internal accessor for sibling backend code (e.g. `SystemDialog`)
        /// that needs to parent a Win32 dialog onto this window.
        var nativeHwnd: HWND {
            hwnd
        }
        private let adapter: WebView2Adapter
        private let bridge: BridgeRuntime
        private weak var app: WindowsAppContext?
        private var titleStorage: String
        // `Foundation.UUID` because the WinSDK overlay re-exports a
        // `UUID` typealias for `_GUIDDef`; bare `UUID` is ambiguous.
        private var continuations: [Foundation.UUID: AsyncStream<WindowEvent>.Continuation] = [:]
        private var lastSize: Size = .zero
        private var lastPosition: Point = .zero
        private var fullscreen = false
        private var savedPlacement: WINDOWPLACEMENT?
        private var savedStyle: LONG_PTR = 0

        // Window class atom — registered lazily on first window. The
        // class holds the wndProc that routes messages back into Swift.
        // `nonisolated(unsafe)` because the static var is mutable
        // global state guarded by the "always called from the UI
        // thread during init" invariant.
        private nonisolated(unsafe) static var classAtom: ATOM = 0
        private static let className: [WCHAR] = "SwiftPWAWindow".utf16.map { WCHAR($0) } + [0]

        public init(
            config: WindowConfig,
            app: WindowsAppContext,
            environment: OpaquePointer
        ) throws {
            Self.registerClassIfNeeded()
            titleStorage = config.title

            // Style: standard overlapped window plus `WS_CLIPCHILDREN`.
            // Without `WS_CLIPCHILDREN`, the parent's WM_ERASEBKGND
            // paints `hbrBackground` (system white) over the entire
            // client area — including where the WebView2 child HWND
            // is rendering — so the page is correctly loaded but
            // invisible. Setting the flag tells GDI to skip the
            // child rectangles. Microsoft's WebView2 samples all
            // do this.
            //
            // Resizable maps to the presence of `WS_THICKFRAME` +
            // `WS_MAXIMIZEBOX`.
            var style = DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN)
            if !config.resizable {
                style &= ~DWORD(WS_THICKFRAME | WS_MAXIMIZEBOX)
            }

            let titleW = config.title.utf16.map { WCHAR($0) } + [0]
            // Initial size: convert from DIPs (the unit the cross-
            // platform `WindowConfig` uses) to physical pixels, against
            // the primary monitor's DPI. Per-Monitor V2 awareness means
            // the OS will reset us to the actual monitor's DPI as soon
            // as the window is positioned, raising `WM_DPICHANGED` if
            // they differ — `handle(...)` accepts the OS-suggested
            // rect from there.
            let initialDpi = primaryMonitorDpi()
            let initialW = Int32((config.size.width * Double(initialDpi) / 96.0).rounded())
            let initialH = Int32((config.size.height * Double(initialDpi) / 96.0).rounded())
            // A remembered / explicit initial position (DIPs → physical px);
            // otherwise let the OS place the window. `WM_DPICHANGED` still
            // reconciles the size/position if the target monitor's DPI differs.
            let initialX: Int32
            let initialY: Int32
            if let origin = config.origin {
                initialX = Int32((origin.x * Double(initialDpi) / 96.0).rounded())
                initialY = Int32((origin.y * Double(initialDpi) / 96.0).rounded())
                lastPosition = origin
            } else {
                initialX = Int32(CW_USEDEFAULT)
                initialY = Int32(CW_USEDEFAULT)
            }
            let hwndOpt: HWND? = titleW.withUnsafeBufferPointer { titlePtr in
                Self.className.withUnsafeBufferPointer { classPtr in
                    CreateWindowExW(
                        0,
                        classPtr.baseAddress,
                        titlePtr.baseAddress,
                        style,
                        initialX, initialY,
                        initialW, initialH,
                        nil, nil,
                        GetModuleHandleW(nil),
                        nil
                    )
                }
            }
            guard let hwnd = hwndOpt else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "CreateWindowExW failed (\(GetLastError()))"
                )
            }
            self.hwnd = hwnd
            self.app = app

            let adapter = try WebView2Adapter(
                environment: environment,
                parent: hwnd,
                content: config.content,
                backgroundColor: config.backgroundColor.flatMap(RGBColor.init(hex:)),
                sharedProvider: app.assetProvider
            )
            self.adapter = adapter
            webView = adapter

            bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: id,
                app: app
            )

            // Stash a back-reference on the HWND so wndProc can find
            // us. Must run after every stored property is initialized
            // — `Unmanaged.passUnretained(self)` counts as a `self`
            // use that the compiler refuses on a partially-initialized
            // instance. We use GWLP_USERDATA; SetWindowLongPtr returns
            // the previous value (0 here).
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: selfPtr)))

            // Pump the message loop until the WebView2 controller is
            // ready. The adapter posts back to MainThread when its
            // async creation chain completes.
            adapter.pumpUntilReady()
            bridge.start()
            adapter.load(config.content)
            adapter.fitTo(client: clientRect())

            lastSize = config.size
            if config.fullscreen { setFullscreen(true) }
            if config.visibleOnLaunch { showAndActivate() }
        }

        // MARK: - Win32 message routing

        private static func registerClassIfNeeded() {
            guard classAtom == 0 else { return }
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
            wc.lpfnWndProc = swiftPWAWndProc
            wc.hInstance = GetModuleHandleW(nil)
            wc.hCursor = LoadCursorW(nil, IDC_ARROW_W)
            // No background brush. WebView2 renders via DirectComposition
            // (not GDI), so its visual sits on top of the HWND surface;
            // an `hbrBackground = COLOR_WINDOW+1` would paint white over
            // the same pixels every WM_ERASEBKGND. Leaving the brush
            // null means GDI doesn't erase the background — there's a
            // brief moment between `ShowWindow` and the first WebView2
            // paint where uninitialized pixels could show, but in
            // practice the controller is already live by the time we
            // show the window.
            wc.hbrBackground = nil
            classAtom = className.withUnsafeBufferPointer { name in
                wc.lpszClassName = name.baseAddress
                return RegisterClassExW(&wc)
            }
            if classAtom == 0 {
                fatalError("swift-pwa: RegisterClassExW failed (\(GetLastError()))")
            }
        }

        /// Called by `swiftPWAWndProc` once it has resolved the back-ref.
        /// Returns `true` to indicate the message was handled and no
        /// further processing is needed; `false` to fall through to
        /// `DefWindowProcW`.
        @discardableResult
        func handle(message: UINT, wParam: WPARAM, lParam: LPARAM) -> Bool {
            switch Int32(message) {
            case WM_SIZE:
                // LOWORD/HIWORD of lParam are the new client extents in
                // *physical* pixels. Convert to DIPs before exposing
                // them on the cross-platform `Size` API.
                let scale = dpiScale()
                let w = Double(LOWORD(DWORD(bitPattern: Int32(lParam)))) / scale
                let h = Double(HIWORD(DWORD(bitPattern: Int32(lParam)))) / scale
                let size = Size(width: w, height: h)
                if size != lastSize {
                    lastSize = size
                    emit(.didResize(size))
                }
                adapter.fitTo(client: clientRect())
                return true
            case WM_MOVE:
                let scale = dpiScale()
                let x = Double(LOWORD(DWORD(bitPattern: Int32(lParam)))) / scale
                let y = Double(HIWORD(DWORD(bitPattern: Int32(lParam)))) / scale
                let pos = Point(x: x, y: y)
                if pos != lastPosition {
                    lastPosition = pos
                    emit(.didMove(pos))
                }
                return true
            case WM_DPICHANGED:
                // Per-Monitor V2 contract: the OS supplies the suggested
                // new window rect (in physical pixels) via lParam,
                // already factored for the new DPI. Apply it verbatim
                // — anything else and the window ends up the wrong
                // physical size for the new monitor.
                if let rect = UnsafePointer<RECT>(bitPattern: UInt(lParam))?.pointee {
                    SetWindowPos(
                        hwnd, nil,
                        rect.left, rect.top,
                        rect.right - rect.left, rect.bottom - rect.top,
                        UINT(SWP_NOZORDER | SWP_NOACTIVATE)
                    )
                }
                return true
            case WM_SETFOCUS:
                emit(.didFocus)
                return true
            case WM_CLOSE:
                emit(.willClose)
                DestroyWindow(hwnd)
                return true
            case WM_DESTROY:
                emit(.didClose)
                cleanupAfterClose()
                return true
            case WM_KEYDOWN, WM_SYSKEYDOWN:
                let ctrlDown = (GetKeyState(VK_CONTROL) & Int16(bitPattern: 0x8000)) != 0
                let altDown = (GetKeyState(VK_MENU) & Int16(bitPattern: 0x8000)) != 0
                // Ctrl+Q quit accelerator, matching Linux.
                if Int32(wParam) == 0x51 /* 'Q' */, ctrlDown {
                    app?.quit(exitCode: 0)
                    return true
                }
                // Ctrl+Alt+J — open WebView2 DevTools. Mirrors Chrome
                // / Edge's Cmd+Opt+J on macOS; cross-platform binding
                // on the other backends is a v0.3 follow-up.
                if Int32(wParam) == 0x4A /* 'J' */, ctrlDown, altDown {
                    adapter.openDevTools()
                    return true
                }
                return false
            default:
                return false
            }
        }

        private func cleanupAfterClose() {
            for c in continuations.values { c.finish() }
            continuations.removeAll()
            bridge.stop()
            adapter.detach()
            app?.windowDidClose(id)
        }

        private func clientRect() -> RECT {
            var r = RECT()
            GetClientRect(hwnd, &r)
            return r
        }

        private func showAndActivate() {
            ShowWindow(hwnd, SW_SHOW)
            UpdateWindow(hwnd)
        }

        // MARK: - Window protocol

        public func eventStream() -> AsyncStream<WindowEvent> {
            // `Foundation.UUID()` because the Win32 SDK exports its
            // own `UUID` typealias (the `_GUIDDef` struct), and Swift
            // can't disambiguate from `UUID()`.
            let key = Foundation.UUID()
            return AsyncStream { continuation in
                self.continuations[key] = continuation
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in self.continuations.removeValue(forKey: key) }
                }
            }
        }

        func emit(_ event: WindowEvent) {
            for c in continuations.values { c.yield(event) }
        }

        public func setTitle(_ title: String) {
            titleStorage = title
            let w = title.utf16.map { WCHAR($0) } + [0]
            w.withUnsafeBufferPointer { ptr in
                _ = SetWindowTextW(hwnd, ptr.baseAddress)
            }
        }
        public func title() -> String { titleStorage }

        public func setSize(_ size: Size, animated _: Bool) {
            // SetWindowPos takes physical pixels; convert from DIPs.
            // SWP_NOMOVE/SWP_NOZORDER preserves position and z-order
            // while resizing.
            let scale = dpiScale()
            SetWindowPos(
                hwnd, nil,
                0, 0,
                Int32((size.width * scale).rounded()),
                Int32((size.height * scale).rounded()),
                UINT(SWP_NOMOVE | SWP_NOZORDER)
            )
        }
        public func size() -> Size {
            var r = RECT()
            GetWindowRect(hwnd, &r)
            let scale = dpiScale()
            return Size(
                width: Double(r.right - r.left) / scale,
                height: Double(r.bottom - r.top) / scale
            )
        }

        public func setPosition(_ point: Point) {
            let scale = dpiScale()
            SetWindowPos(
                hwnd, nil,
                Int32((point.x * scale).rounded()),
                Int32((point.y * scale).rounded()),
                0, 0,
                UINT(SWP_NOSIZE | SWP_NOZORDER)
            )
        }
        public func position() -> Point {
            var r = RECT()
            GetWindowRect(hwnd, &r)
            let scale = dpiScale()
            return Point(x: Double(r.left) / scale, y: Double(r.top) / scale)
        }

        // MARK: - DPI

        /// Logical-to-physical pixel ratio for this window's current
        /// monitor. Always at least 1.0; clamps to 96-DPI when
        /// `GetDpiForWindow` returns 0 (Windows 8.1 / earlier).
        private func dpiScale() -> Double {
            let raw = GetDpiForWindow(hwnd)
            return raw > 0 ? Double(raw) / 96.0 : 1.0
        }

        public func focus() {
            SetForegroundWindow(hwnd)
            emit(.didFocus)
        }
        public func minimize() {
            ShowWindow(hwnd, SW_MINIMIZE)
            emit(.didMinimize)
        }
        public func maximize() {
            ShowWindow(hwnd, SW_MAXIMIZE)
        }

        public func setFullscreen(_ on: Bool) {
            if on == fullscreen { return }
            if on {
                // Standard "fake fullscreen" recipe: stash the current
                // placement + style, drop chrome, resize to monitor.
                var placement = WINDOWPLACEMENT()
                placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
                GetWindowPlacement(hwnd, &placement)
                savedPlacement = placement
                savedStyle = GetWindowLongPtrW(hwnd, GWL_STYLE)

                let monitor = MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTOPRIMARY))
                var info = MONITORINFO()
                info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
                GetMonitorInfoW(monitor, &info)
                _ = SetWindowLongPtrW(
                    hwnd, GWL_STYLE,
                    savedStyle & ~LONG_PTR(WS_OVERLAPPEDWINDOW)
                )
                SetWindowPos(
                    hwnd, HWND_TOP,
                    info.rcMonitor.left, info.rcMonitor.top,
                    info.rcMonitor.right - info.rcMonitor.left,
                    info.rcMonitor.bottom - info.rcMonitor.top,
                    UINT(SWP_NOOWNERZORDER | SWP_FRAMECHANGED)
                )
                fullscreen = true
                emit(.didEnterFullscreen)
            } else {
                _ = SetWindowLongPtrW(hwnd, GWL_STYLE, savedStyle)
                if var placement = savedPlacement {
                    SetWindowPlacement(hwnd, &placement)
                }
                SetWindowPos(
                    hwnd, nil, 0, 0, 0, 0,
                    UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER
                        | SWP_NOOWNERZORDER | SWP_FRAMECHANGED)
                )
                fullscreen = false
                emit(.didExitFullscreen)
            }
        }
        public func isFullscreen() -> Bool { fullscreen }

        /// Minimized is the only part Win32 will tell us: there is no occlusion
        /// query short of DWM tricks, so a window that merely *might* be covered
        /// reports `unknown` rather than claiming to be visible.
        public func visibility() -> WindowVisibility {
            // `== false` rather than a bare condition or `.boolValue`: Win32's
            // `BOOL` arrives as `WindowsBool` in some import configurations and as
            // `Bool` in others, and comparing against a literal compiles either
            // way. (Can't be built on a Mac, so it's CI that finds out.)
            IsIconic(hwnd) == false ? .unknown : .hidden
        }

        public func close() {
            // Sending WM_CLOSE goes through the same path as the user
            // clicking the close button: emits .willClose, destroys
            // the HWND, then WM_DESTROY emits .didClose and cleans up.
            SendMessageW(hwnd, UINT(WM_CLOSE), 0, 0)
        }
    }

    // MARK: - WndProc

    /// `@convention(c)` window procedure. Looks up the back-ref via
    /// `GWLP_USERDATA` and forwards to `Win32Window.handle`.
    let swiftPWAWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        guard let hwnd else { return 0 }
        let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        if raw != 0 {
            let opaque = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(raw)))
            if let opaque {
                let win = Unmanaged<Win32Window>.fromOpaque(opaque).takeUnretainedValue()
                let handled = MainActor.assumeIsolated {
                    win.handle(message: msg, wParam: wParam, lParam: lParam)
                }
                if handled { return 0 }
            }
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }

    // MARK: - LOWORD / HIWORD helpers

    //
    // The Win32 macros aren't imported into Swift. They're trivial
    // bit-twiddles, so just spell them out.

    @inline(__always)
    func LOWORD(_ v: DWORD) -> UInt16 { UInt16(v & 0xFFFF) }

    @inline(__always)
    func HIWORD(_ v: DWORD) -> UInt16 { UInt16((v >> 16) & 0xFFFF) }

    // MARK: - Primary monitor DPI

    /// DPI of the primary monitor, used to size the window before its
    /// HWND exists (so we can't yet call `GetDpiForWindow`). Per-Monitor
    /// V2 awareness means every secondary monitor may report a different
    /// DPI; the OS sends `WM_DPICHANGED` once the window is positioned
    /// on its real monitor, and `handle(...)` re-applies the suggested
    /// rect from there.
    func primaryMonitorDpi() -> UINT {
        // `GetDpiForSystem` returns the DPI of the primary monitor for
        // a Per-Monitor-V2 process. Available on Win10 1607+; falls
        // back to 96 below that.
        let dpi = GetDpiForSystem()
        return dpi > 0 ? dpi : 96
    }
#endif
