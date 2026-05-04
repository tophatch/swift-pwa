#if os(macOS)
    import AppKit
    import Foundation
    import SwiftPWACore

    /// macOS-side runtime. Owns the singleton `MacAppContext` and drives
    /// `NSApplication.run()`. The `configure` closure runs synchronously
    /// before `NSApp.run()` enters the AppKit event loop — windows it
    /// creates are visible from the moment the loop starts.
    @MainActor
    public final class MacAppRuntime {
        public static let shared = MacAppRuntime()
        public let context = MacAppContext()
        private var didStartConfigure = false

        private init() {}

        public func bootstrap(
            configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) {
            guard !didStartConfigure else { return }
            didStartConfigure = true
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.mainMenu = Self.makeMainMenu()

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
                FileHandle.standardError.write(
                    Data("swift-pwa: configure threw: \(error)\n".utf8)
                )
            }
            NSApp.activate(ignoringOtherApps: true)
        }

        public func runForever() -> Never {
            NSApplication.shared.run()
            // NSApp.run() returns after orderly shutdown. Use the
            // exit code stashed by `MacAppContext.quit`, defaulting
            // to 0 on a clean termination.
            exit(context.pendingExitCode ?? 0)
        }

        /// Minimal application menu so ⌘Q / ⌘H / About work out of the
        /// box. Without an `NSApp.mainMenu`, AppKit installs nothing —
        /// the app silently has no menu bar and ⌘Q is a no-op.
        private static func makeMainMenu() -> NSMenu {
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
            return mainMenu
        }
    }
#endif
