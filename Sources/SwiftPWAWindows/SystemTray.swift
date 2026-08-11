#if os(Windows)
    import CWebView2Shim
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
        private var menuHasContent: Bool {
            !menuItems.isEmpty
        }
        // `Foundation.UUID` to disambiguate from the Win32 SDK's
        // `UUID` typealias (`_GUIDDef`).
        private var continuations: [Foundation.UUID: AsyncStream<TrayEvent>.Continuation] = [:]
        private var visible = false

        /// Custom message id Shell_NotifyIcon uses to deliver mouse
        /// events to our owner HWND. Must be in the WM_APP range so
        /// it doesn't collide with other shell messages.
        ///
        /// `nonisolated` so the trampoline WndProc (which can't be
        /// `@MainActor`) can read it without a hop.
        nonisolated static let callbackMessage: UINT = .init(WM_APP) + 1

        // Owner window class name. Registered lazily.
        // `nonisolated(unsafe)` — only mutated on the UI thread under
        // the same invariant that guards the other class atoms.
        private nonisolated(unsafe) static var classAtom: ATOM = 0
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
            // `LoadImageW(IMAGE_ICON, LR_LOADFROMFILE)` reads `.ico` files and
            // nothing else — hand it a PNG and it returns null, which is how
            // the agent indicator came to occupy a blank slot in the
            // notification area on Windows while rendering fine everywhere
            // else. The cross-platform contract is that a PNG works (macOS
            // takes one, both GTK backends take one, and the JS docs show
            // one), so the conversion belongs here rather than in every
            // caller: a PNG gets repackaged as a single-entry icon container
            // on the way in.
            let loadPath = Self.iconContainerPath(for: path) ?? path
            defer {
                if loadPath != path { try? FileManager.default.removeItem(atPath: loadPath) }
            }

            // `LoadImageW` returns `HANDLE` (`UnsafeMutableRawPointer?`)
            // on Swift's WinSDK overlay; `HICON` is a distinct typed
            // pointer (`UnsafeMutablePointer<HICON__>`). Convert
            // through `OpaquePointer` so the bit pattern is preserved
            // without going through `Int`.
            //
            // Asking for the small-icon metric rather than `LR_DEFAULTSIZE`:
            // this is a notification-area icon, and the default is the large
            // (32px) metric, so the shell would resample a second time to get
            // it down to tray size.
            let side = GetSystemMetrics(SM_CXSMICON)
            let h: HICON? = loadPath.withCString(encodedAs: UTF16.self) { wcs in
                guard let raw = LoadImageW(
                    nil, wcs,
                    UINT(IMAGE_ICON),
                    side, side,
                    UINT(LR_LOADFROMFILE)
                ) else { return nil }
                return HICON(OpaquePointer(raw))
            }
            if h == nil {
                FileHandle.standardError.writeQuietly(
                    Data("swift-pwa: tray icon '\(path)' could not be loaded (\(GetLastError()))\n".utf8)
                )
            }
            if let old = hicon { DestroyIcon(old) }
            hicon = h
            nid.hIcon = h
            nid.uFlags |= UINT(NIF_ICON)
            _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
        }

        /// Repackage a PNG as a single-entry `.ico` in the temp directory, and
        /// return its path. `nil` for anything that isn't a PNG — including a
        /// file `LoadImageW` already handles, which is passed through
        /// untouched.
        ///
        /// Detection is by signature, not by extension: `LoadImageW` sniffs
        /// content (verified — icon bytes named `.png` load fine), so the
        /// extension is the less reliable of the two.
        ///
        /// The container itself is 22 bytes of header in front of the original
        /// PNG bytes, which Windows has accepted inside `.ico` since Vista.
        /// Verified on a real box against the notification area rather than in
        /// a unit test: `swift test` doesn't run on Windows.
        private static func iconContainerPath(for path: String) -> String? {
            guard let png = FileManager.default.contents(atPath: path),
                  png.count > 24,
                  png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            else { return nil }

            /// IHDR is the first chunk, so width and height are at fixed
            /// offsets, big-endian.
            func dimension(at offset: Int) -> Int {
                (0 ..< 4).reduce(0) { $0 << 8 | Int(png[offset + $1]) }
            }
            /// An entry's size field is one byte, where 0 means 256. Anything
            /// larger is declared as 256 and scaled from the real PNG, which is
            /// what the loader reads for the actual pixels anyway.
            func sizeByte(_ value: Int) -> UInt8 {
                value >= 256 || value <= 0 ? 0 : UInt8(value)
            }

            var ico = Data()
            func u16(_ value: Int) {
                ico.append(UInt8(value & 0xFF))
                ico.append(UInt8((value >> 8) & 0xFF))
            }
            func u32(_ value: Int) {
                u16(value & 0xFFFF)
                u16((value >> 16) & 0xFFFF)
            }
            u16(0) // reserved
            u16(1) // type: icon
            u16(1) // one image
            ico.append(sizeByte(dimension(at: 16)))
            ico.append(sizeByte(dimension(at: 20)))
            ico.append(0) // palette entries: not paletted
            ico.append(0) // reserved
            u16(1) // colour planes
            u16(32) // bits per pixel
            u32(png.count)
            u32(22) // payload offset, past this 6 + 16 byte header
            ico.append(png)

            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-tray-\(Foundation.UUID().uuidString).ico")
            guard (try? ico.write(to: out)) != nil else { return nil }
            return out.path
        }

        /// Dark taskbar ⇒ light art. Read from the theme registry each time
        /// rather than cached: a user can switch theme while the app runs, and
        /// there's no cost worth avoiding here.
        ///
        /// `SystemUsesLightTheme`, not `AppsUseLightTheme` — the notification
        /// area is system chrome, and the two are independently settable. A
        /// missing value means the default, which is a dark taskbar.
        public var prefersLightArt: Bool? {
            var value: DWORD = 0
            var size = DWORD(MemoryLayout<DWORD>.size)
            let status = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"
                .withCString(encodedAs: UTF16.self) { subkey in
                    "SystemUsesLightTheme".withCString(encodedAs: UTF16.self) { name in
                        withUnsafeMutablePointer(to: &value) { valuePointer in
                            RegGetValueW(
                                HKEY_CURRENT_USER, subkey, name,
                                DWORD(RRF_RT_REG_DWORD), nil,
                                UnsafeMutableRawPointer(valuePointer), &size
                            )
                        }
                    }
                }
            guard status == ERROR_SUCCESS else { return true }
            return value == 0
        }

        public func setTooltip(_ text: String) {
            // szTip is a fixed 128-WCHAR buffer in NOTIFYICONDATAW;
            // truncate silently if the caller hands us something longer.
            let wide = Array(text.utf16.prefix(127)) + [0]
            withUnsafeMutableBytes(of: &nid.szTip) { dst in
                let cap = dst.count / MemoryLayout<WCHAR>.size
                let n = min(wide.count, cap)
                let dstW = dst.bindMemory(to: WCHAR.self)
                for i in 0 ..< n { dstW[i] = wide[i] }
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
            // `Foundation.UUID()` to disambiguate from the Win32 SDK's
            // `UUID` typealias (`_GUIDDef`), which is also in scope.
            let key = Foundation.UUID()
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
                    let flags = UINT(MF_STRING) | (item.enabled ? 0 : UINT(MF_GRAYED))
                    item.label.withCString(encodedAs: UTF16.self) { wcs in
                        _ = AppendMenuW(menu, flags, UINT_PTR(i + 1), wcs)
                    }
                }
            }
            var pt = POINT()
            GetCursorPos(&pt)
            // SetForegroundWindow before TrackPopupMenu is required
            // by Win32 docs to avoid the menu disappearing on the
            // first click.
            SetForegroundWindow(ownerHwnd)
            // Swift's WinSDK overlay imports `TrackPopupMenu` as
            // returning `Bool`, dropping the chosen-command id we
            // need with `TPM_RETURNCMD`. Route through the C shim
            // (`swiftpwa_track_popup_menu`) which preserves the int.
            let cmd = swiftpwa_track_popup_menu(
                UnsafeMutableRawPointer(menu),
                UINT(TPM_RETURNCMD | TPM_RIGHTBUTTON),
                pt.x, pt.y,
                UnsafeMutableRawPointer(ownerHwnd)
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
            //
            // `MainActor.assumeIsolated` to satisfy Swift 6's rule
            // that nonisolated `deinit` can't access `@MainActor`-
            // isolated stored properties (`nid`, `hicon`). At process
            // exit the runtime is on the main thread anyway.
            MainActor.assumeIsolated {
                var n = nid
                _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &n)
                if let hicon { DestroyIcon(hicon) }
            }
        }
    }

    let trayOwnerWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        guard let hwnd else { return 0 }
        // Inlined `WM_APP+1` rather than referencing
        // `SystemTray.callbackMessage` — the static is `nonisolated`,
        // but some Swift 6.3 nightlies still flag the read from a
        // non-isolated `@convention(c)` closure. Inlining avoids the
        // diagnostic with no runtime cost.
        let dispatchMsg = UINT(WM_APP) + 1
        if msg == dispatchMsg {
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
