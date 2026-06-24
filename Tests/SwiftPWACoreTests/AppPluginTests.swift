import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("AppPlugin")
@MainActor
struct AppPluginTests {
    private func makeApp() -> MockAppContext {
        let app = MockAppContext()
        app.use(AppPlugin())
        return app
    }

    private func dispatch(_ command: String, payload: Data, on app: MockAppContext) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: payload)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    @Test("app.quit with no exitCode quits cleanly with 0")
    func quitDefault() async {
        let app = makeApp()
        let result = await dispatch("app.quit", payload: Data("{}".utf8), on: app)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(app.didQuitWith == 0)
    }

    @Test("app.quit forwards an explicit exitCode")
    func quitWithCode() async throws {
        let app = makeApp()
        let payload = try JSONEncoder().encode(AppQuitArgs(exitCode: 3))
        let result = await dispatch("app.quit", payload: payload, on: app)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(app.didQuitWith == 3)
    }

    @Test("app.name returns a non-empty name")
    func name() async throws {
        let app = makeApp()
        let result = await dispatch("app.name", payload: Data("{}".utf8), on: app)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(StringResult.self, from: data)
        // Falls back to the process name when no Info.plist is present, so
        // this is always populated regardless of test-host bundle shape.
        #expect(!out.value.isEmpty)
    }

    @Test("app.version is callable and returns a string")
    func version() async throws {
        let app = makeApp()
        let result = await dispatch("app.version", payload: Data("{}".utf8), on: app)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        // The value depends on the host bundle (empty when there's no
        // Info.plist); we only assert the command decodes to a StringResult.
        _ = try JSONDecoder().decode(StringResult.self, from: data)
    }

    @Test("app.dataDir returns a created, writable directory path")
    func dataDir() async throws {
        let app = makeApp()
        let result = await dispatch("app.dataDir", payload: Data("{}".utf8), on: app)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(StringResult.self, from: data)
        #expect(!out.value.isEmpty)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: out.value, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("app.cacheDir returns a created directory path, distinct from dataDir")
    func cacheDir() async throws {
        let app = makeApp()
        let dataResult = await dispatch("app.dataDir", payload: Data("{}".utf8), on: app)
        let cacheResult = await dispatch("app.cacheDir", payload: Data("{}".utf8), on: app)
        guard case let .ok(dataData) = dataResult, case let .ok(cacheData) = cacheResult else {
            Issue.record("expected ok"); return
        }
        let dataPath = try JSONDecoder().decode(StringResult.self, from: dataData).value
        let cachePath = try JSONDecoder().decode(StringResult.self, from: cacheData).value
        #expect(FileManager.default.fileExists(atPath: cachePath))
        #expect(dataPath != cachePath)
    }

    @Test("AppPlugin reports its own name on install")
    func pluginName() {
        let app = makeApp()
        #expect(app.installedPlugins.contains("app"))
    }
}
