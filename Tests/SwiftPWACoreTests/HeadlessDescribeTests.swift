import Foundation
@testable import SwiftPWACore
import Testing

/// The headless catalog dump (roadmap #6): `HeadlessAppContext` stands in for a
/// real backend so `swift-pwa codegen` can read the command catalog without a
/// window/webview. These cover the testable core — the built-in plugin set, that
/// an app's `configure` closure registers into it, and the no-op window factory.
/// The `exit(0)`-terminating `dumpIfRequested` path is exercised end-to-end by
/// running `swift-pwa codegen` against a real app.
@Suite("Headless describe")
@MainActor
struct HeadlessDescribeTests {
    @Test("the headless context installs the same built-ins a real backend does")
    func installsBuiltins() {
        let ctx = HeadlessAppContext()
        let names = Set(ctx.registry.names())
        // One representative command from each built-in plugin.
        for expected in [
            "window.setSize", // WindowPlugin
            "__platform.info", // PlatformInfoPlugin
            "__bridge.describe", // PlatformInfoPlugin (codegen)
            "system.memory", // SystemPlugin
            "app.version", // AppPlugin
            "clipboard.readText" // ClipboardPlugin
        ] {
            #expect(names.contains(expected), "missing built-in \(expected)")
        }
    }

    @Test("built-in command shapes are typed in the catalog (probed, no annotation)")
    func builtinsAreTyped() {
        let ctx = HeadlessAppContext()
        let setSize = ctx.registry.descriptors().first { $0.name == "window.setSize" }
        #expect(setSize?.args == .object(name: "SetSizeArgs", fields: [
            .init(name: "id", schema: .optional(.string)),
            .init(name: "width", schema: .double),
            .init(name: "height", schema: .double),
            .init(name: "animated", schema: .optional(.bool))
        ]))
    }

    @Test("a configure closure registers into the headless context")
    func configureRegisters() throws {
        struct Ping: Codable, Sendable { let n: Int }
        let ctx = HeadlessAppContext()
        // Mimic what a backend does: run the app's configure against the context.
        let configure: @MainActor @Sendable (any AppContext) throws -> Void = { app in
            app.registry.register("demo.ping", typed: { (_: Ping, _) -> Ping in Ping(n: 1) })
            _ = try app.createWindow(WindowConfig(
                title: "T",
                size: .init(width: 10, height: 20),
                content: .remote(URL(fileURLWithPath: "/"))
            ))
        }
        try configure(ctx)

        let ping = ctx.registry.descriptors().first { $0.name == "demo.ping" }
        #expect(ping?.kind == .unary)
        #expect(ping?.args == .object(name: "Ping", fields: [.init(name: "n", schema: .int)]))
    }

    @Test("createWindow returns an inert window that records requested state")
    func createWindowIsInert() throws {
        let ctx = HeadlessAppContext()
        let win = try ctx.createWindow(WindowConfig(
            title: "Hello",
            size: .init(width: 640, height: 480),
            content: .remote(URL(fileURLWithPath: "/"))
        ))
        #expect(ctx.windows[win.id] != nil)
        #expect(win.title() == "Hello")
        #expect(win.size() == .init(width: 640, height: 480))
        // Setters don't crash and read back.
        win.setTitle("Renamed")
        win.setFullscreen(true)
        #expect(win.title() == "Renamed")
        #expect(win.isFullscreen())
        win.close() // no-op, must not throw/crash
    }

    @Test("the emitted catalog round-trips as [CommandDescriptor] JSON")
    func catalogRoundTrips() throws {
        let ctx = HeadlessAppContext()
        let descriptors = ctx.registry.descriptors()
        let data = try JSONEncoder().encode(descriptors)
        let back = try JSONDecoder().decode([CommandDescriptor].self, from: data)
        #expect(back == descriptors)
        #expect(back.contains { $0.name == "__bridge.describe" })
    }
}
