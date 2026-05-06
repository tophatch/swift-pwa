import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("UpdaterPlugin")
@MainActor
struct UpdaterPluginTests {
    private func makeApp() -> (MockAppContext, MockUpdater) {
        let app = MockAppContext()
        let updater = MockUpdater()
        app.use(UpdaterPlugin(updater))
        return (app, updater)
    }

    private func sampleInfo(version: String = "0.4.0", current: String = "0.3.0") -> UpdateInfo {
        UpdateInfo(
            version: version,
            currentVersion: current,
            pubDate: "2026-05-12T10:00:00Z",
            notes: "Bug fixes.",
            downloadURL: URL(string: "https://updates.example.com/0.4.0.app.tar.gz")!,
            signature: "AAAA",
            target: "darwin-aarch64"
        )
    }

    // MARK: - check

    @Test("updater.check returns null when up to date")
    func checkUpToDate() async throws {
        let (app, updater) = makeApp()
        updater.nextCheckResult = nil
        let inv = Invocation(id: 1, command: "updater.check", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let value = try JSONDecoder().decode(UpdateInfo?.self, from: data)
        #expect(value == nil)
        #expect(updater.actions == [.check])
    }

    @Test("updater.check returns the UpdateInfo when available")
    func checkAvailable() async throws {
        let (app, updater) = makeApp()
        let info = sampleInfo()
        updater.nextCheckResult = info
        let inv = Invocation(id: 1, command: "updater.check", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let value = try JSONDecoder().decode(UpdateInfo?.self, from: data)
        #expect(value == info)
    }

    // MARK: - run

    @Test("updater.run yields checking → upToDate when no update")
    func runUpToDate() async throws {
        let (app, updater) = makeApp()
        updater.nextCheckResult = nil
        let events = try await collectRun(app: app, args: "{}")
        #expect(events == [.checking, .upToDate])
        #expect(updater.actions == [.check])
    }

    @Test("updater.run yields checking → available → download events")
    func runHappyPath() async throws {
        let (app, updater) = makeApp()
        let info = sampleInfo()
        updater.nextCheckResult = info
        updater.nextDownloadEvents = [
            .downloadProgress(bytesDownloaded: 1024, contentLength: 4096),
            .downloadProgress(bytesDownloaded: 4096, contentLength: 4096),
            .readyToInstall
        ]
        let events = try await collectRun(app: app, args: "{}")
        #expect(events == [
            .checking,
            .available(info),
            .downloadProgress(bytesDownloaded: 1024, contentLength: 4096),
            .downloadProgress(bytesDownloaded: 4096, contentLength: 4096),
            .readyToInstall
        ])
        #expect(updater.actions == [.check, .download(info)])
    }

    @Test("updater.run skips check when caller passes UpdateInfo")
    func runSkipsCheck() async throws {
        let (app, updater) = makeApp()
        let info = sampleInfo()
        let payload = try #require(String(data: JSONEncoder().encode(UpdaterRunArgs(info: info)), encoding: .utf8))
        let events = try await collectRun(app: app, args: payload)
        #expect(events.first == .available(info))
        #expect(updater.actions == [.download(info)]) // no .check
    }

    @Test("updater.run surfaces a download error as an error event")
    func runDownloadError() async throws {
        let (app, updater) = makeApp()
        updater.nextCheckResult = sampleInfo()
        updater.nextDownloadEvents = [.downloadProgress(bytesDownloaded: 100, contentLength: nil)]
        updater.nextDownloadError = BridgeError(code: BridgeError.handler, message: "network gone")
        let events = try await collectRun(app: app, args: "{}", expectError: true)
        // Last event should be the synthesized .error mirror.
        guard case let .error(code, message) = events.last else {
            Issue.record("expected trailing .error event, got \(String(describing: events.last))")
            return
        }
        #expect(code == BridgeError.handler)
        #expect(message == "network gone")
    }

    // MARK: - installAndRelaunch

    @Test("updater.installAndRelaunch invokes the updater")
    func installAndRelaunch() async {
        let (app, updater) = makeApp()
        let inv = Invocation(id: 1, command: "updater.installAndRelaunch", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(updater.actions == [.installAndRelaunch])
    }

    @Test("updater.installAndRelaunch surfaces errors as bridge errors")
    func installError() async {
        let (app, updater) = makeApp()
        updater.nextInstallError = BridgeError(code: BridgeError.handler, message: "no staged update")
        let inv = Invocation(id: 1, command: "updater.installAndRelaunch", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.handler)
        #expect(err.message.contains("no staged update"))
    }

    // MARK: - helpers

    private func collectRun(
        app: MockAppContext,
        args: String,
        expectError: Bool = false
    ) async throws -> [UpdaterEvent] {
        let inv = Invocation(id: 1, command: "updater.run", payload: Data(args.utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .stream(stream) = result else {
            Issue.record("expected stream result")
            return []
        }
        var collected: [UpdaterEvent] = []
        do {
            for try await chunk in stream {
                let event = try JSONDecoder().decode(UpdaterEvent.self, from: chunk)
                collected.append(event)
            }
            if expectError { Issue.record("expected the stream to throw") }
        } catch {
            if !expectError { throw error }
        }
        return collected
    }
}
