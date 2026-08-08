import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// The runtime-owned indicator: what a user sees when agent access is open.
///
/// Its whole reason to exist is surviving a developer who cuts the corner and
/// skips asking, so the behaviour is defined in Core (backends supply only a
/// tray) and checked here rather than five times over.
@MainActor
@Suite("Agent indicator")
struct AgentIndicatorTests {
    static let tools = [
        AgentTool(command: "book.open", description: "Open a book.", readOnly: true),
        AgentTool(command: "book.delete", description: "Delete a book.", destructive: true)
    ]

    static func state(enabled: Bool, attached: Bool) -> AgentState {
        AgentState(
            enabled: enabled,
            attached: attached,
            port: enabled ? 51234 : nil,
            token: enabled ? "abc" : nil,
            tools: tools
        )
    }

    static func update(
        enabled: Bool,
        attached: Bool = false,
        disable: @escaping @Sendable () -> Void = {}
    ) -> AgentIndicatorUpdate {
        AgentIndicatorUpdate(state: state(enabled: enabled, attached: attached), disable: disable)
    }

    @Test("nothing is shown while access is off")
    func hiddenWhileOff() {
        let tray = MockTray()
        let holder = TrayIndicatorHolder { tray }
        holder.apply(Self.update(enabled: false))
        // Not even constructed: an app that never opens the door shouldn't grow
        // a status item.
        #expect(tray.actions.isEmpty)
    }

    @Test("it appears the moment access is enabled, not when a client connects")
    func shownWhileEnabled() {
        let tray = MockTray()
        let holder = TrayIndicatorHolder { tray }
        holder.apply(Self.update(enabled: true, attached: false))
        // The port is open and anyone with the token can connect, so a user who
        // forgot they'd allowed it must still see something.
        #expect(tray.visible)
        #expect(tray.iconPath != nil)
        #expect(tray.tooltip?.contains("2 tools") == true, "\(tray.tooltip ?? "nil")")
        #expect(tray.menu.items.first?.label == "Waiting for an agent")
    }

    @Test("it says so once a client is actually connected")
    func reportsAttachment() {
        let tray = MockTray()
        let holder = TrayIndicatorHolder { tray }
        holder.apply(Self.update(enabled: true, attached: false))
        holder.apply(Self.update(enabled: true, attached: true))
        #expect(tray.menu.items.first?.label == "Agent connected")
        #expect(tray.tooltip?.contains("connected") == true, "\(tray.tooltip ?? "nil")")
    }

    @Test("it goes away when access is revoked")
    func hiddenAgainAfterRevoke() {
        let tray = MockTray()
        let holder = TrayIndicatorHolder { tray }
        holder.apply(Self.update(enabled: true))
        holder.apply(Self.update(enabled: false))
        #expect(tray.visible == false)
    }

    @Test("the menu offers a way to turn access off")
    func offersRevocation() async {
        let tray = MockTray()
        let holder = TrayIndicatorHolder { tray }
        let revoked = Flag()
        holder.apply(Self.update(enabled: true, disable: { revoked.set() }))

        let item = tray.menu.items.first { $0.id == "disable" }
        #expect(item?.label == "Turn off agent access")

        tray.emit(.menuItemClicked(id: "disable"))
        // The event stream is consumed by a Task; give it a turn.
        for _ in 0 ..< 50 where !revoked.value {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(revoked.value, "the tray's disable item didn't revoke access")
    }

    @Test("an unrelated menu click doesn't revoke")
    func ignoresOtherItems() async {
        let tray = MockTray()
        let holder = TrayIndicatorHolder { tray }
        let revoked = Flag()
        holder.apply(Self.update(enabled: true, disable: { revoked.set() }))

        tray.emit(.menuItemClicked(id: "status"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(revoked.value == false)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }
}
