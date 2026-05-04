#if os(Linux)
    import CGtk4Shim
    import Foundation
    import SwiftPWACore

    /// `Clipboard` backed by `GdkClipboard` on the GTK4 backend.
    ///
    /// GTK4 dropped `GtkClipboard`'s synchronous reads; the only way to
    /// fetch text is via `gdk_clipboard_read_text_async`. We bridge that
    /// into a Swift `CheckedContinuation` through the C shim — the same
    /// trick the GTK4 backend uses for `evaluateJavaScript`.
    ///
    /// `clear()` mirrors GTK3 semantics: it relinquishes our local
    /// ownership of the clipboard via `gdk_clipboard_set_content(NULL)`,
    /// it does not wipe content held by another app.
    public final class SystemClipboard: Clipboard, @unchecked Sendable {
        public init() {}

        public func readText() async throws -> String? {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                let boxRaw = UInt(bitPattern: Unmanaged.passRetained(
                    ClipboardReadBox(continuation: cont)
                ).toOpaque())
                Task {
                    await MainThread.run {
                        guard let boxPtr = UnsafeMutableRawPointer(bitPattern: boxRaw) else {
                            return
                        }
                        guard let cb = swiftpwa_clipboard_default() else {
                            // No default display — resume with nil and
                            // release the retained box.
                            Unmanaged<ClipboardReadBox>.fromOpaque(boxPtr)
                                .takeRetainedValue()
                                .continuation.resume(returning: nil)
                            return
                        }
                        swiftpwa_clipboard_read_text(cb, clipboardReadCallback, boxPtr)
                    }
                }
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

    /// Heap box carrying the read-text continuation across the C boundary.
    /// Owned by exactly one party at a time (Swift hands it to C; the
    /// callback hands it back via `clipboardReadCallback`).
    final class ClipboardReadBox: @unchecked Sendable {
        let continuation: CheckedContinuation<String?, Never>
        init(continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }
    }

    /// `@convention(c)` callback for `swiftpwa_clipboard_read_text`.
    /// Fires on the GTK main thread once `gdk_clipboard_read_text_async`
    /// completes.
    ///
    /// Read failures (e.g. "no text on the clipboard", "unsupported
    /// MIME type") are surfaced to JS as `nil` rather than thrown,
    /// matching the Apple / GTK3 behaviour where an empty clipboard is
    /// not an error.
    let clipboardReadCallback: @convention(c) (
        UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<CChar>?,
        UnsafeMutableRawPointer?
    ) -> Void = { textPtr, errPtr, userData in
        guard let userData else { return }
        let box = Unmanaged<ClipboardReadBox>.fromOpaque(userData).takeRetainedValue()
        if let errPtr {
            g_free(UnsafeMutableRawPointer(errPtr))
            box.continuation.resume(returning: nil)
            return
        }
        if let textPtr {
            let s = String(cString: textPtr)
            g_free(UnsafeMutableRawPointer(textPtr))
            box.continuation.resume(returning: s)
        } else {
            box.continuation.resume(returning: nil)
        }
    }
#endif
