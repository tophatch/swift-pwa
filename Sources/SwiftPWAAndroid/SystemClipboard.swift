#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `Clipboard` backed by Android's `ClipboardManager`. All operations
    /// hop to the JVM main thread inside the Kotlin `SwiftPWABridge`
    /// before touching the manager — `ClipboardManager.setPrimaryClip`
    /// in particular is documented as UI-thread-only on some OEM
    /// builds, and the bridge already centralizes the post-to-main
    /// dispatch.
    ///
    /// **Empty / non-text contents.** `readText()` returns `nil` when
    /// the clipboard is empty or holds a non-text item that
    /// `coerceToText` can't render (an in-flight image drag, for
    /// example). `clear()` calls `clearPrimaryClip` on API 28+; on
    /// API 26 / 27 it falls back to `setPrimaryClip(empty)` because
    /// the explicit clear method only landed in P.
    public final class SystemClipboard: Clipboard, @unchecked Sendable {
        public init() {}

        public func readText() async throws -> String? {
            let result: ClipboardTextResult = try await AndroidRPC.call(
                "clipboard.read", EmptyArgs()
            )
            return result.text
        }

        public func writeText(_ text: String) async throws {
            _ = try await AndroidRPC.call(
                "clipboard.write",
                ClipboardWriteTextArgs(text: text),
                as: NoResult.self
            )
        }

        public func clear() async throws {
            try await AndroidRPC.callVoid("clipboard.clear")
        }
    }
#endif
