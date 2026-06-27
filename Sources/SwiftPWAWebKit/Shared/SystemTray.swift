#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore

    #if os(macOS)
        import AppKit

        /// macOS `Tray` backed by an `NSStatusItem` in the system status
        /// bar. Click behaviour matches the platform: when a menu is set
        /// AppKit shows it on click; when no menu is set, left-click
        /// emits `.click` via the button's target/action.
        @MainActor
        public final class SystemTray: NSObject, Tray {
            private let statusItem: NSStatusItem
            private var continuations: [UUID: AsyncStream<TrayEvent>.Continuation] = [:]

            override public init() {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                super.init()
                statusItem.button?.target = self
                statusItem.button?.action = #selector(buttonClicked)
            }

            public func setIcon(path: String, template: Bool) {
                guard let image = NSImage(contentsOfFile: path) else { return }
                image.isTemplate = template
                statusItem.button?.image = image
            }

            public func setTooltip(_ text: String) {
                statusItem.button?.toolTip = text
            }

            public func setMenu(_ menu: TrayMenu) {
                if menu.items.isEmpty {
                    // Tearing the menu down restores left-click → button
                    // action; AppKit suppresses the action while a menu
                    // is attached, so we have to rebind on every removal.
                    statusItem.menu = nil
                    statusItem.button?.target = self
                    statusItem.button?.action = #selector(buttonClicked)
                    return
                }
                let nsmenu = NSMenu()
                for item in menu.items {
                    if item.separator {
                        nsmenu.addItem(.separator())
                    } else {
                        let mi = NSMenuItem(
                            title: item.label,
                            action: #selector(menuItemClicked(_:)),
                            keyEquivalent: ""
                        )
                        mi.target = self
                        mi.isEnabled = item.enabled
                        mi.representedObject = item.id
                        nsmenu.addItem(mi)
                    }
                }
                statusItem.menu = nsmenu
            }

            public func setVisible(_ visible: Bool) {
                statusItem.isVisible = visible
            }

            public func eventStream() -> AsyncStream<TrayEvent> {
                let key = UUID()
                return AsyncStream { continuation in
                    self.continuations[key] = continuation
                    continuation.onTermination = { @Sendable _ in
                        Task { @MainActor in self.continuations.removeValue(forKey: key) }
                    }
                }
            }

            @objc private func buttonClicked() {
                emit(.click)
            }

            @objc private func menuItemClicked(_ sender: NSMenuItem) {
                guard let id = sender.representedObject as? String else { return }
                emit(.menuItemClicked(id: id))
            }

            private func emit(_ event: TrayEvent) {
                for c in continuations.values { c.yield(event) }
            }
        }

    #else // os(iOS)

        /// iOS has no system tray — `SystemTray` is a no-op stub so the
        /// same `TrayPlugin(SystemTray())` line works on every platform.
        /// All commands resolve successfully but display nothing; a
        /// one-shot warning is logged the first time anything is called.
        @MainActor
        public final class SystemTray: Tray {
            private var warned = false

            public init() {}

            public func setIcon(path _: String, template _: Bool) { warnOnce() }
            public func setTooltip(_: String) { warnOnce() }
            public func setMenu(_: TrayMenu) { warnOnce() }
            public func setVisible(_: Bool) { warnOnce() }

            public func eventStream() -> AsyncStream<TrayEvent> {
                AsyncStream { $0.finish() }
            }

            private func warnOnce() {
                guard !warned else { return }
                warned = true
                FileHandle.standardError.writeQuietly(Data(
                    "swift-pwa: TrayPlugin is a no-op on iOS — system has no tray.\n".utf8
                ))
            }
        }
    #endif
#endif
