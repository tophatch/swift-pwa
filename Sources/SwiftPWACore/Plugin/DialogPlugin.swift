import Foundation

/// Optional plugin exposing `dialog.*` to JS. Not auto-installed because
/// constructing a backend `SystemDialog` is cheap but the underlying
/// frameworks (`AppKit` / `UIKit` save panels, `GtkFileChooser`, the
/// Win32 IFileDialog COM stack) shouldn't load for apps that don't use
/// dialogs. Users opt in:
///
/// ```swift
/// runtime.run { ctx in
///     ctx.use(DialogPlugin(SystemDialog()))
/// }
/// ```
///
/// The originating window is plumbed through automatically — every
/// command pulls `parent` from `CommandContext.originWindow`, so
/// JS-side calls don't pass it.
public struct DialogPlugin: Plugin {
    public static let pluginName = "dialog"

    private let dialog: any Dialog

    public init(_ dialog: any Dialog) {
        self.dialog = dialog
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let dialog = dialog

        registry.register(
            "dialog.message",
            typed: { (args: DialogMessageArgs, ctx) async throws -> EmptyResult in
                try await dialog.message(args, parent: ctx.originWindow)
                return EmptyResult()
            }
        )

        registry.register(
            "dialog.confirm",
            typed: { (args: DialogConfirmArgs, ctx) async throws -> DialogConfirmResult in
                try await DialogConfirmResult(ok: dialog.confirm(args, parent: ctx.originWindow))
            }
        )

        registry.register(
            "dialog.openFile",
            typed: { (args: DialogOpenFileArgs, ctx) async throws -> DialogOpenFileResult in
                let paths = try await dialog.openFile(args, parent: ctx.originWindow)
                return try await DialogOpenFileResult(
                    paths: paths,
                    bookmarks: dialog.bookmarks(forPaths: paths)
                )
            }
        )

        registry.register(
            "dialog.saveFile",
            typed: { (args: DialogSaveFileArgs, ctx) async throws -> DialogPathResult in
                try await DialogPathResult(path: dialog.saveFile(args, parent: ctx.originWindow))
            }
        )

        registry.register(
            "dialog.openDirectory",
            typed: { (args: DialogOpenDirectoryArgs, ctx) async throws -> DialogOpenDirectoryResult in
                let paths = try await dialog.openDirectory(args, parent: ctx.originWindow)
                return try await DialogOpenDirectoryResult(
                    paths: paths,
                    bookmarks: dialog.bookmarks(forPaths: paths)
                )
            }
        )

        registry.register(
            "dialog.resolveBookmark",
            typed: { (args: DialogResolveBookmarkArgs, _) async throws -> DialogResolveBookmarkResult in
                try await dialog.resolveBookmark(args.bookmark)
            }
        )

        registry.register(
            "dialog.exportFile",
            typed: { (args: DialogExportFileArgs, ctx) async throws -> DialogPathResult in
                try await DialogPathResult(path: dialog.exportFile(args, parent: ctx.originWindow))
            }
        )
    }
}

private extension Dialog {
    /// Mint a token per picked path so the JS result carries `bookmarks`
    /// beside `paths` without a second round trip. Backends report "no
    /// durable handle for this one" as a `nil` slot, keeping the pick
    /// itself successful; a thrown error means the mint went wrong and is
    /// worth failing the call over.
    func bookmarks(forPaths paths: [String]) async throws -> [String?] {
        var out: [String?] = []
        out.reserveCapacity(paths.count)
        for path in paths {
            try await out.append(makeBookmark(forPath: path))
        }
        return out
    }
}
