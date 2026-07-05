#if os(Linux)
    import CGtk3Shim
    import Foundation
    import SwiftPWACore

    /// GTK3 `Dialog` backed by `GtkMessageDialog` (message / confirm)
    /// and `GtkFileChooserDialog` (open / save / directory).
    ///
    /// All four dialogs are run synchronously via `gtk_dialog_run`,
    /// which spins a nested GLib main loop. That blocks the *async*
    /// flow without blocking the UI: GTK keeps pumping paint /
    /// pointer / WebKit IPC while the modal is up. We hop to the GTK
    /// main thread via `MainThread.run`, mirroring the rest of the
    /// GTK backend.
    ///
    /// **Parent window.** When `parent` is non-nil and resolves to a
    /// known `GTKWindow`, the dialog is `transient_for` it (centered
    /// over it, shaded the way GTK convention expects). When `nil`
    /// or the id no longer maps to an open window, we fall through
    /// to a parent-less modal — still functional, just less polished.
    public final class SystemDialog: Dialog, @unchecked Sendable {
        public init() {}

        public func message(_ args: DialogMessageArgs, parent: WindowID?) async throws {
            try await MainThread.run { [self] in try messageOnMain(args, parent: parent) }
        }

        public func confirm(_ args: DialogConfirmArgs, parent: WindowID?) async throws -> Bool {
            try await MainThread.run { [self] in try confirmOnMain(args, parent: parent) }
        }

        public func openFile(_ args: DialogOpenFileArgs, parent: WindowID?) async throws -> [String] {
            try await MainThread.run { [self] in try openFileOnMain(args, parent: parent) }
        }

        public func saveFile(_ args: DialogSaveFileArgs, parent: WindowID?) async throws -> String? {
            try await MainThread.run { [self] in try saveFileOnMain(args, parent: parent) }
        }

        public func openDirectory(_ args: DialogOpenDirectoryArgs, parent: WindowID?) async throws -> [String] {
            try await MainThread.run { [self] in try openDirectoryOnMain(args, parent: parent) }
        }

        public func exportFile(_ args: DialogExportFileArgs, parent: WindowID?) async throws -> String? {
            // Resolve bytes first so bad input fails before the chooser.
            let data = try args.resolveData()
            guard let dest = try await MainThread.run({ [self] in try exportFileChooseOnMain(args, parent: parent) })
            else { return nil }
            try data.write(to: URL(fileURLWithPath: dest))
            return dest
        }

        // MARK: - Main-thread bodies

        @MainActor
        private func messageOnMain(_ args: DialogMessageArgs, parent: WindowID?) throws {
            let parentPtr = lookupParent(parent)
            let dialog: UnsafeMutablePointer<GtkWidget> = args.title.withOptionalCString { title in
                args.message.withCString { message in
                    swiftpwa_message_dialog_new(parentPtr, kindToShim(args.kind), title, message)
                }
            }
            _ = swiftpwa_dialog_run(dialog)
            swiftpwa_widget_destroy(dialog)
        }

        @MainActor
        private func confirmOnMain(_ args: DialogConfirmArgs, parent: WindowID?) throws -> Bool {
            let parentPtr = lookupParent(parent)
            let dialog: UnsafeMutablePointer<GtkWidget> = args.title.withOptionalCString { title in
                args.message.withCString { message in
                    args.okLabel.withOptionalCString { ok in
                        args.cancelLabel.withOptionalCString { cancel in
                            swiftpwa_confirm_dialog_new(
                                parentPtr,
                                kindToShim(args.kind),
                                title, message,
                                ok, cancel
                            )
                        }
                    }
                }
            }
            let resp = swiftpwa_dialog_run(dialog)
            swiftpwa_widget_destroy(dialog)
            return resp == GTK_RESPONSE_OK.rawValue
        }

        @MainActor
        private func openFileOnMain(_ args: DialogOpenFileArgs, parent: WindowID?) throws -> [String] {
            let dialog = makeFileChooser(
                parent: parent,
                action: SWIFTPWA_FILE_CHOOSER_OPEN,
                title: args.title,
                folder: args.defaultPath,
                filename: nil,
                allowMultiple: args.multiple ?? false
            )
            applyFilters(args.filters ?? [], to: dialog)
            let resp = swiftpwa_dialog_run(dialog)
            defer { swiftpwa_widget_destroy(dialog) }
            guard resp == GTK_RESPONSE_OK.rawValue else { return [] }
            return takeFilenames(dialog)
        }

        @MainActor
        private func saveFileOnMain(_ args: DialogSaveFileArgs, parent: WindowID?) throws -> String? {
            let dialog = makeFileChooser(
                parent: parent,
                action: SWIFTPWA_FILE_CHOOSER_SAVE,
                title: args.title,
                folder: args.defaultPath,
                filename: args.defaultName,
                allowMultiple: false
            )
            applyFilters(args.filters ?? [], to: dialog)
            let resp = swiftpwa_dialog_run(dialog)
            defer { swiftpwa_widget_destroy(dialog) }
            guard resp == GTK_RESPONSE_OK.rawValue else { return nil }
            return takeFilename(dialog)
        }

        @MainActor
        private func exportFileChooseOnMain(_ args: DialogExportFileArgs, parent: WindowID?) throws -> String? {
            let dialog = makeFileChooser(
                parent: parent,
                action: SWIFTPWA_FILE_CHOOSER_SAVE,
                title: args.title,
                folder: nil,
                filename: args.suggestedName,
                allowMultiple: false
            )
            applyFilters(args.filters ?? [], to: dialog)
            let resp = swiftpwa_dialog_run(dialog)
            defer { swiftpwa_widget_destroy(dialog) }
            guard resp == GTK_RESPONSE_OK.rawValue else { return nil }
            return takeFilename(dialog)
        }

        @MainActor
        private func openDirectoryOnMain(_ args: DialogOpenDirectoryArgs, parent: WindowID?) throws -> [String] {
            let dialog = makeFileChooser(
                parent: parent,
                action: SWIFTPWA_FILE_CHOOSER_SELECT_FOLDER,
                title: args.title,
                folder: args.defaultPath,
                filename: nil,
                allowMultiple: args.multiple ?? false
            )
            let resp = swiftpwa_dialog_run(dialog)
            defer { swiftpwa_widget_destroy(dialog) }
            guard resp == GTK_RESPONSE_OK.rawValue else { return [] }
            return takeFilenames(dialog)
        }

        // MARK: - Helpers

        @MainActor
        private func makeFileChooser(
            parent: WindowID?,
            action: swiftpwa_file_chooser_action,
            title: String?,
            folder: String?,
            filename: String?,
            allowMultiple: Bool
        ) -> UnsafeMutablePointer<GtkWidget> {
            let parentPtr = lookupParent(parent)
            let dialog: UnsafeMutablePointer<GtkWidget> = title.withOptionalCString { title in
                swiftpwa_file_chooser_dialog_new(parentPtr, action, title, allowMultiple ? 1 : 0)
            }
            if let folder { folder.withCString { swiftpwa_file_chooser_set_current_folder(dialog, $0) } }
            if let filename { filename.withCString { swiftpwa_file_chooser_set_current_name(dialog, $0) } }
            return dialog
        }

        @MainActor
        private func applyFilters(_ filters: [DialogFileFilter], to dialog: UnsafeMutablePointer<GtkWidget>) {
            for filter in filters {
                let patterns = filter.extensions.map { "*.\($0)" }
                // Build a NULL-terminated `const char *const *` buffer.
                // `strdup` returns `UnsafeMutablePointer<CChar>!`; wrap
                // explicitly in `UnsafePointer(...)` so Swift infers the
                // array's element type as the optional `const`-pointer
                // the shim signature expects (the implicit conversion
                // doesn't fire for pointer types inside an array
                // literal).
                let cStrings: [UnsafePointer<CChar>?] = patterns.map { UnsafePointer<CChar>(strdup($0)) } + [nil]
                cStrings.withUnsafeBufferPointer { buf in
                    filter.name.withCString { namePtr in
                        swiftpwa_file_chooser_add_filter(dialog, namePtr, buf.baseAddress)
                    }
                }
                for ptr in cStrings where ptr != nil { free(UnsafeMutablePointer(mutating: ptr)) }
            }
        }

        @MainActor
        private func takeFilenames(_ dialog: UnsafeMutablePointer<GtkWidget>) -> [String] {
            guard let raw = swiftpwa_file_chooser_get_filenames(dialog) else { return [] }
            var paths: [String] = []
            var i = 0
            while let cstr = raw[i] {
                paths.append(String(cString: cstr))
                i += 1
            }
            // Free both the strings and the array — `g_strfreev` does both.
            g_strfreev(raw)
            return paths
        }

        @MainActor
        private func takeFilename(_ dialog: UnsafeMutablePointer<GtkWidget>) -> String? {
            guard let cstr = swiftpwa_file_chooser_get_filename(dialog) else { return nil }
            let path = String(cString: cstr)
            g_free(UnsafeMutableRawPointer(cstr))
            return path
        }

        @MainActor
        private func lookupParent(_ id: WindowID?) -> UnsafeMutablePointer<GtkWindow>? {
            guard let id, let win = GTKAppContext.shared.windows[id] as? GTKWindow else { return nil }
            return win.nativeWindow
        }

        private func kindToShim(_ kind: DialogKind?) -> swiftpwa_dialog_kind {
            switch kind ?? .info {
            case .info: SWIFTPWA_DIALOG_INFO
            case .warning: SWIFTPWA_DIALOG_WARNING
            case .error: SWIFTPWA_DIALOG_ERROR
            }
        }
    }

    private extension String? {
        /// Run `body` with a C-string pointer (or `nil`), without
        /// requiring the caller to handle the optional themselves.
        func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
            switch self {
            case let .some(s): s.withCString { body($0) }
            case .none: body(nil)
            }
        }
    }
#endif
