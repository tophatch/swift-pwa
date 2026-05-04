import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("TrayPlugin")
@MainActor
struct TrayPluginTests {
    private func makeApp() -> (MockAppContext, MockTray) {
        let app = MockAppContext()
        let tray = MockTray()
        app.use(TrayPlugin(tray))
        return (app, tray)
    }

    @Test("tray.setIcon forwards path and template flag")
    func setIcon() async throws {
        let (app, tray) = makeApp()
        let payload = try JSONEncoder().encode(TraySetIconArgs(path: "/tmp/icon.png", template: true))
        let inv = Invocation(id: 1, command: "tray.setIcon", payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(tray.iconPath == "/tmp/icon.png")
        #expect(tray.iconTemplate)
        #expect(tray.actions == [.setIcon(path: "/tmp/icon.png", template: true)])
    }

    @Test("tray.setIcon defaults template to false when omitted")
    func setIconDefaultTemplate() async {
        let (app, tray) = makeApp()
        let inv = Invocation(
            id: 1,
            command: "tray.setIcon",
            payload: Data(#"{"path":"/tmp/icon.png"}"#.utf8)
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(tray.iconTemplate == false)
    }

    @Test("tray.setTooltip forwards text")
    func setTooltip() async throws {
        let (app, tray) = makeApp()
        let payload = try JSONEncoder().encode(TraySetTooltipArgs(text: "Hello"))
        let inv = Invocation(id: 1, command: "tray.setTooltip", payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(tray.tooltip == "Hello")
    }

    @Test("tray.setMenu replaces the menu items")
    func setMenu() async throws {
        let (app, tray) = makeApp()
        let menu = TrayMenu(items: [
            TrayMenuItem(id: "open", label: "Open"),
            .separator(),
            TrayMenuItem(id: "quit", label: "Quit", enabled: true)
        ])
        let payload = try JSONEncoder().encode(menu)
        let inv = Invocation(id: 1, command: "tray.setMenu", payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(tray.menu == menu)
    }

    @Test("tray.setVisible toggles visibility")
    func setVisible() async throws {
        let (app, tray) = makeApp()
        let payload = try JSONEncoder().encode(TraySetVisibleArgs(visible: false))
        let inv = Invocation(id: 1, command: "tray.setVisible", payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(tray.visible == false)
    }

    @Test("tray.subscribe streams click and menu events")
    func subscribe() async throws {
        let (app, tray) = makeApp()
        let inv = Invocation(id: 1, command: "tray.subscribe", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }

        var iterator = stream.makeAsyncIterator()
        await MainActor.run { tray.emit(.click) }
        let chunk = try await iterator.next()
        let event = try JSONDecoder().decode(TrayEvent.self, from: #require(chunk))
        #expect(event == .click)

        await MainActor.run { tray.emit(.menuItemClicked(id: "quit")) }
        let chunk2 = try await iterator.next()
        let event2 = try JSONDecoder().decode(TrayEvent.self, from: #require(chunk2))
        #expect(event2 == .menuItemClicked(id: "quit"))
    }

    @Test("TrayEvent codable round-trip matches WindowEvent shape")
    func eventCodable() throws {
        let click = TrayEvent.click
        let menuClick = TrayEvent.menuItemClicked(id: "open")

        // Sort keys so the wire shape comparison is deterministic —
        // Swift's JSONEncoder iterates a hash-randomized dictionary
        // otherwise.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let clickJSON = try encoder.encode(click)
        let menuJSON = try encoder.encode(menuClick)

        #expect(String(data: clickJSON, encoding: .utf8) == #"{"type":"click"}"#)
        #expect(String(data: menuJSON, encoding: .utf8) == #"{"id":"open","type":"menuItemClicked"}"#)

        #expect(try JSONDecoder().decode(TrayEvent.self, from: clickJSON) == click)
        #expect(try JSONDecoder().decode(TrayEvent.self, from: menuJSON) == menuClick)
    }
}
