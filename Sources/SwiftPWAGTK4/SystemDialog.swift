#if os(Linux)
    import CGtk4Shim
    import Foundation
    import SwiftPWACore

    /// GTK4 `Dialog` backed by `GtkAlertDialog` (message / confirm) and
    /// `GtkFileDialog` (open / save / directory). Both are async — the
    /// GTK4 backend has no `gtk_dialog_run` analogue — so we bridge the
    /// `GAsyncReadyCallback` chain into Swift continuations the same
    /// way `swiftpwa_clipboard_read_text` does for the clipboard.
    /// Requires GTK 4.10+ (when both APIs landed); the Linux setup
    /// doc calls this out.
    ///
    /// **Threading.** The C shim has to be invoked on the GTK main
    /// thread, and routing through `MainThread.run` (which uses the
    /// `g_idle_add`-based hook) is the only way to do that under
    /// `gtk_main()`. A `@MainActor` hop would route through Swift's
    /// MainActor executor — libdispatch's main queue — which
    /// `gtk_main()` doesn't drain, so the call would never run and
    /// the bridge pump would stall behind it (taking other plugins
    /// with it). This is the same constraint the GTK3 dialog
    /// implementation hits, just more visible here because GTK4's
    /// dialogs are async.
    public final class SystemDialog: Dialog, @unchecked Sendable {
        public init() {}

        public func message(_ args: DialogMessageArgs, parent: WindowID?) async throws {
            _ = try await runAlertAsync(
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
            // Buttons ordered cancel, ok — index 0 is the cancel /
            // dismiss row, index 1 the affirmative one. GTK lays them
            // out per platform convention.
            let chosen = try await runAlertAsync(
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
            try await runFileDialogAsync(
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
            try await runFileDialogAsync(
                action: SWIFTPWA_FILE_DIALOG_SAVE,
                title: args.title,
                folder: args.defaultPath,
                name: args.defaultName,
                filters: args.filters ?? [],
                parent: parent
            ).first
        }

        public func openDirectory(_ args: DialogOpenDirectoryArgs, parent: WindowID?) async throws -> [String] {
            try await runFileDialogAsync(
                action: args.multiple == true
                    ? SWIFTPWA_FILE_DIALOG_SELECT_FOLDER_MULTIPLE
                    : SWIFTPWA_FILE_DIALOG_SELECT_FOLDER,
                title: args.title,
                folder: args.defaultPath,
                name: nil,
                filters: [],
                parent: parent
            )
        }

        public func exportFile(_ args: DialogExportFileArgs, parent: WindowID?) async throws -> String? {
            // Resolve bytes first so bad input fails before the chooser.
            let data = try args.resolveData()
            guard let dest = try await runFileDialogAsync(
                action: SWIFTPWA_FILE_DIALOG_SAVE,
                title: args.title,
                folder: nil,
                name: args.suggestedName,
                filters: args.filters ?? [],
                parent: parent
            ).first else { return nil }
            try data.write(to: URL(fileURLWithPath: dest))
            return dest
        }

        // MARK: - Alert bridge

        /// Suspend until the alert dialog's C callback resumes us.
        /// Hops to the GTK main thread via `MainThread.run` to fire
        /// the (async) C shim; the shim's `Completed` callback
        /// resumes the continuation when the user dismisses.
        private func runAlertAsync(
            title: String?,
            message: String,
            kind: DialogKind?,
            buttons: [String],
            defaultButton: Int32,
            cancelButton: Int32,
            parent: WindowID?
        ) async throws -> Int32 {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, any Error>) in
                let box = AlertContinuation(continuation: cont)
                // Wrap the raw pointer in a Sendable container — Swift
                // on Linux's strict-concurrency mode flags the implicit
                // `UnsafeMutableRawPointer` capture across the Task
                // boundary even though the standard library declares it
                // Sendable. The wrapper is `@unchecked Sendable`
                // because the pointer is genuinely safe to share here:
                // it's a one-shot hand-off to the C shim, which uses it
                // synchronously inside the same MainThread.run hop.
                let opaqueRef = OpaquePointerRef(Unmanaged.passRetained(box).toOpaque())

                // Detached hop: the continuation body must be
                // synchronous, so we spawn a Task that awaits
                // `MainThread.run` for us. The Task itself completes
                // as soon as the C shim returns (which is fast — the
                // shim is async). The user-facing continuation is
                // resumed later, by `alertCallback`, when the dialog
                // is dismissed.
                Task { [self, opaqueRef] in
                    await MainThread.run { [self] in
                        fireAlertOnMain(
                            parent: parent,
                            kind: kind,
                            title: title,
                            message: message,
                            buttons: buttons,
                            defaultButton: defaultButton,
                            cancelButton: cancelButton,
                            opaque: opaqueRef.value
                        )
                    }
                }
            }
        }

        @MainActor
        private func fireAlertOnMain(
            parent: WindowID?,
            kind: DialogKind?,
            title: String?,
            message: String,
            buttons: [String],
            defaultButton: Int32,
            cancelButton: Int32,
            opaque: UnsafeMutableRawPointer
        ) {
            let parentPtr = lookupParent(parent)
            var cButtons: [UnsafeMutablePointer<CChar>?] = buttons.map { strdup($0) } + [nil]
            cButtons.withUnsafeMutableBufferPointer { buf in
                title.withOptionalCString { titlePtr in
                    message.withCString { msgPtr in
                        // `gtk_alert_dialog_set_buttons` copies the
                        // labels array internally, so freeing the
                        // strdup'd entries after the call is safe.
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

        // MARK: - File dialog bridge

        private func runFileDialogAsync(
            action: swiftpwa_file_dialog_action,
            title: String?,
            folder: String?,
            name: String?,
            filters: [DialogFileFilter],
            parent: WindowID?
        ) async throws -> [String] {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], any Error>) in
                let box = FileContinuation(continuation: cont)
                let opaqueRef = OpaquePointerRef(Unmanaged.passRetained(box).toOpaque())

                Task { [self, opaqueRef] in
                    await MainThread.run { [self] in
                        fireFileDialogOnMain(
                            action: action,
                            parent: parent,
                            title: title,
                            folder: folder,
                            name: name,
                            filters: filters,
                            opaque: opaqueRef.value
                        )
                    }
                }
            }
        }

        @MainActor
        private func fireFileDialogOnMain(
            action: swiftpwa_file_dialog_action,
            parent: WindowID?,
            title: String?,
            folder: String?,
            name: String?,
            filters: [DialogFileFilter],
            opaque: UnsafeMutableRawPointer
        ) {
            let parentPtr = lookupParent(parent)

            // The shim takes ownership of the returned `GListStore*`
            // (unrefs after binding to the dialog), so we don't free
            // it here.
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

        /// Build the GListStore<GtkFileFilter> the C shim uses to
        /// install the file-type filter chooser on the dialog.
        ///
        /// Implementation note: every C string we hand to the shim
        /// (filter name, filter pattern) is heap-allocated via
        /// `strdup`, and every per-filter NULL-terminated pattern
        /// array is heap-allocated via `UnsafeMutablePointer.allocate`.
        /// Both go through `free` / `deallocate` at the end of the
        /// function. We can't use `Array.withUnsafeBufferPointer`
        /// for the per-filter pattern arrays because we need their
        /// addresses to outlive any single closure scope — they're
        /// referenced by the outer "array of pattern-array pointers"
        /// passed to the shim.
        @MainActor
        private func buildFilterStore(_ filters: [DialogFileFilter]) -> OpaquePointer? {
            guard !filters.isEmpty else { return nil }

            var stringAllocations: [UnsafeMutablePointer<CChar>] = []
            var arrayAllocations: [UnsafeMutablePointer<UnsafePointer<CChar>?>] = []
            defer {
                for ptr in stringAllocations { free(ptr) }
                for ptr in arrayAllocations { ptr.deallocate() }
            }

            func dup(_ s: String) -> UnsafePointer<CChar> {
                let p = strdup(s)!
                stringAllocations.append(p)
                return UnsafePointer(p)
            }

            var nameArray: [UnsafePointer<CChar>?] = []
            var patternArrayPtrs: [UnsafePointer<UnsafePointer<CChar>?>?] = []

            for filter in filters {
                nameArray.append(dup(filter.name))

                let n = filter.extensions.count
                let arr = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: n + 1)
                arrayAllocations.append(arr)
                for (i, ext) in filter.extensions.enumerated() {
                    (arr + i).initialize(to: dup("*.\(ext)"))
                }
                (arr + n).initialize(to: nil)
                patternArrayPtrs.append(UnsafePointer(arr))
            }

            return nameArray.withUnsafeBufferPointer { nameBuf -> OpaquePointer? in
                patternArrayPtrs.withUnsafeBufferPointer { patBuf -> OpaquePointer? in
                    swiftpwa_file_dialog_build_filters(
                        Int32(filters.count),
                        nameBuf.baseAddress,
                        patBuf.baseAddress
                    )
                }
            }
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

    /// `@unchecked Sendable` wrapper around an `UnsafeMutableRawPointer`.
    /// Used to hand the heap-boxed continuation pointer across the
    /// Task / MainThread.run hop without tripping Swift on Linux's
    /// strict-concurrency diagnostic — the standard library declares
    /// `UnsafeMutableRawPointer` Sendable, but implicit captures
    /// across actor-isolation boundaries are still flagged on some
    /// toolchain versions. Safe in this specific use because the
    /// pointer is a one-shot hand-off to the C shim, which uses it
    /// synchronously inside the MainThread.run body.
    private struct OpaquePointerRef: @unchecked Sendable {
        let value: UnsafeMutableRawPointer
        init(_ value: UnsafeMutableRawPointer) { self.value = value }
    }

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

    /// `@convention(c)` callback for `swiftpwa_alert_dialog_run`.
    /// Fires on the GTK main thread once the dialog dismisses.
    /// Resumes the captured continuation; the awaiting Task wakes
    /// up on the cooperative pool.
    private let alertCallback: @convention(c) (
        Int32, UnsafeMutablePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { button, errPtr, userData in
        guard let userData else { return }
        let raw = UInt(bitPattern: userData)
        let errMsg: String? = errPtr.map { String(cString: $0) }
        if let errPtr { g_free(UnsafeMutableRawPointer(errPtr)) }
        guard let opaque = UnsafeMutableRawPointer(bitPattern: raw) else { return }
        let box = Unmanaged<AlertContinuation>.fromOpaque(opaque).takeRetainedValue()
        if let errMsg {
            box.continuation.resume(throwing: BridgeError(code: BridgeError.handler, message: errMsg))
        } else {
            box.continuation.resume(returning: button)
        }
    }

    /// `@convention(c)` callback for `swiftpwa_file_dialog_run`.
    /// Fires on the GTK main thread.
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
