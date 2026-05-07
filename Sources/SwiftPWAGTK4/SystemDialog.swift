#if os(Linux)
    import CGtk4Shim
    import Foundation
    import SwiftPWACore

    /// GTK4 `Dialog` backed by `GtkAlertDialog` (message / confirm) and
    /// `GtkFileDialog` (open / save / directory). Both are async — the
    /// GTK4 backend does not have a `gtk_dialog_run` analogue — so we
    /// bridge the `GAsyncReadyCallback` chain into Swift continuations
    /// the same way `swiftpwa_clipboard_read_text` does for the
    /// clipboard. Requires GTK 4.10 (when both APIs landed); the Linux
    /// setup doc calls this out.
    public final class SystemDialog: Dialog, @unchecked Sendable {
        public init() {}

        public func message(_ args: DialogMessageArgs, parent: WindowID?) async throws {
            _ = try await runAlert(
                title: args.title,
                message: args.message,
                kind: args.kind,
                buttons: ["OK"],
                defaultButton: 0,
                cancelButton: 0,
                parent: parent
            )
        }

        public func confirm(_ args: DialogConfirmArgs, parent: WindowID?) async throws -> Bool {
            // Buttons are ordered cancel, ok — index 0 is the cancel /
            // dismiss row, index 1 is the affirmative one. GTK lays
            // them out as the platform convention indicates.
            let chosen = try await runAlert(
                title: args.title,
                message: args.message,
                kind: args.kind,
                buttons: [args.cancelLabel ?? "Cancel", args.okLabel ?? "OK"],
                defaultButton: 1,
                cancelButton: 0,
                parent: parent
            )
            return chosen == 1
        }

        public func openFile(_ args: DialogOpenFileArgs, parent: WindowID?) async throws -> [String] {
            try await runFileDialog(
                action: args.multiple == true
                    ? SWIFTPWA_FILE_DIALOG_OPEN_MULTIPLE
                    : SWIFTPWA_FILE_DIALOG_OPEN,
                title: args.title,
                folder: args.defaultPath,
                name: nil,
                filters: args.filters ?? [],
                parent: parent
            )
        }

        public func saveFile(_ args: DialogSaveFileArgs, parent: WindowID?) async throws -> String? {
            try await runFileDialog(
                action: SWIFTPWA_FILE_DIALOG_SAVE,
                title: args.title,
                folder: args.defaultPath,
                name: args.defaultName,
                filters: args.filters ?? [],
                parent: parent
            ).first
        }

        public func openDirectory(_ args: DialogOpenDirectoryArgs, parent: WindowID?) async throws -> String? {
            try await runFileDialog(
                action: SWIFTPWA_FILE_DIALOG_SELECT_FOLDER,
                title: args.title,
                folder: args.defaultPath,
                name: nil,
                filters: [],
                parent: parent
            ).first
        }

        // MARK: - Alert bridge

        @MainActor
        private func runAlert(
            title: String?,
            message: String,
            kind: DialogKind?,
            buttons: [String],
            defaultButton: Int32,
            cancelButton: Int32,
            parent: WindowID?
        ) async throws -> Int32 {
            let parentPtr = lookupParent(parent)
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, any Error>) in
                let box = AlertContinuation(continuation: cont)
                let opaque = Unmanaged.passRetained(box).toOpaque()

                // Build a NULL-terminated `const char *const *` array
                // of button labels owned by this scope.
                var cButtons: [UnsafeMutablePointer<CChar>?] = buttons.map { strdup($0) } + [nil]
                cButtons.withUnsafeMutableBufferPointer { buf in
                    title.withOptionalCString { titlePtr in
                        message.withCString { msgPtr in
                            // The shim retains the buttons array internally
                            // by passing it to gtk_alert_dialog_set_buttons,
                            // which copies, so freeing after the call is safe.
                            buf.baseAddress?.withMemoryRebound(
                                to: UnsafePointer<CChar>?.self,
                                capacity: buf.count
                            ) { typed in
                                swiftpwa_alert_dialog_run(
                                    parentPtr,
                                    kindToShim(kind),
                                    titlePtr, msgPtr,
                                    typed,
                                    defaultButton,
                                    cancelButton,
                                    alertCallback,
                                    opaque
                                )
                            }
                        }
                    }
                }
                for ptr in cButtons where ptr != nil { free(ptr) }
            }
        }

        // MARK: - File dialog bridge

        @MainActor
        private func runFileDialog(
            action: swiftpwa_file_dialog_action,
            title: String?,
            folder: String?,
            name: String?,
            filters: [DialogFileFilter],
            parent: WindowID?
        ) async throws -> [String] {
            let parentPtr = lookupParent(parent)
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], any Error>) in
                let box = FileContinuation(continuation: cont)
                let opaque = Unmanaged.passRetained(box).toOpaque()

                // Build the filter store. The shim takes ownership of
                // the returned `GListStore*` (unrefs it after the
                // dialog is set up), so we don't free it here.
                let store = buildFilterStore(filters)

                title.withOptionalCString { titlePtr in
                    folder.withOptionalCString { folderPtr in
                        name.withOptionalCString { namePtr in
                            swiftpwa_file_dialog_run(
                                parentPtr,
                                action,
                                titlePtr,
                                folderPtr,
                                namePtr,
                                store,
                                fileDialogCallback,
                                opaque
                            )
                        }
                    }
                }
            }
        }

        @MainActor
        private func buildFilterStore(_ filters: [DialogFileFilter]) -> OpaquePointer? {
            guard !filters.isEmpty else { return nil }

            // For each filter: keep an array of strdup'd `*.ext` C
            // strings (NULL-terminated), plus a strdup'd name. We have
            // to pass a `const char *const *const *` to the shim — a
            // pointer to per-filter pattern arrays.
            var allocations: [[UnsafeMutablePointer<CChar>?]] = []
            var nameStorage: [UnsafeMutablePointer<CChar>?] = []
            var patternArrayStorage: [UnsafePointer<UnsafePointer<CChar>?>?] = []

            for filter in filters {
                let cName = strdup(filter.name)
                nameStorage.append(cName)
                var patterns: [UnsafeMutablePointer<CChar>?] = filter.extensions.map { strdup("*.\($0)") } + [nil]
                allocations.append(patterns)
                patterns.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress?.withMemoryRebound(
                        to: UnsafePointer<CChar>?.self, capacity: buf.count
                    ) { typed in
                        // Keep the typed pointer for the shim call.
                        patternArrayStorage.append(UnsafePointer(typed))
                    }
                }
            }

            let store = nameStorage.withUnsafeBufferPointer { nameBuf -> OpaquePointer? in
                nameBuf.baseAddress?.withMemoryRebound(
                    to: UnsafePointer<CChar>?.self, capacity: nameBuf.count
                ) { namePtrs in
                    patternArrayStorage.withUnsafeBufferPointer { patBuf -> OpaquePointer? in
                        guard let patBase = patBuf.baseAddress else { return nil }
                        return swiftpwa_file_dialog_build_filters(
                            Int32(filters.count),
                            namePtrs,
                            patBase
                        )
                    } ?? nil
                } ?? nil
            } ?? nil

            // Free the strdup'd C strings — the GtkFileFilter copies
            // them at `set_name` / `add_pattern` time.
            for ptr in nameStorage where ptr != nil { free(ptr) }
            for arr in allocations {
                for ptr in arr where ptr != nil { free(ptr) }
            }
            return store
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

    // MARK: - Continuation boxes

    /// Boxed continuation handed to the C shim as user_data. The
    /// trampoline reconstitutes it via `Unmanaged.fromOpaque` and
    /// resumes exactly once.
    private final class AlertContinuation: @unchecked Sendable {
        let continuation: CheckedContinuation<Int32, any Error>
        init(continuation: CheckedContinuation<Int32, any Error>) { self.continuation = continuation }
    }

    private final class FileContinuation: @unchecked Sendable {
        let continuation: CheckedContinuation<[String], any Error>
        init(continuation: CheckedContinuation<[String], any Error>) { self.continuation = continuation }
    }

    /// `@convention(c)` callback for `swiftpwa_alert_dialog_run`. Fires
    /// on the GTK main thread.
    private let alertCallback: @convention(c) (
        Int32, UnsafeMutablePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { button, errPtr, userData in
        guard let userData else { return }
        let raw = UInt(bitPattern: userData)
        let errMsg: String? = errPtr.map { String(cString: $0) }
        if let errPtr { g_free(UnsafeMutableRawPointer(errPtr)) }
        // Resume off the GTK thread on a Task — the C shim doesn't care.
        guard let opaque = UnsafeMutableRawPointer(bitPattern: raw) else { return }
        let box = Unmanaged<AlertContinuation>.fromOpaque(opaque).takeRetainedValue()
        if let errMsg {
            box.continuation.resume(throwing: BridgeError(code: BridgeError.handler, message: errMsg))
        } else {
            box.continuation.resume(returning: button)
        }
    }

    /// `@convention(c)` callback for `swiftpwa_file_dialog_run`. Fires
    /// on the GTK main thread.
    private let fileDialogCallback: @convention(c) (
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<CChar>?,
        UnsafeMutableRawPointer?
    ) -> Void = { paths, errPtr, userData in
        guard let userData else { return }
        let raw = UInt(bitPattern: userData)

        var collected: [String] = []
        if let paths {
            var i = 0
            while let cstr = paths[i] {
                collected.append(String(cString: cstr))
                i += 1
            }
            g_strfreev(paths)
        }
        let errMsg: String? = errPtr.map { String(cString: $0) }
        if let errPtr { g_free(UnsafeMutableRawPointer(errPtr)) }

        guard let opaque = UnsafeMutableRawPointer(bitPattern: raw) else { return }
        let box = Unmanaged<FileContinuation>.fromOpaque(opaque).takeRetainedValue()
        if let errMsg {
            box.continuation.resume(throwing: BridgeError(code: BridgeError.handler, message: errMsg))
        } else {
            box.continuation.resume(returning: collected)
        }
    }

    private extension String? {
        func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
            switch self {
            case let .some(s): s.withCString { body($0) }
            case .none: body(nil)
            }
        }
    }
#endif
