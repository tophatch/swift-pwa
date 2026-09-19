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
        let ctx = CommandContext(invocation: inv, caller: .agent, appContext: app)
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

    /// `bridge.js` sends `payload: null` for `invoke(cmd)` with no argument,
    /// which is exactly how the JS API documents `app.quit` and how a settings
    /// UI reads `app.lastWindowClosed`. Every earlier test here passed `{}`,
    /// so the shape the page actually sends was never covered — and it failed.
    @Test("a command with all-optional args accepts an absent payload")
    func nullPayloadDecodesAsEmpty() async {
        let app = makeApp()
        let quit = await dispatch("app.quit", payload: Data("null".utf8), on: app)
        guard case .ok = quit else { Issue.record("expected ok"); return }
        #expect(app.didQuitWith == 0)

        let read = await dispatch("app.lastWindowClosed", payload: Data("null".utf8), on: app)
        guard case .ok = read else { Issue.record("expected ok"); return }
    }

    @Test("app.lastWindowClosed reads, sets, and refuses a value that isn't one")
    func lastWindowClosed() async throws {
        let app = makeApp()

        // Reading takes no argument and reports the default.
        let read = await dispatch("app.lastWindowClosed", payload: Data("{}".utf8), on: app)
        guard case let .ok(data) = read else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(StringResult.self, from: data).value == "reopen")

        // Setting replies with the value now in force, so a settings UI can
        // round-trip in one call.
        let set = try await dispatch(
            "app.lastWindowClosed",
            payload: JSONEncoder().encode(AppLastWindowClosedArgs(value: "keep-running")),
            on: app
        )
        guard case let .ok(setData) = set else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(StringResult.self, from: setData).value == "keep-running")
        #expect(app.lastWindowClosed == .keepRunning)

        // A typo must not silently leave the old policy in place looking set.
        let bad = try await dispatch(
            "app.lastWindowClosed",
            payload: JSONEncoder().encode(AppLastWindowClosedArgs(value: "quitt")),
            on: app
        )
        guard case .failure = bad else { Issue.record("expected a failure"); return }
        #expect(app.lastWindowClosed == .keepRunning)
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

    /// Remove a directory only if nothing is in it, so a run can't delete a
    /// folder that was already someone's.
    private func removeIfEmpty(_ url: URL) {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        guard contents?.isEmpty == true else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// #250: the folder a *person* sees, as against the two containers above.
    /// An app that wants the user to keep something has had nowhere to put it
    /// and has been hardcoding a path per platform.
    @Test("app.documentsDir returns a created directory, distinct from the app's containers")
    func documentsDir() async throws {
        let app = makeApp()
        // This one creates a folder in the *user's* Documents, so the test
        // tidies up after itself — a test suite that leaves litter where a
        // person can see it is its own small bug. Removed only while empty:
        // asking for the path is what creates it, so "did it exist before"
        // can't be answered without creating it first.
        let expected = PlatformDirectories.documentsDirectory(appName: AppPlugin.appName())
        defer { removeIfEmpty(expected) }
        let result = await dispatch("app.documentsDir", payload: Data("{}".utf8), on: app)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DocumentsLocation.self, from: data)
        #expect(!out.path.isEmpty)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        // It is a *user* location, so it must not be the private container.
        let dataResult = await dispatch("app.dataDir", payload: Data("{}".utf8), on: app)
        guard case let .ok(dataData) = dataResult else { Issue.record("expected ok"); return }
        #expect(try out.path != (JSONDecoder().decode(StringResult.self, from: dataData).value))
        // Writable, since the whole point is that the app puts things there.
        let probe = URL(fileURLWithPath: out.path).appendingPathComponent("swift-pwa-probe.txt")
        try Data("hi".utf8).write(to: probe)
        try FileManager.default.removeItem(at: probe)
        // And the one fact an app has to branch on, asserted here rather than
        // in a second test: both would race over one shared location, and the
        // loser's cleanup would delete the winner's directory mid-run.
        #if os(iOS)
            #expect(out.survivesUninstall == false)
        #else
            #expect(out.survivesUninstall == true)
        #endif
    }

    @Test("AppPlugin reports its own name on install")
    func pluginName() {
        let app = makeApp()
        #expect(app.installedPlugins.contains("app"))
    }

    @Test("strippingExeExtension drops a trailing .exe (Windows processName) but nothing else")
    func stripExeExtension() {
        // Windows `ProcessInfo.processName` includes `.exe`; it must not leak
        // into app.name or the data/cache dir leaf.
        #expect(AppPlugin.strippingExeExtension("CritterFacts.exe") == "CritterFacts")
        #expect(AppPlugin.strippingExeExtension("CritterFacts.EXE") == "CritterFacts") // case-insensitive
        #expect(AppPlugin.strippingExeExtension("CritterFacts") == "CritterFacts") // no-op (macOS/Linux)
        #expect(AppPlugin.strippingExeExtension("my.tool") == "my.tool") // only .exe is stripped
        #expect(AppPlugin.strippingExeExtension(".exe") == "") // degenerate, but consistent
    }
}
