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
                try await DialogOpenFileResult(paths: dialog.openFile(args, parent: ctx.originWindow))
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
            typed: { (args: DialogOpenDirectoryArgs, ctx) async throws -> DialogPathResult in
                try await DialogPathResult(path: dialog.openDirectory(args, parent: ctx.originWindow))
            }
        )
    }
}
