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
        private let adapter: WebView2Adapter
        private let bridge: BridgeRuntime
        private weak var app: WindowsAppContext?
        private var titleStorage: String
        private var continuations: [UUID: AsyncStream<WindowEvent>.Continuation] = [:]
        private var lastSize: Size = .zero
        private var lastPosition: Point = .zero
        private var fullscreen = false
        private var savedPlacement: WINDOWPLACEMENT?
        private var savedStyle: LONG_PTR = 0

        // Window class atom — registered lazily on first window. The
        // class holds the wndProc that routes messages back into Swift.
        private static var classAtom: ATOM = 0
        private static let className: [WCHAR] = "SwiftPWAWindow".utf16.map { WCHAR($0) } + [0]

        public init(
            config: WindowConfig,
            app: WindowsAppContext,
            environment: OpaquePointer
        ) throws {
            Self.registerClassIfNeeded()
            titleStorage = config.title

            // Style: standard overlapped window. Resizable maps to the
            // presence of `WS_THICKFRAME` + `WS_MAXIMIZEBOX`.
            var style: DWORD = DWORD(WS_OVERLAPPEDWINDOW)
            if !config.resizable {
                style &= ~DWORD(WS_THICKFRAME | WS_MAXIMIZEBOX)
            }

            let titleW = config.title.utf16.map { WCHAR($0) } + [0]
            let hwndOpt: HWND? = titleW.withUnsafeBufferPointer { titlePtr in
                Self.className.withUnsafeBufferPointer { classPtr in
                    CreateWindowExW(
                        0,
                        classPtr.baseAddress,
                        titlePtr.baseAddress,
                        style,
                        Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT),
                        Int32(config.size.width), Int32(config.size.height),
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

            // Stash a back-reference on the HWND so wndProc can find
            // us. We use GWLP_USERDATA; SetWindowLongPtr returns the
            // previous value (0 here).
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: selfPtr)))

            let adapter = try WebView2Adapter(
                environment: environment,
                parent: hwnd,
                content: config.content
            )
            self.adapter = adapter
            webView = adapter

            bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: id,
                app: app
            )

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
            wc.hCursor = LoadCursorW(nil, IDC_ARROW)
            wc.hbrBackground = HBRUSH(bitPattern: UInt(COLOR_WINDOW + 1))
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
        func handle(message: UINT, wParam _: WPARAM, lParam: LPARAM) -> Bool {
            switch Int32(message) {
            case WM_SIZE:
                // LOWORD/HIWORD of lParam are the new client extents.
                let w = Double(LOWORD(DWORD(bitPattern: Int32(lParam))))
                let h = Double(HIWORD(DWORD(bitPattern: Int32(lParam))))
                let size = Size(width: w, height: h)
                if size != lastSize {
                    lastSize = size
                    emit(.didResize(size))
                }
                adapter.fitTo(client: clientRect())
                return true
            case WM_MOVE:
                let x = Double(LOWORD(DWORD(bitPattern: Int32(lParam))))
                let y = Double(HIWORD(DWORD(bitPattern: Int32(lParam))))
                let pos = Point(x: x, y: y)
                if pos != lastPosition {
                    lastPosition = pos
                    emit(.didMove(pos))
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
            case WM_KEYDOWN:
                // Ctrl+Q quit accelerator, matching Linux.
                if Int32(wParam) == 0x51 /* 'Q' */
                    && (GetKeyState(VK_CONTROL) & Int16(bitPattern: 0x8000)) != 0
                {
                    app?.quit(exitCode: 0)
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
            let key = UUID()
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
            // SetWindowPos with SWP_NOMOVE/SWP_NOZORDER preserves
            // position and z-order while resizing.
            SetWindowPos(
                hwnd, nil,
                0, 0,
                Int32(size.width), Int32(size.height),
                UINT(SWP_NOMOVE | SWP_NOZORDER)
            )
        }
        public func size() -> Size {
            var r = RECT()
            GetWindowRect(hwnd, &r)
            return Size(width: Double(r.right - r.left), height: Double(r.bottom - r.top))
        }

        public func setPosition(_ point: Point) {
            SetWindowPos(
                hwnd, nil,
                Int32(point.x), Int32(point.y),
                0, 0,
                UINT(SWP_NOSIZE | SWP_NOZORDER)
            )
        }
        public func position() -> Point {
            var r = RECT()
            GetWindowRect(hwnd, &r)
            return Point(x: Double(r.left), y: Double(r.top))
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
#endif
