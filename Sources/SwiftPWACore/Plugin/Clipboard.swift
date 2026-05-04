import Foundation

/// Cross-platform system clipboard. Backends provide a concrete
/// implementation (`SystemClipboard` in `SwiftPWAWebKit` and
/// `SwiftPWAGTK`); tests use `MockClipboard` from `_SwiftPWATestSupport`.
///
/// All methods are `async` because GTK4's `GdkClipboard` is fundamentally
/// asynchronous (`gdk_clipboard_read_text_async`). Apple and GTK3 read
/// synchronously; their implementations hop to the UI thread via
/// `MainThread.run` and await the immediate result.
public protocol Clipboard: AnyObject, Sendable {
    /// Returns the clipboard's plain-text contents, or `nil` if the
    /// clipboard is empty / does not currently hold text.
    func readText() async throws -> String?

    /// Replace the clipboard's contents with `text`.
    func writeText(_ text: String) async throws

    /// Clear the clipboard.
    func clear() async throws
}

// MARK: - DTOs (used by `ClipboardPlugin`)

public struct ClipboardWriteTextArgs: Sendable, Codable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ClipboardTextResult: Sendable, Codable, Equatable {
    public var text: String?
    public init(text: String?) { self.text = text }
}
