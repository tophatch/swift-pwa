#if os(macOS)
    import AppKit
    import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing

    /// Guards the menu bar's *shape*. It can't prove a keystroke edits a text
    /// field — that needs a running app with a key window, and lives in
    /// `docs/manual-test-cases.md` — but it does catch the failure that made
    /// the Edit menu necessary in the first place: the items quietly not being
    /// there. For two releases every swift-pwa app on macOS beeped at ⌘C, ⌘V
    /// and ⌘A because `makeMainMenu` built the app submenu and stopped, and
    /// nothing anywhere would have noticed it happening again.
    @Suite("MainMenu")
    @MainActor
    struct MainMenuTests {
        private func menu(titled title: String, in main: NSMenu) -> NSMenu? {
            main.items.compactMap(\.submenu).first { $0.title == title }
        }

        /// Every editing shortcut, by the two things that have to be right for
        /// it to reach the responder chain: the selector and the key
        /// equivalent. A wrong selector is silent — the item shows, greys out
        /// and never fires.
        @Test("the Edit menu carries the editing actions with their shortcuts")
        func editMenu() throws {
            let main = MacAppRuntime.makeMainMenu(for: NSApplication.shared)
            let edit = try #require(menu(titled: "Edit", in: main))

            let expected: [(title: String, selector: String, key: String, mask: NSEvent.ModifierFlags)] = [
                ("Undo", "undo:", "z", [.command]),
                ("Redo", "redo:", "z", [.command, .shift]),
                ("Cut", "cut:", "x", [.command]),
                ("Copy", "copy:", "c", [.command]),
                ("Paste", "paste:", "v", [.command]),
                ("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift]),
                ("Select All", "selectAll:", "a", [.command])
            ]
            for want in expected {
                let item = try #require(
                    edit.items.first { $0.title == want.title },
                    "the Edit menu has no \(want.title) item"
                )
                #expect(item.action.map(NSStringFromSelector) == want.selector)
                #expect(item.keyEquivalent == want.key)
                #expect(item.keyEquivalentModifierMask == want.mask)
                // A `nil` target is what sends these down the responder chain
                // to whatever is focused; giving one would aim them at an
                // object that can't edit the page.
                #expect(item.target == nil)
            }
        }

        @Test("the Window menu carries Minimize, Zoom and Close")
        func windowMenu() throws {
            let app = NSApplication.shared
            let main = MacAppRuntime.makeMainMenu(for: app)
            let window = try #require(menu(titled: "Window", in: main))

            let expected = [
                ("Minimize", "performMiniaturize:", "m"),
                ("Zoom", "performZoom:", ""),
                ("Close", "performClose:", "w")
            ]
            for (title, selector, key) in expected {
                let item = try #require(window.items.first { $0.title == title })
                #expect(item.action.map(NSStringFromSelector) == selector)
                #expect(item.keyEquivalent == key)
            }
            // Handing AppKit the menu is what keeps the window list and its
            // checkmark current without the runtime tracking either.
            #expect(app.windowsMenu === window)
        }

        @Test("the app menu still has its own items, and now a Services menu")
        func appMenu() throws {
            let app = NSApplication.shared
            let main = MacAppRuntime.makeMainMenu(for: app)
            let appMenu = try #require(main.items.first?.submenu)
            let titles = appMenu.items.map(\.title)
            #expect(titles.contains { $0.hasPrefix("About ") })
            #expect(titles.contains { $0.hasPrefix("Quit ") })
            #expect(titles.contains("Services"))
            #expect(app.servicesMenu === appMenu.items.first { $0.title == "Services" }?.submenu)
        }

        /// The submenus have to hang off the *main* menu's items, not float
        /// unattached — a menu with the right items and no parent is invisible
        /// and dispatches nothing.
        @Test("the submenus are attached in menu-bar order")
        func order() {
            let main = MacAppRuntime.makeMainMenu(for: NSApplication.shared)
            #expect(main.items.compactMap(\.submenu?.title).suffix(2) == ["Edit", "Window"])
        }
    }
#endif
