#if os(Windows)
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// Hidden message-only window that fronts the `MainThread` hook on
    /// Windows. `MainThread.run` heap-boxes the closure, posts
    /// `WM_APP+1` to this window, and the WndProc unboxes and fires
    /// the closure on the UI thread.
    ///
    /// We need this because Swift's MainActor executor on Windows is
    /// backed by libdispatch's main queue, which `GetMessageW` doesn't
    /// pump. So `await MainActor.run` from a cooperative-pool task
    /// would hang the same way it does under `gtk_main()` on Linux.
    enum MainThreadDispatcher {
        /// The custom window message we post for queued closures. Must
        /// be in the application range (`WM_APP..0xBFFF`) per Win32
        /// guidelines so it doesn't collide with anything WebView2 or
        /// the shell sends us.
        static let dispatchMessage: UINT = .init(WM_APP) + 1

        /// Marker class atom — `RegisterClassExW` hands back an `ATOM`
        /// (UInt16). We register on first call and reuse it for
        /// subsequent windows; doesn't matter in practice (we only
        /// ever create one), but `RegisterClassExW` errors on a
        /// duplicate registration.
        // `nonisolated(unsafe)` because the static var is mutable
        // global state. The invariant that protects it: `create()` is
        // only ever called once at startup, on the UI thread, before
        // any other code touches it. Same pattern as
        // `MainThread._hook` in `SwiftPWACore/MainThread.swift`.
        private nonisolated(unsafe) static var classAtom: ATOM = 0
        private static let className: [WCHAR] = "SwiftPWADispatcher".utf16.map { WCHAR($0) } + [0]

        static func create() -> HWND {
            registerClassIfNeeded()
            // HWND_MESSAGE makes this a message-only window: it
            // doesn't render, doesn't appear in z-order, and isn't
            // enumerated by EnumWindows. Exactly what we want.
            let hwnd = className.withUnsafeBufferPointer { name -> HWND? in
                CreateWindowExW(
                    0,
                    name.baseAddress,
                    nil,
                    0,
                    0, 0, 0, 0,
                    HWND_MESSAGE,
                    nil,
                    GetModuleHandleW(nil),
                    nil
                )
            }
            guard let hwnd else {
                fatalError("swift-pwa: CreateWindowExW(HWND_MESSAGE) failed (\(GetLastError()))")
            }
            return hwnd
        }

        static func post(to hwnd: HWND, body: @escaping @Sendable () -> Void) {
            let box = Unmanaged.passRetained(ClosureBox(body)).toOpaque()
            // Carry the boxed closure pointer through LPARAM. WPARAM
            // is reserved for future use (e.g. distinguishing message
            // categories if we ever multiplex this window).
            let lparam = LPARAM(Int(bitPattern: box))
            // Swift's WinSDK overlay (6.3+) imports `PostMessageW` as
            // returning Swift `Bool`, not the C `BOOL` (Int32). Use it
            // directly.
            if !PostMessageW(hwnd, dispatchMessage, 0, lparam) {
                // PostMessage failed — release the box so we don't
                // leak. The WndProc retains-then-fires; on a failed
                // post nothing else will pick it up.
                Unmanaged<ClosureBox>.fromOpaque(box).release()
            }
        }

        private static func registerClassIfNeeded() {
            guard classAtom == 0 else { return }
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = dispatcherWndProc
            wc.hInstance = GetModuleHandleW(nil)
            classAtom = className.withUnsafeBufferPointer { name -> ATOM in
                wc.lpszClassName = name.baseAddress
                return RegisterClassExW(&wc)
            }
            if classAtom == 0 {
                fatalError("swift-pwa: RegisterClassExW failed (\(GetLastError()))")
            }
        }
    }

    /// Heap-boxed `@Sendable () -> Void` closure ferried across the
    /// `PostMessageW` boundary.
    final class ClosureBox: @unchecked Sendable {
        let body: @Sendable () -> Void
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    }

    /// `@convention(c)` WndProc for the dispatcher window.
    /// Always invoked on the UI thread (`DispatchMessageW` runs the
    /// WndProc inline on the calling thread).
    let dispatcherWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        if msg == MainThreadDispatcher.dispatchMessage {
            let raw = UInt(bitPattern: Int(lParam))
            if let opaque = UnsafeMutableRawPointer(bitPattern: raw) {
                let box = Unmanaged<ClosureBox>.fromOpaque(opaque).takeRetainedValue()
                box.body()
            }
            return 0
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
#endif
