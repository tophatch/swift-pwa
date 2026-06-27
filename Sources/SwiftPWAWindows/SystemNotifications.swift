#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// `Notifications` backed by `Windows.UI.Notifications.ToastNotificationManager`
    /// via the `swiftpwa_toast` C++/WinRT shim.
    ///
    /// Falls back to `Shell_NotifyIconW` balloon tips when the WinRT
    /// path is unavailable — for instance on Windows Server SKUs
    /// without the Desktop Experience, or when the process never set
    /// an AppUserModelID (the toast shim guards against this in
    /// `swiftpwa_toast_available`).
    ///
    /// AUMID is set up by `WindowsAppRuntime` at process start; toasts
    /// shown from an unpackaged executable will surface but won't
    /// persist in Action Center across reboots unless the app also
    /// installs a Start-menu shortcut with a matching AUMID. That's a
    /// caller-side concern — packaging and shortcut registration live
    /// in the bundler / installer, not the runtime.
    public final class SystemNotifications: Notifications, @unchecked Sendable {
        public init() {}

        public func requestAuthorization() async throws -> Bool {
            // ToastNotificationManager doesn't gate on a permission
            // prompt at the Win32 level — Windows routes through Focus
            // Assist / Do Not Disturb but never refuses an API call.
            // Returning `true` keeps the JS-side flow symmetric with
            // Apple, where authorization is a real boolean.
            true
        }

        public func send(_ request: NotificationRequest) async throws -> String {
            try await MainThread.run { [self] in try sendOnMainThread(request) }
        }

        private func sendOnMainThread(_ request: NotificationRequest) throws -> String {
            // The toast's WinRT tag doubles as the id we return to JS.
            // We synthesize one per send (the v0.2 protocol doesn't
            // expose a caller-supplied tag); replace-by-id surfaces
            // when the protocol grows a `tag` field.
            let id = Foundation.UUID().uuidString

            if swiftpwa_toast_available() != 0 {
                let hr = id.withCString(encodedAs: UTF16.self) { tagW in
                    request.title.withCString(encodedAs: UTF16.self) { titleW in
                        (request.body ?? "").withCString(encodedAs: UTF16.self) { bodyW in
                            swiftpwa_toast_send(tagW, titleW, bodyW, request.sound ? 0 : 1)
                        }
                    }
                }
                if hr == 0 { return id }
                // Non-zero from the WinRT path — log and fall through
                // to the balloon tip. Don't throw: the shim already
                // wrote the HRESULT to stderr, and we'd rather show
                // *something* than fail the JS call entirely on a
                // transient WinRT failure.
                FileHandle.standardError.writeQuietly(
                    Data(
                        "swift-pwa: WinRT toast failed (0x\(String(UInt32(bitPattern: hr), radix: 16))), falling back to balloon\n"
                            .utf8
                    )
                )
            }

            try sendBalloonFallback(request)
            return id
        }

        // MARK: - Balloon-tip fallback

        private func sendBalloonFallback(_ request: NotificationRequest) throws {
            let owner = NotificationHost.shared.hwnd
            var nid = NOTIFYICONDATAW()
            nid.cbSize = UINT(MemoryLayout<NOTIFYICONDATAW>.size)
            nid.hWnd = owner
            nid.uID = NotificationHost.iconId
            nid.uFlags = UINT(NIF_INFO)
            nid.dwInfoFlags = request.sound ? UINT(NIIF_INFO) : UINT(NIIF_INFO | NIIF_NOSOUND)

            // szInfoTitle is 64 WCHARs, szInfo is 256 — truncate to fit.
            let titleW = Array(request.title.utf16.prefix(63)) + [0]
            withUnsafeMutableBytes(of: &nid.szInfoTitle) { dst in
                let w = dst.bindMemory(to: WCHAR.self)
                for i in 0 ..< titleW.count { w[i] = titleW[i] }
            }
            let bodyW = Array((request.body ?? "").utf16.prefix(255)) + [0]
            withUnsafeMutableBytes(of: &nid.szInfo) { dst in
                let w = dst.bindMemory(to: WCHAR.self)
                for i in 0 ..< bodyW.count { w[i] = bodyW[i] }
            }

            let op: DWORD = NotificationHost.shared.installed ? DWORD(NIM_MODIFY) : DWORD(NIM_ADD)
            if !Shell_NotifyIconW(op, &nid) {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "Shell_NotifyIconW failed (\(GetLastError()))"
                )
            }
            NotificationHost.shared.installed = true
        }
    }

    // MARK: - Notification host

    ///
    /// Hidden HWND owning the lifetime of the shared tray icon used as
    /// the toast source. Lazily created on first send.
    ///
    /// Not `@MainActor` — the surrounding `SystemNotifications` is
    /// `@unchecked Sendable` and accesses the host only from inside
    /// `MainThread.run` closures, so the "UI thread only" invariant is
    /// upheld externally. `installed` is `nonisolated(unsafe)` for
    /// the same reason.
    final class NotificationHost: @unchecked Sendable {
        static let shared = NotificationHost()
        static let iconId: UINT = 2 // distinct from SystemTray.uID = 1
        let hwnd: HWND
        nonisolated(unsafe) var installed = false

        private static let className: [WCHAR] =
            "SwiftPWANotifyHost".utf16.map { WCHAR($0) } + [0]
        private nonisolated(unsafe) static var classAtom: ATOM = 0

        private init() {
            Self.registerClassIfNeeded()
            hwnd = Self.className.withUnsafeBufferPointer { name in
                CreateWindowExW(
                    0, name.baseAddress, nil, 0, 0, 0, 0, 0,
                    HWND_MESSAGE, nil, GetModuleHandleW(nil), nil
                )!
            }
        }

        private static func registerClassIfNeeded() {
            guard classAtom == 0 else { return }
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = { hwnd, msg, w, l in DefWindowProcW(hwnd, msg, w, l) }
            wc.hInstance = GetModuleHandleW(nil)
            classAtom = className.withUnsafeBufferPointer { name in
                wc.lpszClassName = name.baseAddress
                return RegisterClassExW(&wc)
            }
        }
    }
#endif
