#if canImport(WebKit) && os(macOS)
    import AppKit
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing
    import WebKit

    /// `selection.setActions` on macOS (#352): the page's items go on the
    /// right-click menu WebKit builds for a selection, and only that one.
    ///
    /// The menus here stand in for WebKit's, built with the identifiers WebKit
    /// stamps on its items (measured on macOS 27: a selection's menu carries
    /// `WKMenuItemIdentifierCopy`, a link's `…CopyLink`, an image's
    /// `…CopyImage`). Opening a real context menu runs a modal tracking loop, so
    /// the on-screen check lives in the manual verification, not here.
    @Suite("selection menu — macOS context menu")
    @MainActor
    struct SelectionMenuTests {
        private func webView(actions: [SelectionAction]) async throws -> SelectionWebView {
            let view = SelectionWebView(frame: .zero, configuration: WKWebViewConfiguration())
            let selection = WebViewSelection()
            try await selection.setActions(actions)
            view.selection = selection
            return view
        }

        private func menu(_ identifiers: [String]) -> NSMenu {
            let menu = NSMenu()
            for identifier in identifiers {
                let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(identifier)
                menu.addItem(item)
            }
            return menu
        }

        private let highlightAndNote = [
            SelectionAction(id: "highlight", title: "Highlight"),
            SelectionAction(id: "note", title: "Note")
        ]

        @Test("a selection's menu gets the page's items first, then a separator")
        func selectionMenu() async throws {
            let view = try await webView(actions: highlightAndNote)
            let menu = menu(["WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierCopy"])
            view.addSelectionActions(to: menu)
            #expect(menu.items.map(\.title) == [
                "Highlight", "Note", "", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierCopy"
            ])
            #expect(menu.items[2].isSeparatorItem)
        }

        @Test("a link's or an image's menu is left alone")
        func otherMenus() async throws {
            let view = try await webView(actions: highlightAndNote)
            for identifiers in [
                ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierCopyLink"],
                ["WKMenuItemIdentifierCopyImage"],
                ["WKMenuItemIdentifierReload"]
            ] {
                let menu = menu(identifiers)
                view.addSelectionActions(to: menu)
                #expect(menu.items.count == identifiers.count, "added to \(identifiers)")
            }
        }

        @Test("no actions, no change")
        func noActions() async throws {
            let view = try await webView(actions: [])
            let menu = menu(["WKMenuItemIdentifierCopy"])
            view.addSelectionActions(to: menu)
            #expect(menu.items.count == 1)
        }

        @Test("choosing an item reaches the page's stream with that item's id")
        func choosing() async throws {
            let view = try await webView(actions: highlightAndNote)
            let selection = try #require(view.selection)
            let events = selection.events()
            let menu = menu(["WKMenuItemIdentifierCopy"])
            view.addSelectionActions(to: menu)
            menu.performActionForItem(at: 1)
            for await event in events {
                #expect(event == .action(id: "note"))
                break
            }
        }
    }
#endif
