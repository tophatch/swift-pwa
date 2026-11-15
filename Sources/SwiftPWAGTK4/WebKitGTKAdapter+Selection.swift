#if os(Linux)
    import CGtk4Shim
    import CWebKitGTK6Shim
    import Foundation
    import SwiftPWACore

    // `selection.setActions` on Linux: WebKitGTK builds the context menu and
    // emits `context-menu` first, with a hit-test result that says whether the
    // menu is for a text selection. The page's items are read from
    // ``WebViewSelection`` at that moment, so a change never has to reach a menu
    // that is already built.

    extension WebKitGTKAdapter {
        func connectSelectionMenu() {
            // Retained by the signal and released when the view goes — the
            // menu can fire for as long as the widget lives.
            let user = Unmanaged.passRetained(self).toOpaque()
            "context-menu".withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(viewWidget),
                    name,
                    unsafeBitCast(contextMenuTrampoline, to: GCallback.self),
                    user,
                    { data, _ in
                        guard let data else { return }
                        Unmanaged<WebKitGTKAdapter>.fromOpaque(data).release()
                    },
                    GConnectFlags(rawValue: 0)
                )
            }
        }

        func addSelectionActions(menu: gpointer, hitTestResult: gpointer) {
            guard let actions = selection?.actions, !actions.isEmpty else { return }
            let ids = actions.map { strdup($0.id) }
            let titles = actions.map { strdup($0.title) }
            defer {
                ids.forEach { free($0) }
                titles.forEach { free($0) }
            }
            let idPointers = ids.map { UnsafePointer($0) }
            let titlePointers = titles.map { UnsafePointer($0) }
            let user = Unmanaged.passUnretained(self).toOpaque()
            idPointers.withUnsafeBufferPointer { idBuffer in
                titlePointers.withUnsafeBufferPointer { titleBuffer in
                    _ = swiftpwa_context_menu_add_selection_actions(
                        menu, hitTestResult, idBuffer.baseAddress, titleBuffer.baseAddress,
                        Int32(actions.count), selectionChoiceTrampoline, user
                    )
                }
            }
        }
    }

    /// `context-menu` in the WebKitGTK 6.0 ABI, which dropped 4.1's event argument: view, menu, hit test.
    /// Returns `FALSE` so WebKit goes on to show the menu.
    let contextMenuTrampoline: @convention(c) (gpointer?, gpointer?, gpointer?, gpointer?)
        -> gboolean = { _, menu, hitTestResult, user in
            guard let menu, let hitTestResult, let user else { return 0 }
            let adapter = Unmanaged<WebKitGTKAdapter>.fromOpaque(user).takeUnretainedValue()
            adapter.addSelectionActions(menu: menu, hitTestResult: hitTestResult)
            return 0
        }

    let selectionChoiceTrampoline: @convention(c) (UnsafePointer<CChar>?, gpointer?) -> Void = { id, user in
        guard let id, let user else { return }
        let adapter = Unmanaged<WebKitGTKAdapter>.fromOpaque(user).takeUnretainedValue()
        adapter.selection?.actionChosen(String(cString: id))
    }
#endif
