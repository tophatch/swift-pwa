#if os(Windows)
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// `Clipboard` backed by the Win32 Clipboard API.
    ///
    /// Hops to the UI thread via `MainThread.run` for every operation.
    /// `OpenClipboard` / `GetClipboardData` are documented as
    /// requiring an owner HWND and a single-clipboard-scope, but in
    /// practice they work from any thread that owns a message queue —
    /// we use the same UI thread that pumps Win32 messages so the
    /// platform's clipboard-update notifications stay coherent.
    public final class SystemClipboard: Clipboard, @unchecked Sendable {
        public init() {}

        public func readText() async throws -> String? {
            await MainThread.run { () -> String? in
                guard OpenClipboard(nil) else { return nil }
                defer { CloseClipboard() }
                guard let h = GetClipboardData(UINT(CF_UNICODETEXT)) else { return nil }
                guard let p = GlobalLock(h) else { return nil }
                defer { GlobalUnlock(h) }
                let wcs = p.assumingMemoryBound(to: WCHAR.self)
                return String(decodingCString: wcs, as: UTF16.self)
            }
        }

        public func writeText(_ text: String) async throws {
            _ = await MainThread.run { () -> Bool in
                guard OpenClipboard(nil) else { return false }
                defer { CloseClipboard() }
                EmptyClipboard()
                let utf16 = Array(text.utf16) + [0]
                let bytes = utf16.count * MemoryLayout<UInt16>.stride
                let h = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes))
                guard let h else { return false }
                guard let dst = GlobalLock(h) else {
                    GlobalFree(h); return false
                }
                utf16.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress, bytes)
                }
                GlobalUnlock(h)
                if SetClipboardData(UINT(CF_UNICODETEXT), h) == nil {
                    GlobalFree(h)
                    return false
                }
                // SetClipboardData transfers ownership of `h` to the
                // OS on success — do not free.
                return true
            }
        }

        public func clear() async throws {
            _ = await MainThread.run { () -> Bool in
                guard OpenClipboard(nil) else { return false }
                defer { CloseClipboard() }
                return EmptyClipboard()
            }
        }
    }
#endif
