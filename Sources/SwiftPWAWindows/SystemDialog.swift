#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore
    import WinSDK

    /// Windows `Dialog` backed by the `swiftpwa_dialog_*` C++ shim:
    /// `MessageBoxW` / `TaskDialogIndirect` for message + confirm,
    /// `IFileOpenDialog` / `IFileSaveDialog` for file pickers. Pulled
    /// out into the shim because COM is awful from raw Swift — the
    /// `IShellItem*` / `CoTaskMemFree` lifetime juggling is ~80 lines
    /// of C++/COM that would balloon to several hundred in Swift.
    ///
    /// All calls hop to the UI thread via `MainThread.run` and block
    /// async-style on the modal — Win32's modal dispatch keeps the
    /// message loop pumping for the parent HWND, so the WebView2
    /// child stays painted while the dialog is up.
    public final class SystemDialog: Dialog, @unchecked Sendable {
        public init() {}

        public func message(_ args: DialogMessageArgs, parent: WindowID?) async throws {
            await MainThread.run { [self] in messageOnMain(args, parent: parent) }
        }

        public func confirm(_ args: DialogConfirmArgs, parent: WindowID?) async throws -> Bool {
            await MainThread.run { [self] in confirmOnMain(args, parent: parent) }
        }

        public func openFile(_ args: DialogOpenFileArgs, parent: WindowID?) async throws -> [String] {
            try await MainThread.run { [self] in try openFileOnMain(args, parent: parent) }
        }

        public func saveFile(_ args: DialogSaveFileArgs, parent: WindowID?) async throws -> String? {
            try await MainThread.run { [self] in try saveFileOnMain(args, parent: parent) }
        }

        public func openDirectory(_ args: DialogOpenDirectoryArgs, parent: WindowID?) async throws -> String? {
            try await MainThread.run { [self] in try openDirectoryOnMain(args, parent: parent) }
        }

        // MARK: - Main-thread bodies

        @MainActor
        private func messageOnMain(_ args: DialogMessageArgs, parent: WindowID?) {
            let owner = lookupParent(parent)
            args.message.withCString(encodedAs: UTF16.self) { msgW in
                (args.title ?? "").withCString(encodedAs: UTF16.self) { titleW in
                    swiftpwa_dialog_message(
                        UnsafeMutableRawPointer(owner),
                        kindToShim(args.kind),
                        args.title == nil ? nil : titleW,
                        msgW
                    )
                }
            }
        }

        @MainActor
        private func confirmOnMain(_ args: DialogConfirmArgs, parent: WindowID?) -> Bool {
            let owner = lookupParent(parent)
            return args.message.withCString(encodedAs: UTF16.self) { msgW in
                (args.title ?? "").withCString(encodedAs: UTF16.self) { titleW in
                    (args.okLabel ?? "").withCString(encodedAs: UTF16.self) { okW in
                        (args.cancelLabel ?? "").withCString(encodedAs: UTF16.self) { cancelW in
                            swiftpwa_dialog_confirm(
                                UnsafeMutableRawPointer(owner),
                                kindToShim(args.kind),
                                args.title == nil ? nil : titleW,
                                msgW,
                                args.okLabel == nil ? nil : okW,
                                args.cancelLabel == nil ? nil : cancelW
                            ) != 0
                        }
                    }
                }
            }
        }

        @MainActor
        private func openFileOnMain(_ args: DialogOpenFileArgs, parent: WindowID?) throws -> [String] {
            let owner = lookupParent(parent)
            return try withFilters(args.filters ?? []) { n, specs in
                try (args.title ?? "").withCString(encodedAs: UTF16.self) { titleW in
                    try (args.defaultPath ?? "").withCString(encodedAs: UTF16.self) { folderW in
                        var paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                        let rc = swiftpwa_dialog_open_file(
                            UnsafeMutableRawPointer(owner),
                            args.title == nil ? nil : titleW,
                            args.defaultPath == nil ? nil : folderW,
                            (args.multiple ?? false) ? 1 : 0,
                            n, specs,
                            &paths
                        )
                        if rc < 0 {
                            throw BridgeError(
                                code: BridgeError.handler,
                                message: "open-file dialog failed (HRESULT path)"
                            )
                        }
                        guard rc > 0, let paths else { return [] }
                        var collected: [String] = []
                        var i = 0
                        while let cstr = paths[i] {
                            collected.append(String(cString: cstr))
                            i += 1
                        }
                        swiftpwa_dialog_free_paths(paths)
                        return collected
                    }
                }
            }
        }

        @MainActor
        private func saveFileOnMain(_ args: DialogSaveFileArgs, parent: WindowID?) throws -> String? {
            let owner = lookupParent(parent)
            return try withFilters(args.filters ?? []) { n, specs in
                try (args.title ?? "").withCString(encodedAs: UTF16.self) { titleW in
                    try (args.defaultPath ?? "").withCString(encodedAs: UTF16.self) { folderW in
                        try (args.defaultName ?? "").withCString(encodedAs: UTF16.self) { nameW in
                            var path: UnsafeMutablePointer<CChar>?
                            let rc = swiftpwa_dialog_save_file(
                                UnsafeMutableRawPointer(owner),
                                args.title == nil ? nil : titleW,
                                args.defaultPath == nil ? nil : folderW,
                                args.defaultName == nil ? nil : nameW,
                                n, specs,
                                &path
                            )
                            if rc < 0 {
                                throw BridgeError(
                                    code: BridgeError.handler,
                                    message: "save-file dialog failed"
                                )
                            }
                            guard rc > 0, let path else { return nil }
                            let str = String(cString: path)
                            swiftpwa_dialog_free_path(path)
                            return str
                        }
                    }
                }
            }
        }

        @MainActor
        private func openDirectoryOnMain(_ args: DialogOpenDirectoryArgs, parent: WindowID?) throws -> String? {
            let owner = lookupParent(parent)
            return try (args.title ?? "").withCString(encodedAs: UTF16.self) { titleW in
                try (args.defaultPath ?? "").withCString(encodedAs: UTF16.self) { folderW in
                    var path: UnsafeMutablePointer<CChar>?
                    let rc = swiftpwa_dialog_open_directory(
                        UnsafeMutableRawPointer(owner),
                        args.title == nil ? nil : titleW,
                        args.defaultPath == nil ? nil : folderW,
                        &path
                    )
                    if rc < 0 {
                        throw BridgeError(
                            code: BridgeError.handler,
                            message: "open-directory dialog failed"
                        )
                    }
                    guard rc > 0, let path else { return nil }
                    let str = String(cString: path)
                    swiftpwa_dialog_free_path(path)
                    return str
                }
            }
        }

        // MARK: - Helpers

        @MainActor
        private func lookupParent(_ id: WindowID?) -> HWND? {
            guard let id, let win = WindowsAppContext.shared.windows[id] as? Win32Window else {
                return nil
            }
            return win.nativeHwnd
        }

        private func kindToShim(_ kind: DialogKind?) -> swiftpwa_dialog_kind {
            switch kind ?? .info {
            case .info: SWIFTPWA_DIALOG_INFO
            case .warning: SWIFTPWA_DIALOG_WARNING
            case .error: SWIFTPWA_DIALOG_ERROR
            }
        }

        /// Build the `swiftpwa_dialog_filter` array and call `body`
        /// with a stable pointer to it. Each filter holds two UTF-16
        /// C strings; we explicitly heap-allocate them via
        /// `UnsafeMutablePointer.allocate` so the pointers stay valid
        /// throughout `body` and are deallocated on exit. The shim
        /// does not retain past the call, so the deallocate is safe
        /// even on a thrown error.
        @MainActor
        private func withFilters<R>(
            _ filters: [DialogFileFilter],
            _ body: (Int32, UnsafePointer<swiftpwa_dialog_filter>?) throws -> R
        ) throws -> R {
            guard !filters.isEmpty else { return try body(0, nil) }

            var allocations: [UnsafeMutablePointer<UInt16>] = []
            defer { for p in allocations { p.deallocate() } }
            func dup(_ s: String) -> UnsafePointer<UInt16> {
                let utf16 = Array(s.utf16) + [0]
                let buf = UnsafeMutablePointer<UInt16>.allocate(capacity: utf16.count)
                for i in utf16.indices { (buf + i).initialize(to: utf16[i]) }
                allocations.append(buf)
                return UnsafePointer(buf)
            }

            let structs: [swiftpwa_dialog_filter] = filters.map { filter in
                let spec = filter.extensions.map { "*.\($0)" }.joined(separator: ";")
                return swiftpwa_dialog_filter(name: dup(filter.name), spec: dup(spec))
            }
            return try structs.withUnsafeBufferPointer { sb in
                try body(Int32(structs.count), sb.baseAddress)
            }
        }
    }
#endif
