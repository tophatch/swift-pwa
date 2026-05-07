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
    /// has no system save panel — apps export through
    /// `UIDocumentPickerViewController(forExporting:)` (which takes an
    /// already-written file URL) or a `UIActivityViewController` share
    /// sheet, neither of which fits the cross-platform API shape. Use
    /// the system APIs directly there.
    func saveFile(_ args: DialogSaveFileArgs, parent: WindowID?) async throws -> String?

    /// Show the platform's directory-picker dialog. Returns the picked
    /// directory path, or `nil` when the user cancels.
    func openDirectory(_ args: DialogOpenDirectoryArgs, parent: WindowID?) async throws -> String?
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

public struct DialogOpenDirectoryArgs: Sendable, Codable, Equatable {
    public var title: String?
    public var defaultPath: String?

    public init(title: String? = nil, defaultPath: String? = nil) {
        self.title = title
        self.defaultPath = defaultPath
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
