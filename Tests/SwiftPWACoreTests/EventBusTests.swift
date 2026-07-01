import Foundation
@testable import SwiftPWACore
import Testing

/// Thread-safe collector for the bus's `@Sendable (Data) -> Void` sink, since
/// a sink closure can't capture a mutable local under strict concurrency.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []

    var sink: @Sendable (Data) -> Void {
        { [self] data in lock.withLock { items.append(data) } }
    }

    var strings: [String] {
        lock.withLock { items.map { String(decoding: $0, as: UTF8.self) } }
    }

    var count: Int {
        lock.withLock { items.count }
    }
}

@Suite("EventBus")
struct EventBusTests {
    @Test("emit reaches a current subscriber")
    func emitReaches() {
        let bus = EventBus()
        let c = Collector()
        _ = bus.subscribe("chan", c.sink)
        bus.emit("chan", payload: Data("\"hi\"".utf8))
        #expect(c.strings == ["\"hi\""])
    }

    @Test("emit fans out to every subscriber on the channel")
    func fanOut() {
        let bus = EventBus()
        let a = Collector(), b = Collector()
        _ = bus.subscribe("chan", a.sink)
        _ = bus.subscribe("chan", b.sink)
        bus.emit("chan", payload: Data("1".utf8))
        #expect(a.strings == ["1"])
        #expect(b.strings == ["1"])
    }

    @Test("emit is scoped to its channel")
    func channelScoping() {
        let bus = EventBus()
        let a = Collector(), b = Collector()
        _ = bus.subscribe("a", a.sink)
        _ = bus.subscribe("b", b.sink)
        bus.emit("a", payload: Data("x".utf8))
        #expect(a.count == 1)
        #expect(b.count == 0)
    }

    @Test("without retain, a late subscriber misses earlier events")
    func noRetainMissesHistory() {
        let bus = EventBus()
        bus.emit("chan", payload: Data("early".utf8))
        let c = Collector()
        _ = bus.subscribe("chan", c.sink)
        #expect(c.count == 0)
    }

    @Test("retained latest value replays to a late subscriber")
    func retainReplays() {
        let bus = EventBus()
        bus.emit("status", payload: Data("\"ready\"".utf8), retain: true)
        let c = Collector()
        _ = bus.subscribe("status", c.sink)
        #expect(c.strings == ["\"ready\""])
    }

    @Test("retain keeps only the latest value")
    func retainKeepsLatest() {
        let bus = EventBus()
        bus.emit("status", payload: Data("1".utf8), retain: true)
        bus.emit("status", payload: Data("2".utf8), retain: true)
        let c = Collector()
        _ = bus.subscribe("status", c.sink)
        #expect(c.strings == ["2"])
    }

    @Test("clearRetained stops future replay")
    func clearRetained() {
        let bus = EventBus()
        bus.emit("status", payload: Data("1".utf8), retain: true)
        bus.clearRetained("status")
        let c = Collector()
        _ = bus.subscribe("status", c.sink)
        #expect(c.count == 0)
    }

    @Test("cancel deregisters the subscriber")
    func cancelDeregisters() {
        let bus = EventBus()
        let c = Collector()
        let sub = bus.subscribe("chan", c.sink)
        #expect(bus.subscriberCount("chan") == 1)
        sub.cancel()
        #expect(bus.subscriberCount("chan") == 0)
        bus.emit("chan", payload: Data("after".utf8))
        #expect(c.count == 0)
    }

    @Test("cancel is idempotent")
    func cancelIdempotent() {
        let bus = EventBus()
        let sub = bus.subscribe("chan") { _ in }
        sub.cancel()
        sub.cancel() // must not crash or underflow
        #expect(bus.subscriberCount("chan") == 0)
    }

    @Test("typed Encodable emit encodes to JSON")
    func typedEmit() throws {
        struct Payload: Codable { let path: String }
        let bus = EventBus()
        let c = Collector()
        _ = bus.subscribe("files", c.sink)
        try bus.emit("files", Payload(path: "/tmp/a"))
        let decoded = try JSONDecoder().decode(Payload.self, from: Data(c.strings[0].utf8))
        #expect(decoded.path == "/tmp/a")
    }
}
