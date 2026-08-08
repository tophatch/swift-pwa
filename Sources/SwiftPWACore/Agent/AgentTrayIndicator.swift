import Foundation

/// Drives the tray status item that shows agent access is open.
///
/// Lives in Core, not in each backend, so there is exactly one definition of
/// what the user sees. Backends supply a `Tray`; everything about when it
/// appears, what it says, and that it can be turned off from there is decided
/// here — the point of the indicator is that it isn't the app's to shape.
@MainActor
final class TrayIndicatorHolder {
    private let makeTray: @MainActor @Sendable () -> any Tray
    private var tray: (any Tray)?
    private var eventTask: Task<Void, Never>?
    private var disable: (@Sendable () -> Void)?

    /// `nonisolated` so a backend can install the indicator from wherever its
    /// startup runs; every method that touches the tray is MainActor.
    nonisolated init(makeTray: @escaping @MainActor @Sendable () -> any Tray) {
        self.makeTray = makeTray
    }

    func apply(_ update: AgentIndicatorUpdate) {
        disable = update.disable
        guard update.state.enabled else {
            hide()
            return
        }
        let tray = ensureTray()
        let toolCount = update.state.tools.count
        let plural = toolCount == 1 ? "" : "s"
        tray.setTooltip(
            update.state.attached
                ? "An agent is connected to this app (\(toolCount) tool\(plural))."
                : "This app is open to an agent (\(toolCount) tool\(plural)). Nothing is connected yet."
        )
        tray.setMenu(TrayMenu(items: [
            TrayMenuItem(
                id: "status",
                label: update.state.attached ? "Agent connected" : "Waiting for an agent",
                enabled: false
            ),
            .separator(),
            TrayMenuItem(id: "disable", label: "Turn off agent access")
        ]))
        tray.setVisible(true)
    }

    private func ensureTray() -> any Tray {
        if let tray { return tray }
        let tray = makeTray()
        if let path = Self.iconPath() {
            // `template` asks AppKit to tint for the menu bar; ignored where
            // the platform doesn't auto-tint.
            tray.setIcon(path: path, template: true)
        }
        // Subscribe *now*, not inside the Task: `eventStream()` registers the
        // continuation when it's called, so deferring it would drop anything
        // emitted before the task got its first turn.
        let events = tray.eventStream()
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard case let .menuItemClicked(id) = event, id == "disable" else { continue }
                self?.disable?()
            }
        }
        self.tray = tray
        return tray
    }

    private func hide() {
        tray?.setVisible(false)
        eventTask?.cancel()
        eventTask = nil
        tray = nil
    }

    /// The icon is embedded as bytes and written to a temp file on first use:
    /// `Tray.setIcon` takes a path, and Core carrying a resource for this would
    /// mean every app paid for it whether or not it ever declares a tool.
    private static func iconPath() -> String? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-agent-indicator.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? Data(iconPNG).write(to: url)) != nil else { return nil }
        }
        return url.path
    }
}

/// 22×22 RGBA PNG: a ring around a filled dot — the "something is connected"
/// mark, legible at menu-bar size and monochrome so it templates cleanly.
private let iconPNG: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00, 0x16,
    0x08, 0x06, 0x00, 0x00, 0x00, 0xC4, 0xB4, 0x6C, 0x3B, 0x00, 0x00, 0x00,
    0xAE, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0xC5, 0x55, 0xC1, 0x0D, 0x80,
    0x20, 0x0C, 0x74, 0x04, 0x46, 0x61, 0x04, 0x46, 0x71, 0x04, 0x46, 0x60,
    0x13, 0x47, 0x61, 0x04, 0x47, 0x60, 0x14, 0xC5, 0xA4, 0x26, 0x67, 0xA5,
    0x60, 0x34, 0x17, 0x9B, 0xDC, 0xA7, 0x94, 0xE3, 0x5A, 0x4A, 0x99, 0xA6,
    0x1F, 0xCD, 0x57, 0xCC, 0x15, 0x49, 0x30, 0x8B, 0xEF, 0xB5, 0x1D, 0x04,
    0xA5, 0x62, 0x33, 0x50, 0x24, 0xE6, 0xB1, 0xB9, 0x8A, 0xDC, 0x21, 0xD4,
    0xC8, 0xB2, 0x67, 0x48, 0xBA, 0x2A, 0x55, 0x51, 0xA5, 0xEE, 0xC5, 0x87,
    0xD9, 0xAC, 0x23, 0x72, 0x54, 0xBA, 0x0C, 0x82, 0x9D, 0xC4, 0xA0, 0x72,
    0xB3, 0xA6, 0x48, 0xFA, 0xD4, 0x90, 0xBC, 0x59, 0xF3, 0x02, 0xE9, 0x6B,
    0xA5, 0x01, 0xBA, 0x22, 0x34, 0x94, 0xE3, 0xDE, 0x5B, 0x4B, 0x9D, 0xA7,
    0xC6, 0x8E, 0x22, 0x2B, 0xA3, 0x08, 0x6B, 0xDE, 0x2A, 0x83, 0x57, 0x4A,
    0xAD, 0x6E, 0x08, 0x86, 0xB0, 0x4B, 0x39, 0x12, 0x2C, 0x58, 0x7E, 0x8D,
    0xA4, 0x62, 0x9B, 0x7E, 0x1A, 0x31, 0xAD, 0x14, 0xB4, 0xCB, 0xA3, 0xB5,
    0x1B, 0xF5, 0x81, 0xD0, 0x9E, 0x34, 0x75, 0x08, 0xD1, 0xC6, 0x26, 0x75,
    0xD0, 0xD3, 0xBF, 0xA6, 0x4F, 0xB6, 0x03, 0xED, 0x45, 0xA9, 0xA5, 0x20,
    0xC5, 0xE0, 0xC5, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82
]
