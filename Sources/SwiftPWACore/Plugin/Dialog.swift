import Foundation

/// Cross-platform native dialogs — message boxes, confirms, and the
/// platform's file open / save / directory pickers. Backends provide a
/// concrete `SystemDialog` (`SwiftPWAWebKit`, `SwiftPWAGTK`,
/// `SwiftPWAWindows`); tests use `MockDialog` from
/// `_SwiftPWATestSupport`.
///
/// **Parent window.** Every method accepts an optional `WindowID`. When
/// non-nil the dialog is parented (modal, sheet, attached) to that
/// window where the platform supports it: window-modal sheets on macOS,
/// transient-for on GTK, owner HWND on Windows, presenting view
/// controller on iOS. When nil the dialog is app-modal — fine, just
/// less polished. `DialogPlugin` fills this in automatically from
/// `CommandContext.originWindow`, so JS callers don't pass it.
///
/// **Concurrency.** Methods are `async` because every backend's
/// underlying API is either inherently async (the user has to click
/// something) or has a sync-on-main wrapper that has to hop. Backends
/// hop to the UI thread via `MainThread.run` internally.
public protocol Dialog: AnyObject, Sendable {
    /// Show an info / warning / error message box with a single OK
    /// button. Returns when the user dismisses the dialog.
    func message(_ args: DialogMessageArgs, parent: WindowID?) async throws

    /// Show an OK / Cancel confirmation dialog. Returns `true` if the
    /// user picked OK, `false` for Cancel or any other dismissal.
    func confirm(_ args: DialogConfirmArgs, parent: WindowID?) async throws -> Bool

    /// Show the platform's file-open dialog. Returns the picked paths
    /// (one entry when `multiple` is false / unset) or an empty array
    /// when the user cancels.
    func openFile(_ args: DialogOpenFileArgs, parent: WindowID?) async throws -> [String]

    /// Show the platform's file-save dialog. Returns the picked path,
    /// or `nil` when the user cancels.
    ///
    /// **iOS:** returns `nil` and logs a one-shot stderr warning. iOS
    /// has no "pick a location, get a writable path back" panel — its
    /// save model is content-first, which is what `exportFile` is for.
    /// Use `dialog.exportFile` on iOS (and it works everywhere else too).
    func saveFile(_ args: DialogSaveFileArgs, parent: WindowID?) async throws -> String?

    /// Let the user save app-provided **content** to a location of their
    /// choosing, and return the destination (a filesystem path on
    /// desktop, the picked file's path on iOS, a `content://` URI on
    /// Android) — or `nil` if the user cancels.
    ///
    /// This is the *content-first* counterpart to `saveFile`. Where
    /// `saveFile` returns a destination path the caller then writes to,
    /// `exportFile` carries the bytes itself (via `path` or `dataBase64`
    /// on `DialogExportFileArgs`) and the backend does the write. That
    /// shape is what lets iOS participate at all — its only save
    /// affordance, `UIDocumentPickerViewController(forExporting:)`, needs
    /// an already-written file — and it rounds out the dialog surface on
    /// every other platform: a save panel followed by a write on
    /// desktop, a SAF create-document followed by a write on Android.
    func exportFile(_ args: DialogExportFileArgs, parent: WindowID?) async throws -> String?

    /// Show the platform's directory-picker dialog. Returns the picked
    /// directory paths (one entry when `multiple` is false / unset) or an
    /// empty array when the user cancels.
    ///
    /// **Multi-select** is desktop-only. macOS / Windows / GTK honor
    /// `multiple`; iOS does too via `UIDocumentPickerViewController`.
    /// Android's `ACTION_OPEN_DOCUMENT_TREE` can only grant one tree at a
    /// time, so `multiple` is ignored there and at most one path comes
    /// back — documented in `docs/android-setup.md`.
    func openDirectory(_ args: DialogOpenDirectoryArgs, parent: WindowID?) async throws -> [String]
}

// MARK: - Severity

/// Visual severity hint. Maps to platform conventions: `NSAlert.Style`
/// on macOS, `UIAlertController` style on iOS, `GtkMessageType` on
/// Linux, `TASKDIALOG_FLAGS` icon on Windows. Defaults to `.info` when
/// omitted.
public enum DialogKind: String, Sendable, Codable, Equatable {
    case info, warning, error
}

// MARK: - DTOs

public struct DialogMessageArgs: Sendable, Codable, Equatable {
    public var title: String?
    public var message: String
    public var kind: DialogKind?

    public init(title: String? = nil, message: String, kind: DialogKind? = nil) {
        self.title = title
        self.message = message
        self.kind = kind
    }
}

public struct DialogConfirmArgs: Sendable, Codable, Equatable {
    public var title: String?
    public var message: String
    public var okLabel: String?
    public var cancelLabel: String?
    public var kind: DialogKind?

    public init(
        title: String? = nil,
        message: String,
        okLabel: String? = nil,
        cancelLabel: String? = nil,
        kind: DialogKind? = nil
    ) {
        self.title = title
        self.message = message
        self.okLabel = okLabel
        self.cancelLabel = cancelLabel
        self.kind = kind
    }
}

/// File-type filter shown in open / save dialogs. `name` is the
/// human-readable label ("Images"); `extensions` lists extensions
/// without the leading dot (`["png", "jpg", "jpeg"]`).
public struct DialogFileFilter: Sendable, Codable, Equatable {
    public var name: String
    public var extensions: [String]

    public init(name: String, extensions: [String]) {
        self.name = name
        self.extensions = extensions
    }
}

public struct DialogOpenFileArgs: Sendable, Codable, Equatable {
    public var title: String?
    public var defaultPath: String?
    public var filters: [DialogFileFilter]?
    public var multiple: Bool?

