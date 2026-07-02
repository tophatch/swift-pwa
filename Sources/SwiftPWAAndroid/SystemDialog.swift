#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `Dialog` backed by Android's `AlertDialog.Builder` for message /
    /// confirm and the Storage Access Framework for file pickers
    /// (`Intent.ACTION_OPEN_DOCUMENT`, `Intent.ACTION_CREATE_DOCUMENT`,
    /// `Intent.ACTION_OPEN_DOCUMENT_TREE`).
    ///
    /// **SAF returns `content://` URIs, not filesystem paths.** That's
    /// the whole point of Storage Access Framework on modern Android —
    /// scoped storage means apps don't get raw filesystem paths to
    /// arbitrary user-selected files. The picked URIs come back as
    /// strings in the same `[String]` slot as the desktop file paths;
    /// callers that need bytes should resolve them through
    /// `ContentResolver` (Android-side) or the swift-pwa `Fs` plugin
    /// once it grows URI support. The behaviour is documented in
    /// `docs/android-setup.md` so JS callers don't try to `fs.readText`
    /// the result and get a "no such file" surprise.
    ///
    /// **Filters.** `DialogFileFilter.extensions` are mapped to the
    /// nearest MIME types via a small built-in table (png → image/png,
    /// pdf → application/pdf, etc.); unknown extensions fall back to
    /// `*/*` so the picker still opens. SAF doesn't take "extension
    /// patterns" the way GTK and Win32 file dialogs do — MIME is the
    /// only filter knob the framework exposes.
    ///
    /// `parent` is ignored on Android — the platform owns Activity
    /// modality and we'd parent every dialog to the host Activity
    /// regardless. The argument stays in the protocol to match the
    /// other backends.
    public final class SystemDialog: Dialog, @unchecked Sendable {
        public init() {}

        public func message(_ args: DialogMessageArgs, parent _: WindowID?) async throws {
            _ = try await AndroidRPC.call(
                "dialog.message", args, as: NoResult.self
            )
        }

        public func confirm(_ args: DialogConfirmArgs, parent _: WindowID?) async throws -> Bool {
            let result: DialogConfirmResult = try await AndroidRPC.call(
                "dialog.confirm", args
            )
            return result.ok
        }

        public func openFile(_ args: DialogOpenFileArgs, parent _: WindowID?) async throws -> [String] {
            let result: DialogOpenFileResult = try await AndroidRPC.call(
                "dialog.openFile", args
            )
            return result.paths
        }

        public func saveFile(_ args: DialogSaveFileArgs, parent _: WindowID?) async throws -> String? {
            let result: DialogPathResult = try await AndroidRPC.call(
                "dialog.saveFile", args
            )
            return result.path
        }

        public func openDirectory(_ args: DialogOpenDirectoryArgs, parent _: WindowID?) async throws -> [String] {
            // SAF's ACTION_OPEN_DOCUMENT_TREE grants one tree per launch, so
            // `args.multiple` is ignored here — the Kotlin host returns a
            // single `path`, which we surface as a zero- or one-element array
            // to match the cross-platform `[String]` contract.
            let result: DialogPathResult = try await AndroidRPC.call(
                "dialog.openDirectory", args
            )
            return result.path.map { [$0] } ?? []
        }
    }
#endif
