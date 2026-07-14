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

    // MARK: - auto-check polling

    @Test("auto-check emits an available update on updateAvailable (retained)")
    func autoCheckEmitsAvailable() async {
        let (app, updater) = makeApp()
        let info = sampleInfo()
        updater.nextCheckResult = info
        let captured = Captured<UpdateInfo>()
        let sub = app.events.subscribe(UpdaterPlugin.updateAvailableChannel) { data in
            if let i = try? JSONDecoder().decode(UpdateInfo.self, from: data) { captured.append(i) }
        }
        defer { sub.cancel() }

        await UpdaterPlugin.checkAndEmit(updater, to: app.events)
        #expect(captured.values == [info])
        #expect(updater.actions == [.check])

        // Retained: a subscriber that connects *after* the emit still
        // receives the latest available update.
        let late = Captured<UpdateInfo>()
        let sub2 = app.events.subscribe(UpdaterPlugin.updateAvailableChannel) { data in
            if let i = try? JSONDecoder().decode(UpdateInfo.self, from: data) { late.append(i) }
        }
        defer { sub2.cancel() }
        #expect(late.values == [info])
    }

    @Test("auto-check stays silent when up to date or the check throws")
    func autoCheckSilentWhenNoUpdate() async {
        let (app, updater) = makeApp()
        let captured = Captured<UpdateInfo>()
        let sub = app.events.subscribe(UpdaterPlugin.updateAvailableChannel) { data in
            if let i = try? JSONDecoder().decode(UpdateInfo.self, from: data) { captured.append(i) }
        }
        defer { sub.cancel() }

        // Up to date → no emit.
        updater.nextCheckResult = nil
        await UpdaterPlugin.checkAndEmit(updater, to: app.events)
        #expect(captured.values.isEmpty)

        // Transient check error → swallowed, still no emit.
        updater.nextCheckError = BridgeError(code: BridgeError.handler, message: "offline")
        await UpdaterPlugin.checkAndEmit(updater, to: app.events)
        #expect(captured.values.isEmpty)
    }

    @Test("autoCheck clamps a too-small interval to the 60s floor")
    func autoCheckIntervalFloor() {
        // A misconfigured 0 must not become a hot loop; the initializer
        // clamps to 60s. (Constructing the plugin is enough — the value
        // is private, so this asserts the plugin builds without spinning.)
        _ = UpdaterPlugin(MockUpdater(), autoCheck: true, checkInterval: 0)
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

    // MARK: - install (streaming variant)

    @Test("updater.install finishes silently on default-impl backends (happy path)")
    func installDefaultHappyPath() async throws {
        let (app, updater) = makeApp()
        let events = try await collectInstall(app: app)
        // MockUpdater inherits the default protocol impl, which just
        // calls installAndRelaunch() and finishes. No events are
        // expected on the wire — matches the desktop-backend story
        // where install replaces the running process.
        #expect(events.isEmpty)
        #expect(updater.actions == [.installAndRelaunch])
    }

    @Test("updater.install surfaces commit-time errors as a trailing .error event")
    func installDefaultError() async throws {
        let (app, updater) = makeApp()
        updater.nextInstallError = BridgeError(code: BridgeError.handler, message: "no staged update")
        let events = try await collectInstall(app: app, expectError: true)
        guard case let .error(code, message) = events.last else {
            Issue.record("expected trailing .error event, got \(String(describing: events.last))")
            return
        }
        #expect(code == BridgeError.handler)
        #expect(message.contains("no staged update"))
    }

    // MARK: - Event codec (round-trip the new install-lifecycle cases)

    @Test("installCommitted / installSucceeded / installFailed round-trip through Codable")
    func installEventCodec() throws {
        let cases: [UpdaterEvent] = [
            .installCommitted,
            .installSucceeded,
            .installFailed(code: "STATUS_FAILURE_ABORTED", message: "user cancelled"),
            .installFailed(code: "STATUS_FAILURE_STORAGE", message: nil)
        ]
        for event in cases {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(UpdaterEvent.self, from: data)
            #expect(decoded == event, "round-trip mismatch for \(event)")
        }
    }

    @Test("installFailed wire shape matches the documented JS contract")
    func installFailedWire() throws {
        let event = UpdaterEvent.installFailed(code: "STATUS_FAILURE_ABORTED", message: "user cancelled")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        #expect(json?["type"] as? String == "installFailed")
        #expect(json?["code"] as? String == "STATUS_FAILURE_ABORTED")
        #expect(json?["message"] as? String == "user cancelled")
    }

    @Test("installFailed with a nil message omits the key on the wire")
    func installFailedNilMessage() throws {
        let event = UpdaterEvent.installFailed(code: "STATUS_FAILURE_STORAGE", message: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        #expect(json?["type"] as? String == "installFailed")
        #expect(json?["code"] as? String == "STATUS_FAILURE_STORAGE")
        #expect(json?["message"] == nil, "nil message should be omitted, not serialized as null")
    }

    // MARK: - helpers

    private func collectRun(
        app: MockAppContext,
        args: String,
        expectError: Bool = false
    ) async throws -> [UpdaterEvent] {
        try await collectStream(app: app, command: "updater.run", args: args, expectError: expectError)
    }

    private func collectInstall(
        app: MockAppContext,
        expectError: Bool = false
    ) async throws -> [UpdaterEvent] {
        try await collectStream(app: app, command: "updater.install", args: "{}", expectError: expectError)
    }

    private func collectStream(
        app: MockAppContext,
        command: String,
        args: String,
        expectError: Bool
    ) async throws -> [UpdaterEvent] {
        let inv = Invocation(id: 1, command: command, payload: Data(args.utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .stream(stream) = result else {
            Issue.record("expected stream result for \(command)")
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

/// Thread-safe payload collector for `EventBus` sinks (which are
/// `@Sendable` and may run off the test's actor).
private final class Captured<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.withLock { storage.append(value) } }
    var values: [T] {
        lock.withLock { storage }
    }
}
