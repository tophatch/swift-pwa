#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore
    import UniformTypeIdentifiers

    #if os(macOS)
        import AppKit

        /// macOS `Dialog` backed by `NSAlert` (message / confirm) and
        /// `NSOpenPanel` / `NSSavePanel` (file pickers).
        ///
        /// Dialogs are window-modal sheets when a key window is
        /// available, falling back to app-modal when nothing is keyed.
        /// We look up the parent via `NSApp.keyWindow` rather than the
        /// `originWindow` `WindowID` — the originating window is the
        /// keyed one by construction (the user just clicked in it), and
        /// going through `NSApp` avoids threading a `MacAppContext`
        /// reference into `SystemDialog` for what would be a no-op
        /// lookup.
        @MainActor
        public final class SystemDialog: Dialog {
            /// Holds each picked location's grant for the session and mints
            /// the bookmarks `dialog.openFile` / `openDirectory` return.
            /// Outside the App Sandbox this is only about durability across
            /// relaunches; inside it, it's what keeps the path readable.
            private let grants = FileGrants()

            public init() {}

            public func message(_ args: DialogMessageArgs, parent _: WindowID?) async throws {
                _ = await runAlert(
                    title: args.title,
                    message: args.message,
                    style: alertStyle(args.kind),
                    buttons: ["OK"]
                )
            }

            public func confirm(_ args: DialogConfirmArgs, parent _: WindowID?) async throws -> Bool {
                let chosen = await runAlert(
                    title: args.title,
                    message: args.message,
                    style: alertStyle(args.kind),
                    buttons: [args.okLabel ?? "OK", args.cancelLabel ?? "Cancel"]
                )
                return chosen == 0
            }

            public func openFile(_ args: DialogOpenFileArgs, parent _: WindowID?) async throws -> [String] {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = args.multiple ?? false
                if let title = args.title { panel.title = title }
                if let path = args.defaultPath {
                    panel.directoryURL = URL(fileURLWithPath: path)
                }
                if let filters = args.filters, !filters.isEmpty {
                    panel.allowedContentTypes = contentTypes(from: filters)
                }
                let resp = await runPanel(panel)
                guard resp == .OK else { return [] }
                return grants.retain(panel.urls)
            }

            public func saveFile(_ args: DialogSaveFileArgs, parent _: WindowID?) async throws -> String? {
                let panel = NSSavePanel()
                if let title = args.title { panel.title = title }
                if let name = args.defaultName { panel.nameFieldStringValue = name }
                if let path = args.defaultPath {
                    panel.directoryURL = URL(fileURLWithPath: path)
                }
                if let filters = args.filters, !filters.isEmpty {
                    panel.allowedContentTypes = contentTypes(from: filters)
                }
                let resp = await runPanel(panel)
                guard resp == .OK, let url = panel.url else { return nil }
                return url.path
            }

            public func openDirectory(_ args: DialogOpenDirectoryArgs, parent _: WindowID?) async throws -> [String] {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = args.multiple ?? false
                if let title = args.title { panel.title = title }
                if let path = args.defaultPath {
                    panel.directoryURL = URL(fileURLWithPath: path)
                }
                let resp = await runPanel(panel)
                guard resp == .OK else { return [] }
                return grants.retain(panel.urls)
            }

            public func makeBookmark(forPath path: String) async throws -> String? {
                grants.makeBookmark(forPath: path)
            }

            public func resolveBookmark(_ bookmark: String) async throws -> DialogResolveBookmarkResult {
                try grants.resolve(bookmark)
            }

            public func exportFile(_ args: DialogExportFileArgs, parent _: WindowID?) async throws -> String? {
                // Resolve the bytes up front so a bad `path`/`dataBase64`
                // fails before we bother the user with a save panel.
                let data = try args.resolveData()
                let panel = NSSavePanel()
                if let title = args.title { panel.title = title }
                panel.nameFieldStringValue = args.suggestedName
                if let filters = args.filters, !filters.isEmpty {
                    panel.allowedContentTypes = contentTypes(from: filters)
                }
                let resp = await runPanel(panel)
                guard resp == .OK, let url = panel.url else { return nil }
                try data.write(to: url)
                return url.path
            }

            // MARK: - NSAlert / panel sheets

            /// Run an alert and return the index of the chosen button
            /// (0 = first/primary, 1 = second, ...). Sheet-modal when a
            /// key window is available; app-modal otherwise.
            private func runAlert(
                title: String?,
                message: String,
                style: NSAlert.Style,
                buttons: [String]
            ) async -> Int {
                let alert = NSAlert()
                alert.alertStyle = style
                alert.messageText = title ?? defaultTitle(for: style)
                alert.informativeText = message
                for label in buttons { alert.addButton(withTitle: label) }
                let resp: NSApplication.ModalResponse = if let parent = NSApp.keyWindow {
                    await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
                        alert.beginSheetModal(for: parent) { cont.resume(returning: $0) }
                    }
                } else {
                    alert.runModal()
                }
                return buttonIndex(from: resp)
            }

            /// Run a save / open panel and return the OK / Cancel
            /// response. The caller reads selected URLs off the panel
            /// after we return — both `NSSavePanel.url` and
            /// `NSOpenPanel.urls` stay valid until the panel deinits,
            /// which happens after the caller drops its reference.
            private func runPanel(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
                if let parent = NSApp.keyWindow {
                    await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
                        panel.beginSheetModal(for: parent) { cont.resume(returning: $0) }
                    }
                } else {
                    panel.runModal()
                }
            }
        }

        private func alertStyle(_ kind: DialogKind?) -> NSAlert.Style {
            switch kind ?? .info {
            case .info: .informational
            case .warning: .warning
            case .error: .critical
            }
        }

        private func defaultTitle(for style: NSAlert.Style) -> String {
            switch style {
            case .warning: "Warning"
            case .critical: "Error"
            default: ""
            }
        }

        /// Map `NSAlert`'s response back to the index we registered the
        /// button at. AppKit returns `firstButtonReturn` (1000),
        /// `secondButtonReturn` (1001), ...
        private func buttonIndex(from resp: NSApplication.ModalResponse) -> Int {
            Int(resp.rawValue) - Int(NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }

    #else // os(iOS)

        import UIKit

        /// iOS `Dialog`. `message` / `confirm` map to
        /// `UIAlertController`; `openFile` / `openDirectory` use
        /// `UIDocumentPickerViewController`. `saveFile` returns `nil`
        /// with a one-shot stderr warning — iOS has no system save
        /// panel, and apps export through
        /// `UIDocumentPickerViewController(forExporting:)` (which takes
        /// a *written* file URL) or a `UIActivityViewController` share
        /// sheet, neither of which fits the cross-platform shape.
        @MainActor
        public final class SystemDialog: Dialog {
            private var savedFileWarned = false

            /// Holds the security scope on every location the user picks.
            /// Without this the paths `openFile` / `openDirectory` return
            /// are unreadable the moment the picker deallocates — anything
            /// outside the app container (iCloud Drive, another app's
            /// documents) is exactly what the scope guards.
            private let grants = FileGrants()

            public init() {}

            public func message(_ args: DialogMessageArgs, parent _: WindowID?) async throws {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    presentAlert(
                        title: args.title ?? "",
                        message: args.message,
                        actions: [
                            UIAlertAction(title: "OK", style: .default) { _ in cont.resume() }
                        ]
                    )
                }
            }

            public func confirm(_ args: DialogConfirmArgs, parent _: WindowID?) async throws -> Bool {
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    presentAlert(
                        title: args.title ?? "",
                        message: args.message,
                        actions: [
                            UIAlertAction(title: args.okLabel ?? "OK", style: .default) { _ in
                                cont.resume(returning: true)
                            },
                            UIAlertAction(title: args.cancelLabel ?? "Cancel", style: .cancel) { _ in
                                cont.resume(returning: false)
                            }
                        ]
                    )
                }
            }

            public func openFile(_ args: DialogOpenFileArgs, parent _: WindowID?) async throws -> [String] {
                let types = contentTypes(from: args.filters ?? []).nilIfEmpty ?? [.item]
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
                picker.allowsMultipleSelection = args.multiple ?? false
                return await presentPicker(picker)
            }

            public func saveFile(_: DialogSaveFileArgs, parent _: WindowID?) async throws -> String? {
                if !savedFileWarned {
                    savedFileWarned = true
                    FileHandle.standardError.writeQuietly(Data(
                        """
                        swift-pwa: dialog.saveFile is a no-op on iOS — there is no "pick a location, \
                        get a writable path" panel. Use dialog.exportFile instead (content-first; \
                        presents the system export picker).
                        \n
                        """.utf8
                    ))
                }
                return nil
            }

            public func exportFile(_ args: DialogExportFileArgs, parent _: WindowID?) async throws -> String? {
                // iOS export is content-first: the picker copies an
                // already-written file to the user's chosen location.
                // Materialize the bytes to a temp file (or reuse the
                // source path), present forExporting:, return the
                // destination. `resolveData`/`materializeTempFile` throw
                // on bad input before we present anything.
                let source = try args.materializeTempFile()
                // materializeTempFile only creates a temp when the content
                // was inline (`dataBase64`); when a `path` was given it
                // returns that URL untouched, so don't delete it.
                let isTemp = args.path == nil
                defer {
                    if isTemp {
                        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
                    }
                }
                let picker = UIDocumentPickerViewController(forExporting: [source])
                return await presentPicker(picker).first
            }

            public func openDirectory(_ args: DialogOpenDirectoryArgs, parent _: WindowID?) async throws -> [String] {
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
                picker.allowsMultipleSelection = args.multiple ?? false
                return await presentPicker(picker)
            }

            public func makeBookmark(forPath path: String) async throws -> String? {
                grants.makeBookmark(forPath: path)
            }

            public func resolveBookmark(_ bookmark: String) async throws -> DialogResolveBookmarkResult {
                try grants.resolve(bookmark)
            }

            // MARK: - Helpers

            private func presentAlert(title: String, message: String, actions: [UIAlertAction]) {
                guard let presenter = topViewController() else { return }
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                for a in actions { alert.addAction(a) }
                presenter.present(alert, animated: true)
            }

            /// Present a picker and return the picked paths, with each
            /// location's security scope activated and retained first — the
            /// URL is the only thing carrying that grant, so it has to
            /// happen here, before the URLs are flattened to strings.
            private func presentPicker(_ picker: UIDocumentPickerViewController) async -> [String] {
                await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
                    let delegate = DocumentPickerDelegate { [grants] urls in
                        cont.resume(returning: grants.retain(urls))
                    }
                    picker.delegate = delegate
                    // Retain the delegate for the picker's lifetime via
                    // an associated reference — UIDocumentPicker holds
                    // its delegate as a weak reference, so the box
                    // would otherwise deallocate before the pick
                    // completes.
                    objc_setAssociatedObject(
                        picker,
                        DocumentPickerDelegate.assocKey,
                        delegate,
                        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    )
                    if let presenter = topViewController() {
                        presenter.present(picker, animated: true)
                    } else {
                        cont.resume(returning: [])
                    }
                }
            }

            private func topViewController() -> UIViewController? {
                let scene = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive }
                    ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                guard var top = scene?.keyWindow?.rootViewController else { return nil }
                while let presented = top.presentedViewController { top = presented }
                return top
            }
        }

        /// Holds the continuation-fulfilling closure across
        /// `UIDocumentPickerDelegate` callbacks. Both `didPickDocumentsAt`
        /// and `wasCancelled` need to resume the continuation exactly
        /// once; we guard with `done` to keep the contract.
        @MainActor
        private final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
            /// objc_setAssociatedObject requires a stable per-key
            /// address. A heap allocation gives us one without falling
            /// foul of strict-concurrency rules around `&` on a static
            /// var; the leak is intentional (one byte, once per process).
            static let assocKey: UnsafeRawPointer = .init(malloc(1)!)

            private let onResult: ([URL]) -> Void
            private var done = false

            /// Hands back the picked **URLs**, not paths: each one carries
            /// the security scope for a location outside the app container,
            /// and the caller has to activate it before that URL is dropped.
            init(_ onResult: @escaping ([URL]) -> Void) {
                self.onResult = onResult
            }

            func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                fire(urls)
            }

            func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
                fire([])
            }

            private func fire(_ urls: [URL]) {
                guard !done else { return }
                done = true
                onResult(urls)
            }
        }

        private extension [UTType] {
            var nilIfEmpty: Self? {
                isEmpty ? nil : self
            }
        }

    #endif

    // MARK: - Shared filter mapping

    /// Map `DialogFileFilter` extensions to `UTType`. Unknown extensions
    /// (no registered UTI on the system) are silently dropped — better
    /// to fall back to "everything" than refuse to open the dialog.
    @MainActor
    func contentTypes(from filters: [DialogFileFilter]) -> [UTType] {
        var out: [UTType] = []
        for f in filters {
            for ext in f.extensions {
                if let t = UTType(filenameExtension: ext) {
                    out.append(t)
                }
            }
        }
        return out
    }
#endif
