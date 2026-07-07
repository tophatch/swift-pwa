import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("SystemPlugin")
@MainActor
struct SystemPluginTests {
    private func makeApp() -> MockAppContext {
        let app = MockAppContext()
        app.use(SystemPlugin())
        return app
    }

    private func dispatch(_ command: String, payload: Data, on app: MockAppContext) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    @Test("SystemPlugin registers under its name")
    func pluginName() {
        let app = makeApp()
        #expect(app.installedPlugins.contains("system"))
        #expect(app.registry.names().contains("system.memory"))
    }

    @Test("system.memory reports a plausible total RAM")
    func memoryReadsPhysical() async throws {
        let app = makeApp()
        let result = await dispatch("system.memory", payload: Data("{}".utf8), on: app)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let snap = try JSONDecoder().decode(MemorySnapshot.self, from: data)
        // Any real machine (and CI host) has more than 64 MiB; this just
        // guards against a zero / bogus read.
        #expect(snap.physicalBytes > 64 * 1024 * 1024)
        // Where availableBytes is reported it can't exceed physical.
        if let available = snap.availableBytes {
            #expect(available <= snap.physicalBytes)
        }
    }

    @Test("DefaultMemoryProvider matches ProcessInfo for physical RAM")
    func providerPhysicalMatchesProcessInfo() async {
        let snap = await DefaultMemoryProvider().snapshot()
        #expect(snap.physicalBytes == ProcessInfo.processInfo.physicalMemory)
        // No per-app OS ceiling on the desktop test host.
        #expect(snap.appLimitBytes == nil)
    }

    @Test("MemorySnapshot round-trips through JSON with omitted optionals")
    func snapshotCodable() throws {
        let snap = MemorySnapshot(physicalBytes: 8 * 1024 * 1024 * 1024)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(MemorySnapshot.self, from: data)
        #expect(back == snap)
        #expect(back.availableBytes == nil)
        #expect(back.lowMemory == false)
    }
}

@Suite("PlatformInfo memory fields")
@MainActor
struct PlatformInfoMemoryTests {
    private func dispatch(_ command: String, on app: MockAppContext) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    @Test("__platform.info carries physicalMemoryBytes and a nil default app limit")
    func platformInfoMemory() async throws {
        let app = MockAppContext()
        app.use(PlatformInfoPlugin())
        let result = await dispatch("__platform.info", on: app)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let info = try JSONDecoder().decode(PlatformInfo.self, from: data)
        #expect(info.physicalMemoryBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(info.appMemoryLimitBytes == nil)
    }

    @Test("__platform.info surfaces an injected app-memory limit")
    func platformInfoInjectedLimit() async throws {
        let app = MockAppContext()
        app.use(PlatformInfoPlugin(appMemoryLimit: { 256 * 1024 * 1024 }))
        let result = await dispatch("__platform.info", on: app)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let info = try JSONDecoder().decode(PlatformInfo.self, from: data)
        #expect(info.appMemoryLimitBytes == 256 * 1024 * 1024)
    }
}
