#if os(Windows)
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// `Tray` backed by `Shell_NotifyIconW` (the legacy "system tray"
    /// API that's still the only supported way to put an icon in the
    /// taskbar's notification area on Windows 10/11).
    ///
    /// Lifecycle:
    ///
    ///  - One hidden owner HWND per tray instance — required by
    ///    `Shell_NotifyIconW`, which routes mouse messages back to it.
    ///  - The owner's WndProc forwards `WM_APP+1` (our chosen
    ///    callback message) to `Win32Tray.handleCallbackMessage`.
    ///  - Right-click pops a `TrackPopupMenu`; left-click emits
    ///    `.click` if no menu is set, otherwise pops the menu (mirrors
    ///    the macOS `NSStatusItem` behavior).
    @MainActor
    public final class SystemTray: Tray {
        private let ownerHwnd: HWND
        private var nid: NOTIFYICONDATAW
        private var hicon: HICON?
        private var menuItems: [TrayMenuItem] = []
        private var menuHasContent: Bool { !menuItems.isEmpty }
        private var continuations: [UUID: AsyncStream<TrayEvent>.Continuation] = [:]
        private var visible = false

        /// Custom message id Shell_NotifyIcon uses to deliver mouse
        /// events to our owner HWND. Must be in the WM_APP range so
        /// it doesn't collide with other shell messages.
        static let callbackMessage: UINT = UINT(WM_APP) + 1

        // Owner window class name. Registered lazily.
        private static var classAtom: ATOM = 0
        private static let className: [WCHAR] = "SwiftPWATrayOwner".utf16.map { WCHAR($0) } + [0]

        public init() {
            Self.registerClassIfNeeded()
            // HWND_MESSAGE again — invisible owner window. We don't
            // actually need it shown, just present so Shell_NotifyIcon
            // has somewhere to send callback messages.
            let hwnd = Self.className.withUnsafeBufferPointer { name -> HWND? in
                CreateWindowExW(
                    0, name.baseAddress, nil, 0, 0, 0, 0, 0,
                    HWND_MESSAGE, nil, GetModuleHandleW(nil), nil
                )
            }
            guard let hwnd else {
                fatalError("swift-pwa: tray owner CreateWindowExW failed (\(GetLastError()))")
            }
            ownerHwnd = hwnd

            nid = NOTIFYICONDATAW()
            nid.cbSize = UINT(MemoryLayout<NOTIFYICONDATAW>.size)
            nid.hWnd = ownerHwnd
            nid.uID = 1
            nid.uFlags = UINT(NIF_MESSAGE)
            nid.uCallbackMessage = Self.callbackMessage

            // Stash a back-ref so the WndProc can dispatch into us.
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            _ = SetWindowLongPtrW(ownerHwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: selfPtr)))

            // Trays are visible on creation, matching the Linux
            // contract. `setVisible(false)` removes the icon; the
            // first `setVisible(true)` re-adds it.
            _ = Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
            visible = true
        }

        public func setIcon(path: String, template _: Bool) {
            // Load the file as an HICON. WebView2 / Win32 use 16x16
            // icons in the tray; let the OS pick the best size.
            let h = path.withCString(encodedAs: UTF16.self) { wcs -> HICON? in
                LoadImageW(
                    nil, wcs,
                    UINT(IMAGE_ICON),
                    0, 0,
                    UINT(LR_LOADFROMFILE | LR_DEFAULTSIZE)
                ).map { HICON($0) }
            }
            if let old = hicon { DestroyIcon(old) }
            hicon = h
            nid.hIcon = h
            nid.uFlags |= UINT(NIF_ICON)
            _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
        }

        public func setTooltip(_ text: String) {
            // szTip is a fixed 128-WCHAR buffer in NOTIFYICONDATAW;
            // truncate silently if the caller hands us something longer.
            let wide = Array(text.utf16.prefix(127)) + [0]
            withUnsafeMutableBytes(of: &nid.szTip) { dst in
                let cap = dst.count / MemoryLayout<WCHAR>.size
                let n = min(wide.count, cap)
                let dstW = dst.bindMemory(to: WCHAR.self)
                for i in 0..<n { dstW[i] = wide[i] }
            }
            nid.uFlags |= UINT(NIF_TIP)
            _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
        }

        public func setMenu(_ menu: TrayMenu) {
            menuItems = menu.items
        }

        public func setVisible(_ visible: Bool) {
            if visible == self.visible { return }
            if visible {
                _ = Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
            } else {
                _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
            }
            self.visible = visible
        }

        public func eventStream() -> AsyncStream<TrayEvent> {
            let key = UUID()
            return AsyncStream { continuation in
                self.continuations[key] = continuation
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in self.continuations.removeValue(forKey: key) }
                }
            }
        }

        // MARK: - Callback handling

        /// Called from `trayOwnerWndProc` for our `WM_APP+1` message.
        /// `lParam` carries the mouse-event constant (`WM_LBUTTONUP`,
        /// `WM_RBUTTONUP`, ...).
        func handleCallbackMessage(lParam: LPARAM) {
            switch Int32(lParam) {
            case WM_LBUTTONUP:
                if menuHasContent {
                    showContextMenu()
                } else {
                    emit(.click)
                }
            case WM_RBUTTONUP, WM_CONTEXTMENU:
                if menuHasContent { showContextMenu() }
            default:
                break
            }
        }

        private func showContextMenu() {
            guard let menu = CreatePopupMenu() else { return }
            defer { DestroyMenu(menu) }
            // Win32 menu items use UINT command ids. Map them to our
            // string ids by tracking insertion order; we look the id
            // back up when TrackPopupMenu returns the chosen command.
            for (i, item) in menuItems.enumerated() {
                if item.separator {
                    AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
                } else {
                    let flags: UINT = UINT(MF_STRING) | (item.enabled ? 0 : UINT(MF_GRAYED))
                    item.label.withCString(encodedAs: UTF16.self) { wcs in
                        AppendMenuW(menu, flags, UINT_PTR(i + 1), wcs)
                    }
                }
            }
            var pt = POINT()
            GetCursorPos(&pt)
            // SetForegroundWindow before TrackPopupMenu is required
            // by Win32 docs to avoid the menu disappearing on the
            // first click.
            SetForegroundWindow(ownerHwnd)
            let cmd = TrackPopupMenu(
                menu,
                UINT(TPM_RETURNCMD | TPM_RIGHTBUTTON),
                pt.x, pt.y, 0, ownerHwnd, nil
            )
            // Per docs, post a null message so the menu gets fully
            // dismissed before we do anything reentrant.
            PostMessageW(ownerHwnd, UINT(WM_NULL), 0, 0)
            if cmd > 0 {
                let idx = Int(cmd) - 1
                if menuItems.indices.contains(idx) {
                    let item = menuItems[idx]
                    if !item.separator {
                        emit(.menuItemClicked(id: item.id))
                    }
                }
            }
        }

        fileprivate func emit(_ event: TrayEvent) {
            for c in continuations.values { c.yield(event) }
        }

        // MARK: - Class registration

        private static func registerClassIfNeeded() {
            guard classAtom == 0 else { return }
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = trayOwnerWndProc
            wc.hInstance = GetModuleHandleW(nil)
            classAtom = className.withUnsafeBufferPointer { name in
                wc.lpszClassName = name.baseAddress
                return RegisterClassExW(&wc)
            }
            if classAtom == 0 {
                fatalError("swift-pwa: tray owner RegisterClassExW failed (\(GetLastError()))")
            }
        }

        deinit {
            // Best-effort tray cleanup. Mirrors the GTK tray's
            // intentional leak-on-app-exit pattern, but we still want
            // to remove the icon from the taskbar on early teardown.
            var n = nid
            _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &n)
            if let hicon { DestroyIcon(hicon) }
        }
    }

    let trayOwnerWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        guard let hwnd else { return 0 }
        if msg == SystemTray.callbackMessage {
            let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
            if raw != 0,
               let opaque = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(raw)))
            {
                let tray = Unmanaged<SystemTray>.fromOpaque(opaque).takeUnretainedValue()
                MainActor.assumeIsolated {
                    tray.handleCallbackMessage(lParam: lParam)
                }
                return 0
            }
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
#endif
