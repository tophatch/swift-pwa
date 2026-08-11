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
    /// What art is currently on the tray, so republishing the same state
    /// doesn't rewrite the icon. The surface publishes on every attach and
    /// detach, and some shells flicker an icon that's reassigned.
    private var appliedIcon: IconKey?

    private struct IconKey: Equatable {
        let connected: Bool
        let light: Bool
    }

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
        setIcon(on: tray, connected: update.state.attached)
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

    /// The ring alone while access is open, with an inset dot once a client is
    /// connected — so the difference between "the door is open" and "someone is
    /// through it" is visible without hovering for the tooltip.
    private func setIcon(on tray: any Tray, connected: Bool) {
        let light = tray.prefersLightArt ?? false
        let key = IconKey(connected: connected, light: light)
        guard key != appliedIcon,
              let path = AgentIndicatorMark.pngPath(connected: connected, lightForeground: light)
        else { return }
        // `template` asks AppKit to tint for the menu bar, which is why Apple
        // needs no polarity of its own; ignored where the platform doesn't
        // auto-tint, which is what `prefersLightArt` is for.
        tray.setIcon(path: path, template: true)
        appliedIcon = key
    }

    private func ensureTray() -> any Tray {
        if let tray { return tray }
        let tray = makeTray()
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
        appliedIcon = nil
    }
}