    public init(
        title: String? = nil,
        defaultPath: String? = nil,
        filters: [DialogFileFilter]? = nil,
        multiple: Bool? = nil
    ) {
        self.title = title
        self.defaultPath = defaultPath
        self.filters = filters
        self.multiple = multiple
    }
}

public struct DialogSaveFileArgs: Sendable, Codable, Equatable {
    public var title: String?
    public var defaultPath: String?
    public var defaultName: String?
    public var filters: [DialogFileFilter]?

    public init(
        title: String? = nil,
        defaultPath: String? = nil,
        defaultName: String? = nil,
        filters: [DialogFileFilter]? = nil
    ) {
        self.title = title
        self.defaultPath = defaultPath
        self.defaultName = defaultName
        self.filters = filters
    }
}

/// Arguments for `dialog.exportFile`. The content to export is supplied
/// as **exactly one** of `path` (an on-disk source file the app can
/// read) or `dataBase64` (inline bytes). `defaultName` seeds the
/// picker's filename field; `filters` narrows the type where the
/// platform's save UI supports it.
public struct DialogExportFileArgs: Sendable, Codable, Equatable {
    public var title: String?
    /// Suggested filename shown in the save/export picker (e.g.
    /// `"report.csv"`). Falls back to the source file's name, then
    /// `"export"`, when omitted.
    public var defaultName: String?
    public var filters: [DialogFileFilter]?
    /// On-disk source file to export. Mutually exclusive with
    /// `dataBase64`.
    public var path: String?
    /// Inline content to export, base64-encoded. Mutually exclusive with
    /// `path`.
    public var dataBase64: String?

    public init(
        title: String? = nil,
        defaultName: String? = nil,
        filters: [DialogFileFilter]? = nil,
        path: String? = nil,
        dataBase64: String? = nil
    ) {
        self.title = title
        self.defaultName = defaultName
        self.filters = filters
        self.path = path
        self.dataBase64 = dataBase64
    }
}

public struct DialogOpenDirectoryArgs: Sendable, Codable, Equatable {
    public var title: String?
    public var defaultPath: String?
    /// Allow selecting more than one directory in a single invocation.
    /// Desktop-only (macOS / Windows / GTK / iOS); ignored on Android,
    /// whose SAF tree picker grants one directory at a time.
    public var multiple: Bool?

    public init(title: String? = nil, defaultPath: String? = nil, multiple: Bool? = nil) {
        self.title = title
        self.defaultPath = defaultPath
        self.multiple = multiple
    }
}

// MARK: - Result envelopes (used by `DialogPlugin`)

public struct DialogConfirmResult: Sendable, Codable, Equatable {
    public var ok: Bool
    public init(ok: Bool) { self.ok = ok }
}

public struct DialogOpenFileResult: Sendable, Codable, Equatable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

public struct DialogPathResult: Sendable, Codable, Equatable {
    public var path: String?
    public init(path: String?) { self.path = path }
}

/// Result of `dialog.openDirectory`. Carries the full `paths` array
/// (one entry unless `multiple` was requested) plus a `path`
/// convenience holding the first selection — kept so pre-0.7.7 JS
/// callers that read `result.path` keep working after directory
/// multi-select landed.
public struct DialogOpenDirectoryResult: Sendable, Codable, Equatable {
    public var path: String?
    public var paths: [String]

    public init(paths: [String]) {
        self.paths = paths
        path = paths.first
    }
}

// MARK: - exportFile content resolution

public extension DialogExportFileArgs {
    /// Resolve the content to export as raw bytes: reads `path`, or
    /// decodes `dataBase64`. Throws `E_HANDLER` if neither (or both) is
    /// provided, or if `dataBase64` isn't valid base64.
    func resolveData() throws -> Data {
        switch (path, dataBase64) {
        case let (source?, nil):
            return try Data(contentsOf: URL(fileURLWithPath: source))
        case let (nil, b64?):
            guard let data = Data(base64Encoded: b64) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "dialog.exportFile: dataBase64 is not valid base64"
                )
            }
            return data
        case (nil, nil):
            throw BridgeError(
                code: BridgeError.handler,
                message: "dialog.exportFile: provide exactly one of path / dataBase64 (got neither)"
            )
        case (.some, .some):
            throw BridgeError(
                code: BridgeError.handler,
                message: "dialog.exportFile: provide exactly one of path / dataBase64 (got both)"
            )
        }
    }

    /// A safe suggested filename for the destination: `defaultName` if
    /// set, else the source file's last path component, else `"export"`.
    var suggestedName: String {
        if let defaultName, !defaultName.isEmpty { return defaultName }
        if let path {
            let base = (path as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return "export"
    }

    /// Materialize the content into a temporary file (named
    /// `suggestedName`) and return its URL. For backends whose export
    /// API takes an already-written source file (iOS `forExporting:`).
    /// When the content is *already* an on-disk file (`path` set,
    /// `dataBase64` nil) that file's URL is returned directly — no copy.
    /// The caller owns cleanup of any temp file created here.
    func materializeTempFile() throws -> URL {
        if let path, dataBase64 == nil {
            return URL(fileURLWithPath: path)
        }
        let data = try resolveData()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedName)
        try data.write(to: url)
        return url
    }
}

public extension Dialog {
    /// Default so a custom `Dialog` conformance that predates
    /// `exportFile` still compiles. The five shipped backends all
    /// override this; the default just fails loudly rather than
    /// silently no-op'ing.
    func exportFile(_: DialogExportFileArgs, parent _: WindowID?) async throws -> String? {
        throw BridgeError(
            code: BridgeError.unimplemented,
            message: "dialog.exportFile is not implemented by this Dialog"
        )
    }
}
