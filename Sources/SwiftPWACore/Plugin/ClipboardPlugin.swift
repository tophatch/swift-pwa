import Foundation

/// Built-in plugin that exposes the `clipboard.*` command set to JS.
///
/// Backends auto-install this in their `AppContext.init` paired with a
/// platform `SystemClipboard`; users don't need to wire it up manually.
public struct ClipboardPlugin: Plugin {
    public static let pluginName = "clipboard"

    private let clipboard: any Clipboard

    public init(_ clipboard: any Clipboard) {
        self.clipboard = clipboard
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let clipboard = clipboard

        registry.register(
            "clipboard.readText",
            typed: { (_: EmptyArgs, _) async throws -> ClipboardTextResult in
                try await ClipboardTextResult(text: clipboard.readText())
            }
        )

        registry.register(
            "clipboard.writeText",
            typed: { (args: ClipboardWriteTextArgs, _) async throws -> EmptyResult in
                try await clipboard.writeText(args.text)
                return EmptyResult()
            }
        )

        registry.register(
            "clipboard.clear",
            typed: { (_: EmptyArgs, _) async throws -> EmptyResult in
                try await clipboard.clear()
                return EmptyResult()
            }
        )
    }
}
