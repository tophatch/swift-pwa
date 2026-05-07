import Foundation
import SwiftPWACore

/// In-memory `Dialog` for unit tests. State is `@MainActor`-isolated so
/// it satisfies `Sendable` without locks; the protocol itself isn't
/// `@MainActor` so tests still exercise the actor hop.
///
/// Each method records the args it was called with (so the test can
/// assert the plugin's arg-mapping) and returns whatever the test stuck
/// into the matching `next*` slot. Defaults are deliberately
/// non-empty for `confirm` (`true`) and empty for the file pickers, so
/// "happy path" tests don't need to set anything.
@MainActor
public final class MockDialog: Dialog {
    public enum Action: Sendable, Equatable {
        case message(DialogMessageArgs, parent: WindowID?)
        case confirm(DialogConfirmArgs, parent: WindowID?)
        case openFile(DialogOpenFileArgs, parent: WindowID?)
        case saveFile(DialogSaveFileArgs, parent: WindowID?)
        case openDirectory(DialogOpenDirectoryArgs, parent: WindowID?)
    }

    public private(set) var actions: [Action] = []

    public var nextConfirm: Bool = true
    public var nextOpenFilePaths: [String] = []
    public var nextSaveFilePath: String?
    public var nextOpenDirectoryPath: String?

    public init() {}

    public func message(_ args: DialogMessageArgs, parent: WindowID?) async throws {
        actions.append(.message(args, parent: parent))
    }

    public func confirm(_ args: DialogConfirmArgs, parent: WindowID?) async throws -> Bool {
        actions.append(.confirm(args, parent: parent))
        return nextConfirm
    }

    public func openFile(_ args: DialogOpenFileArgs, parent: WindowID?) async throws -> [String] {
        actions.append(.openFile(args, parent: parent))
        return nextOpenFilePaths
    }

    public func saveFile(_ args: DialogSaveFileArgs, parent: WindowID?) async throws -> String? {
        actions.append(.saveFile(args, parent: parent))
        return nextSaveFilePath
    }

    public func openDirectory(_ args: DialogOpenDirectoryArgs, parent: WindowID?) async throws -> String? {
        actions.append(.openDirectory(args, parent: parent))
        return nextOpenDirectoryPath
    }
}
