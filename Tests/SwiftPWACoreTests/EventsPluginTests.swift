import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("EventsPlugin")
@MainActor
struct EventsPluginTests {
    private func makeApp() -> MockAppContext {
        let app = MockAppContext()
        app.use(EventsPlugin())
        return app
    }

    private func dispatch(
        _ command: String,
        _ payload: [String: Any],
        on app: MockAppContext
    ) async -> InvocationResult {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let inv = Invocation(id: 1, command: command, payload: data)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    /// Open an `events.subscribe` stream. The bus subscription is registered
    /// synchronously during dispatch (the `AsyncThrowingStream` builder runs
    /// eagerly), so emits issued *after* this returns are guaranteed to be
    /// observed. Callers make the iterator inline so it stays in a fresh
    /// isolation region (returning an iterator across the `await` boundary would
    /// taint it main-actor-isolated and trip `sending`).
    private func openStream(
        channel: String,
        on app: MockAppContext
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        let result = await dispatch("events.subscribe", ["channel": channel], on: app)
        guard case let .stream(stream) = result else {
            throw BridgeError(code: "TEST", message: "expected a stream")
        }
        return stream
    }

    private func object(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    @Test("events.emit from JS reaches an events.subscribe stream")
    func emitToSubscribe() async throws {
        let app = makeApp()
        let stream = try await openStream(channel: "greetings", on: app)
        var iter = stream.makeAsyncIterator()
        _ = await dispatch("events.emit", ["channel": "greetings", "payload": ["hi": true]], on: app)
        let chunk = try await iter.next()
        #expect(object(chunk)?["hi"] as? Bool == true)
    }

    @Test("Swift-side ctx.emit reaches a subscriber")
    func swiftEmitReaches() async throws {
        struct Job: Codable { let done: Bool }
        let app = makeApp()
        let stream = try await openStream(channel: "jobs", on: app)
        var iter = stream.makeAsyncIterator()
        try app.emit("jobs", Job(done: true))
        let chunk = try await iter.next()
        #expect(object(chunk)?["done"] as? Bool == true)
    }

    @Test("emit fans out to subscribers across separate streams (multi-window)")
    func fanOutAcrossStreams() async throws {
        let app = makeApp()
        let streamA = try await openStream(channel: "bus", on: app)
        let streamB = try await openStream(channel: "bus", on: app)
        var a = streamA.makeAsyncIterator()
        var b = streamB.makeAsyncIterator()
        _ = await dispatch("events.emit", ["channel": "bus", "payload": 7], on: app)
        let ca = try await a.next()
        let cb = try await b.next()
        #expect(String(decoding: ca ?? Data(), as: UTF8.self) == "7")
        #expect(String(decoding: cb ?? Data(), as: UTF8.self) == "7")
    }

    @Test("a retained channel replays its latest value on subscribe")
    func retainedReplay() async throws {
        let app = makeApp()
        _ = await dispatch(
            "events.emit",
            ["channel": "status", "payload": "ready", "retain": true],
            on: app
        )
        let stream = try await openStream(channel: "status", on: app)
        var iter = stream.makeAsyncIterator()
        let chunk = try await iter.next()
        #expect(String(decoding: chunk ?? Data(), as: UTF8.self) == "\"ready\"")
    }

    @Test("events.emit without a channel fails to decode")
    func emitRequiresChannel() async {
        let app = makeApp()
        let result = await dispatch("events.emit", ["payload": 1], on: app)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.decode)
    }

    @Test("EventsPlugin is auto-installable and reports its name")
    func pluginName() {
        let app = makeApp()
        #expect(app.installedPlugins.contains("events"))
    }

    @Test("a payload-less signal delivers null")
    func signalDeliversNull() async throws {
        let app = makeApp()
        let stream = try await openStream(channel: "ping", on: app)
        var iter = stream.makeAsyncIterator()
        app.emit("ping")
        let chunk = try await iter.next()
        #expect(String(decoding: chunk ?? Data(), as: UTF8.self) == "null")
    }
}
