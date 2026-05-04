#if os(Linux)
    import CGtk3Shim
    import Foundation
    import SwiftPWACore

    /// `Clipboard` backed by `GtkClipboard` (the X11 / Wayland CLIPBOARD
    /// selection) on the GTK3 backend.
    ///
    /// All entry points hop to the GTK main thread via `MainThread.run`
    /// because `gtk_clipboard_*` is not safe from background threads —
    /// `gtk_clipboard_wait_for_text` in particular spins a nested main
    /// loop and would deadlock if called off-thread.
    ///
    /// `clear()` only relinquishes our local ownership of the selection;
    /// content set by another app remains the system-wide value. This
    /// mirrors GTK4's `gdk_clipboard_set_content(NULL)` semantics so the
    /// two backends behave the same.
    public final class SystemClipboard: Clipboard, @unchecked Sendable {
        public init() {}

        public func readText() async throws -> String? {
            await MainThread.run { () -> String? in
                guard let cb = swiftpwa_clipboard_default() else { return nil }
                guard let cstr = swiftpwa_clipboard_wait_for_text(cb) else { return nil }
                let s = String(cString: cstr)
                g_free(UnsafeMutableRawPointer(cstr))
                return s
            }
        }

        public func writeText(_ text: String) async throws {
            _ = await MainThread.run { () -> Bool in
                guard let cb = swiftpwa_clipboard_default() else { return false }
                text.withCString { swiftpwa_clipboard_set_text(cb, $0) }
                return true
            }
        }

        public func clear() async throws {
            _ = await MainThread.run { () -> Bool in
                guard let cb = swiftpwa_clipboard_default() else { return false }
                swiftpwa_clipboard_clear(cb)
                return true
            }
        }
    }
#endif
