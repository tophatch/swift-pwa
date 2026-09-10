#if os(macOS)
    import AppKit
    import Foundation
    import SwiftPWACore
    import WebKit

    /// macOS-side runtime. Owns the singleton `MacAppContext` and drives
    /// `NSApplication.run()`. The `configure` closure runs synchronously
    /// before `NSApp.run()` enters the AppKit event loop — windows it
    /// creates are visible from the moment the loop starts.
    @MainActor
    public final class MacAppRuntime {
        public static let shared = MacAppRuntime()
        public let context = MacAppContext()
        private var didStartConfigure = false
        /// Retained for the lifetime of the process — releasing the
        /// monitor handle removes the hook.
        private var devToolsMonitor: Any?
        /// Retained for the lifetime of the process — `NSApplication.delegate`
        /// is a weak reference, so without a strong hold here the app-level
        /// handlers would deallocate immediately and never fire.
        private var appDelegate: MacAppDelegate?

        private init() {}

        public func bootstrap(
            configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) {
            guard !didStartConfigure else { return }
            didStartConfigure = true
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.mainMenu = Self.makeMainMenu(for: app)
            installDevToolsAccelerator()

            // Deliver OS "Open With" / document-open events to JS. Set before
            // `NSApp.run()` so the launch open-file Apple event (queued during
            // a cold launch) is handled once the loop starts; the payload is
            // emitted retained, so the WebView receives it whenever it
            // subscribes. See `MacAppDelegate`.
            let appDelegate = MacAppDelegate(context: context)
            self.appDelegate = appDelegate
            app.delegate = appDelegate

            // Route MainThread.run through DispatchQueue.main so the
            // bridge runtime can hop to the UI thread uniformly across
            // platforms. (The GTK side does the same with g_idle_add.)
            MainThread.setHook { body in
                if Thread.isMainThread {
                    body()
                } else {
                    DispatchQueue.main.async { body() }
                }
            }

            do {
                try configure(context)
            } catch {
                FileHandle.standardError.writeQuietly(
                    Data("swift-pwa: configure threw: \(error)\n".utf8)
                )
            }
            // Opt-in dev/test control socket. After `configure` so the app's
            // first window already exists when a driver connects; a no-op
            // unless SWIFT_PWA_DRIVE names a port (and absent entirely from
            // release builds).
            // The agent surface's indicator: a runtime-owned status item, so a user
            // can see access is open (and close it) without the app's cooperation.
            AgentIndicator.installTray { SystemTray() }
            AppDriver.startIfRequested(context, backend: "macos")

            NSApp.activate(ignoringOtherApps: true)
        }

        /// Cmd+Opt+J — open WKWebView's web inspector for the focused
        /// page. Mirrors Chrome / Edge / Safari's "open JS console"
        /// shortcut, and matches `Ctrl+Alt+J` on the GTK and Windows
        /// backends. We use a global `NSEvent` monitor rather than a
        /// menu item so the surface stays minimal — apps that want a
        /// visible "Develop" menu can add their own.
        ///
        /// Walks the key window's responder chain to find the
        /// foreground WKWebView, then forwards `_showInspector:` —
        /// the same SPI `WKWebViewAdapter.openDevTools()` calls.
        private func installDevToolsAccelerator() {
            devToolsMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard mods == [.command, .option],
                      event.charactersIgnoringModifiers == "j"
                else { return event }
                var responder: NSResponder? = NSApp.keyWindow?.firstResponder
                while let r = responder {
                    if let wkv = r as? WKWebView {
                        let sel = NSSelectorFromString("_showInspector:")
                        if wkv.responds(to: sel) {
                            wkv.perform(sel, with: nil)
                            return nil // consume
                        }
                        break
                    }
                    responder = r.nextResponder
                }
                return event
            }
        }

        public func runForever() -> Never {
            NSApplication.shared.run()
            // NSApp.run() returns after orderly shutdown. Use the
            // exit code stashed by `MacAppContext.quit`, defaulting
            // to 0 on a clean termination.
            exit(context.pendingExitCode ?? 0)
        }

        /// The application menu bar: app, Edit and Window submenus, so ⌘Q /
        /// ⌘H / About, the editing shortcuts and ⌘M / ⌘W all work out of the
        /// box. Without an `NSApp.mainMenu`, AppKit installs nothing — the app
        /// silently has no menu bar and ⌘Q is a no-op.
        ///
        /// **The Edit menu is why a text field works.** On macOS the editing
        /// shortcuts are not a property of the text field: they are main-menu
        /// *key equivalents*, dispatched down the responder chain as
        /// `selectAll:` / `copy:` / `paste:` / `cut:` / `undo:`. An equivalent
        /// matching no menu item is never dispatched at all — it falls off the
        /// end of the chain, and the beep is the sound of that. `NSTextView`
        /// inside `WKWebView` implements every one of those actions and is
        /// sitting there ready to receive them; until this menu existed,
        /// nothing ever sent them, so **no swift-pwa app could copy, paste or
        /// select-all with the keyboard.** Reported by an adopter.
        ///
        /// Every editing item has a `nil` target on purpose. That is what makes
        /// AppKit walk the responder chain to whatever is focused, and what lets
        /// WebKit answer `validateUserInterfaceItem(_:)` for itself — Paste
        /// greys out on a non-editable field without swift-pwa knowing anything
        /// about the page.
        static func makeMainMenu(for app: NSApplication) -> NSMenu {
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
                ?? ProcessInfo.processInfo.processName

            let mainMenu = NSMenu()
            let appMenuItem = NSMenuItem()
            mainMenu.addItem(appMenuItem)

            let appMenu = NSMenu()
            appMenu.addItem(
                withTitle: "About \(appName)",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
            appMenu.addItem(NSMenuItem.separator())
            appMenu.addItem(
                withTitle: "Hide \(appName)",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"
            )
            let hideOthers = appMenu.addItem(
                withTitle: "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h"
            )
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            appMenu.addItem(
                withTitle: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""
            )
            appMenu.addItem(NSMenuItem.separator())
            appMenu.addItem(
                withTitle: "Quit \(appName)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            appMenuItem.submenu = appMenu

            // Services. AppKit fills and maintains the submenu itself once it
            // knows which one to use; without this the app offers none.
            let servicesMenu = NSMenu()
            let servicesItem = appMenu.insertItem(
                withTitle: "Services",
                action: nil,
                keyEquivalent: "",
                at: appMenu.items.count - 2 // above the separator before Quit
            )
            servicesItem.submenu = servicesMenu
            app.servicesMenu = servicesMenu

            let editMenuItem = NSMenuItem()
            mainMenu.addItem(editMenuItem)
            let editMenu = NSMenu(title: "Edit")
            // `undo:` / `redo:` are declared on no public AppKit class — they
            // are `NSUndoManager` responder-chain messages — so they can only
            // be written as a string selector. The extra parens stop the
            // compiler suggesting `#selector` for a name it can't resolve.
            editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            editMenu.addItem(NSMenuItem.separator())
            editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            // `pasteAsPlainText(_:)` is NSTextView's, not NSText's.
            let pasteMatch = editMenu.addItem(
                withTitle: "Paste and Match Style",
                action: #selector(NSTextView.pasteAsPlainText(_:)),
                keyEquivalent: "v"
            )
            pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
            editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
            editMenu.addItem(
                withTitle: "Select All",
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"
            )
            editMenuItem.submenu = editMenu

            // Window — ⌘M and ⌘W are dead for exactly the same reason.
            let windowMenuItem = NSMenuItem()
            mainMenu.addItem(windowMenuItem)
            let windowMenu = NSMenu(title: "Window")
            windowMenu.addItem(
                withTitle: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
            windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            windowMenu.addItem(NSMenuItem.separator())
            windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            windowMenuItem.submenu = windowMenu
            // Lets AppKit keep the window list and the checkmark up to date.
            app.windowsMenu = windowMenu

            return mainMenu
        }
    }

    /// The app-level `NSApplicationDelegate`: OS document-open events, and
    /// reopening the window when an app with none is activated.
    ///
    /// Document-open events (`Finder → Open With`, `open <file>`, custom URL
    /// schemes) reach the web app over the ``OpenFile`` event-bus channel.
    /// Without a delegate at all, `MacAppRuntime` ran a delegate-less
    /// `NSApplication` and silently dropped opened files.
    @MainActor
    private final class MacAppDelegate: NSObject, NSApplicationDelegate {
        private let events: EventBus
        /// Retains opened security-scoped URLs so the sandbox grant stays
        /// active for the process lifetime. Under the App Sandbox a file from
        /// Launch Services is only readable between
        /// `startAccessingSecurityScopedResource()` and `stop…`; the web app
        /// reads it via `fs.readBinary` after an async bridge round-trip, so
        /// releasing the scope eagerly would revoke access mid-read. Holding
        /// for the session is the simplest correct lifetime for a document the
        /// user explicitly opened.
        private var scopedURLs: [URL] = []
        private let context: MacAppContext

        init(context: MacAppContext) {
            self.context = context
            events = MainActor.assumeIsolated { context.events }
        }

        /// Activating an app that has no windows open — a Dock click, ⌘Tab,
        /// picking it in Launchpad — is macOS's "I want this app" gesture, and
        /// the standard answer is a window. Without this an app whose only
        /// window was closed with ⌘W is visible in the Dock, running, and
        /// unreachable forever.
        ///
        /// Returning `false` tells AppKit not to do anything further itself;
        /// under any policy other than `.reopen` that is the whole answer, and
        /// the app stays windowless on purpose.
        func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
            guard !hasVisibleWindows else { return true }
            return MainActor.assumeIsolated {
                guard context.lastWindowClosed == .reopen else { return false }
                return !context.reopenLastWindow()
            }
        }

        func application(_: NSApplication, open urls: [URL]) {
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return }
            // Activate the sandbox grant where present (no-op / false for a
            // non-sandboxed app, where the path is readable anyway).
            for url in fileURLs where url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
            }
            OpenFile.emit(fileURLs.map(\.path), on: events)
        }
    }
#endif
