#if os(Windows)
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// `Notifications` backed by `Shell_NotifyIconW` balloon tips.
    ///
    /// On modern Windows 10 / 11, balloon tips from a registered
    /// notification-area icon are routed through Action Center and
    /// rendered as toast notifications, so a v0.2 cut that piggy-backs
    /// on the tray icon's HWND gets us "real" toasts without taking
    /// on a `swift-winrt` dependency. The richer
    /// `Windows.UI.Notifications.ToastNotificationManager` API (with
    /// XML payloads, replace-by-id, action buttons) lands in v0.3
    /// alongside the swift-winrt rollout the rest of the platform
    /// will use for biometric auth and storage pickers.
    ///
    /// Caveats:
    ///
    ///  - The hosting executable must have a registered AppUserModelID
    ///    *or* be a packaged app for toasts to persist in Action
    ///    Center. Unsigned `swift run` invocations show a transient
    ///    balloon and nothing in history. The CLI's Windows bundler
    ///    sets a stable AUMID via `SetCurrentProcessExplicitAppUserModelID`
    ///    on process start.
    ///  - One tray icon is shared across all calls. We create it
    ///    on demand and lazily; closing it is fine because Action
    ///    Center keeps a copy of the toast.
    public final class SystemNotifications: Notifications, @unchecked Sendable {
        public init() {}

        public func requestAuthorization() async throws -> Bool {
            // Balloon tips don't gate on a permission prompt — Windows
            // routes them through Focus Assist / Do Not Disturb but
            // never refuses an API call. Returning `true` keeps the
            // JS-side flow symmetric with Apple, where authorization
            // is a real boolean.
            true
        }

        public func send(_ request: NotificationRequest) async throws -> String {
            try await MainThread.run { [self] in try sendOnMainThread(request) }
        }

        private func sendOnMainThread(_ request: NotificationRequest) throws -> String {
            let owner = NotificationHost.shared.hwnd
            var nid = NOTIFYICONDATAW()
            nid.cbSize = UINT(MemoryLayout<NOTIFYICONDATAW>.size)
            nid.hWnd = owner
            nid.uID = NotificationHost.iconId
            nid.uFlags = UINT(NIF_INFO)
            nid.dwInfoFlags = request.sound ? UINT(NIIF_INFO) : UINT(NIIF_INFO | NIIF_NOSOUND)

            // szInfoTitle is 64 WCHARs, szInfo is 256 — truncate to fit.
            // Tuples of WCHAR don't have nice element-by-index APIs in
            // Swift, so write through `withUnsafeMutableBytes`.
            let titleW = Array(request.title.utf16.prefix(63)) + [0]
            withUnsafeMutableBytes(of: &nid.szInfoTitle) { dst in
                let w = dst.bindMemory(to: WCHAR.self)
                for i in 0..<titleW.count { w[i] = titleW[i] }
            }
            let bodyW = Array((request.body ?? "").utf16.prefix(255)) + [0]
            withUnsafeMutableBytes(of: &nid.szInfo) { dst in
                let w = dst.bindMemory(to: WCHAR.self)
                for i in 0..<bodyW.count { w[i] = bodyW[i] }
            }

            // First call adds the icon (NIM_ADD); subsequent calls
            // re-trigger the balloon via NIM_MODIFY. NotificationHost
            // tracks whether we've added it yet.
            let op: DWORD = NotificationHost.shared.installed ? DWORD(NIM_MODIFY) : DWORD(NIM_ADD)
            if Shell_NotifyIconW(op, &nid) == 0 {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "Shell_NotifyIconW failed (\(GetLastError()))"
                )
            }
            NotificationHost.shared.installed = true
            // Win32 doesn't return an id for balloon tips. Synthesize
            // one — callers use it for log correlation only on the
            // Windows backend (action-button events ship in v0.3).
            return UUID().uuidString
        }

    }

    // MARK: - Notification host
    //
    // Hidden HWND owning the lifetime of the shared tray icon used as
    // the toast source. Lazily created on first send.
    //
    // Not `@MainActor` — the surrounding `SystemNotifications` is
    // `@unchecked Sendable` and accesses the host only from inside
    // `MainThread.run` closures, so the "UI thread only" invariant is
    // upheld externally. `installed` is `nonisolated(unsafe)` for
    // the same reason.
    final class NotificationHost: @unchecked Sendable {
        static let shared = NotificationHost()
        static let iconId: UINT = 2 // distinct from SystemTray.uID = 1
        let hwnd: HWND
        nonisolated(unsafe) var installed = false

        private static let className: [WCHAR] =
            "SwiftPWANotifyHost".utf16.map { WCHAR($0) } + [0]
        nonisolated(unsafe) private static var classAtom: ATOM = 0

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
