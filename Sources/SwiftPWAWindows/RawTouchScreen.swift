#if os(Windows)
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// Whether a finger is on the touch screen, from its raw HID input.
    ///
    /// WebView2 hides a selection-handle drag from the page completely — no
    /// `pointerdown`, no `touchstart`, nothing at the lift, only
    /// `selectionchange` — and its input window belongs to another process,
    /// so the app can't watch it. The touch screen's raw input is the app's
    /// own to read (`RIDEV_INPUTSINK`, no hook into WebView2): a digitizer
    /// sends reports for as long as a finger is down and stops when it lifts.
    /// Measured on a Surface (Snapdragon X, Windows 11): the reports started
    /// and stopped within about 10 ms of every touch the page could see, and
    /// bracketed the handle drags it couldn't.
    ///
    /// Only the arrival of reports is used, never their contents, so it
    /// needs no per-device HID parsing. The lift is noticed ``liftGap`` after
    /// the last report.
    @MainActor
    final class RawTouchScreen {
        static let shared = RawTouchScreen()

        /// Long enough to bridge the gap between two reports of one contact
        /// (about 8 ms at 120 Hz), short enough to read as the lift.
        static let liftGap: UInt64 = 60

        private(set) var isDown = false
        private var lastReport: UInt64 = 0
        private var hwnd: HWND?
        private var liftWaiters: [ObjectIdentifier: () -> Void] = [:]

        private static let className: [WCHAR] = "SwiftPWARawTouch".utf16.map { WCHAR($0) } + [0]
        private static let liftTimer: UINT_PTR = 1

        /// Register for the touch screen's raw input. Idempotent. A machine
        /// without a touch screen registers fine and never reports.
        func start() {
            guard hwnd == nil else { return }
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = rawTouchWndProc
            wc.hInstance = GetModuleHandleW(nil)
            let atom = Self.className.withUnsafeBufferPointer { name -> ATOM in
                wc.lpszClassName = name.baseAddress
                return RegisterClassExW(&wc)
            }
            guard atom != 0 else {
                FileHandle.standardError.writeQuietly(Data(
                    "swift-pwa: couldn't register the raw-touch window class (\(GetLastError()))\n".utf8
                ))
                return
            }
            // A hidden top-level window rather than a message-only one: the
            // kind that was measured to receive `RIDEV_INPUTSINK` input.
            hwnd = Self.className.withUnsafeBufferPointer { name in
                CreateWindowExW(
                    DWORD(WS_EX_TOOLWINDOW), name.baseAddress, nil, DWORD(WS_POPUP),
                    0, 0, 0, 0, nil, nil, GetModuleHandleW(nil), nil
                )
            }
            guard let hwnd else {
                FileHandle.standardError.writeQuietly(Data(
                    "swift-pwa: couldn't create the raw-touch window (\(GetLastError()))\n".utf8
                ))
                return
            }
            // Usage page 0x0D (digitizer), usage 0x04 (touch screen).
            var device = RAWINPUTDEVICE(
                usUsagePage: 0x0D, usUsage: 0x04, dwFlags: DWORD(RIDEV_INPUTSINK), hwndTarget: hwnd
            )
            if !RegisterRawInputDevices(&device, 1, UINT(MemoryLayout<RAWINPUTDEVICE>.size)) {
                FileHandle.standardError.writeQuietly(Data("""
                swift-pwa: couldn't register for touch-screen input (\(GetLastError())); \
                a selection-handle drag won't report selection gestures

                """.utf8))
            }
        }

        /// The page's selection changed with no press the page could see. If
        /// a finger is on the glass that is a selection-handle drag: report
        /// `began` now and `ended` when the finger lifts.
        func selectionChangedWithoutPress(_ selection: WebViewSelection) {
            guard isDown else { return }
            selection.gesture(.began)
            liftWaiters[ObjectIdentifier(selection)] = { [weak selection] in selection?.gesture(.ended) }
        }

        fileprivate func reportArrived() {
            // Input sink: reports arrive while another app is in front too.
            // A touch there is not this app's selection gesture.
            guard ownsForeground() else { return }
            lastReport = GetTickCount64()
            guard !isDown else { return }
            isDown = true
            SetTimer(hwnd, Self.liftTimer, 20, nil)
        }

        fileprivate func checkLift() {
            guard isDown, GetTickCount64() - lastReport > Self.liftGap else { return }
            isDown = false
            KillTimer(hwnd, Self.liftTimer)
            let waiters = liftWaiters.values
            liftWaiters.removeAll()
            for lifted in waiters {
                lifted()
            }
        }

        private func ownsForeground() -> Bool {
            guard let foreground = GetForegroundWindow() else { return false }
            var pid: DWORD = 0
            GetWindowThreadProcessId(foreground, &pid)
            return pid == GetCurrentProcessId()
        }
    }

    /// Runs on the UI thread, inside `DispatchMessageW`.
    private let rawTouchWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        switch msg {
        case UINT(WM_INPUT):
            MainActor.assumeIsolated { RawTouchScreen.shared.reportArrived() }
        case UINT(WM_TIMER):
            MainActor.assumeIsolated { RawTouchScreen.shared.checkLift() }
            return 0
        default:
            break
        }
        // WM_INPUT also needs DefWindowProc, which releases the input.
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
#endif
