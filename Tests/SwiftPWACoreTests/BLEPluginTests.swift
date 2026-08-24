import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - A peripheral that does what the test tells it to

private final class FakeLink: BluetoothLink, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<BLELinkEvent, any Error>.Continuation?
    private(set) var writes: [(characteristic: String, value: Data, withResponse: Bool)] = []
    private(set) var notifying: [String: Bool] = [:]
    private(set) var disconnectCount = 0
    /// Set to make the next operation fail, the way a peripheral rejects a
    /// write to a characteristic it doesn't have.
    var failWith: BLEError?

    func events() -> AsyncThrowingStream<BLELinkEvent, any Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func emit(_ event: BLELinkEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }

    func write(characteristic: String, value: Data, withResponse: Bool) async throws {
        if let failWith { throw failWith }
        lock.withLock { writes.append((characteristic, value, withResponse)) }
    }

    func read(characteristic _: String) async throws -> Data {
        if let failWith { throw failWith }
        return Data("hello".utf8)
    }

    func setNotify(characteristic: String, enabled: Bool) async throws {
        if let failWith { throw failWith }
        lock.withLock { notifying[characteristic] = enabled }
    }

    func disconnect() async {
        lock.withLock { disconnectCount += 1 }
    }
}

private final class FakeCentral: BluetoothCentral, @unchecked Sendable {
    let link = FakeLink()
    private let lock = NSLock()
    var availabilityResult = BLEAvailability.available
    private(set) var scanFilter: BLEScanFilter?
    private(set) var scanStopped = false
    /// Advertisements handed out by a scan, then the stream stays open so a
    /// test can watch teardown rather than racing a finished stream.
    var advertisements: [BLEAdvertisement] = []
    /// Set to make `connect` never return `ready`, for the timeout path.
    var connectHangs = false

    func availability() async -> BLEAvailability { availabilityResult }

    func scan(_ filter: BLEScanFilter) -> AsyncThrowingStream<BLEAdvertisement, any Error> {
        lock.withLock { scanFilter = filter }
        return AsyncThrowingStream { continuation in
            for advertisement in advertisements { continuation.yield(advertisement) }
            continuation.onTermination = { [self] _ in lock.withLock { scanStopped = true } }
        }
    }

    func connect(_: String) async throws -> any BluetoothLink {
        if !connectHangs {
            // Real backends discover asynchronously, so `ready` lands after
            // the caller has subscribed rather than during `connect`.
            Task { [link] in
                try? await Task.sleep(for: .milliseconds(5))
                link.emit(.ready(services: [
                    BLEService(uuid: try! BLEUUID.require("ffe0"), characteristics: [
                        BLECharacteristic(uuid: try! BLEUUID.require("ffe1"), properties: ["write", "notify"])
                    ])
                ]))
            }
        }
        return link
    }
}

/// What JS actually posts into an open session — a plain object, not an
/// encoded `BLECommand` (which is decode-only, since nothing in the runtime
/// ever sends one).
private struct Push: Encodable {
    var kind: String
    var characteristic: String
    var valueBase64: String?
    var withResponse: Bool?
    var token: Int?
}

// MARK: -

@Suite("ble.* plugin")
@MainActor
struct BLEPluginTests {
    private func setUp(
        _ central: FakeCentral, declare: Bool = true
    ) -> (MockAppContext, MockWindow, MockWebView, BridgeRuntime) {
        let app = MockAppContext()
        if declare { app.permissions.declare(.bluetooth) }
        let webView = MockWebView()
        let win = MockWindow(webView: webView)
        app.attach(win)
        BLEPlugin(central).register(into: app.registry, app: app)
        let bridge = BridgeRuntime(webView: webView, registry: app.registry, windowID: win.id, app: app)
        bridge.start()
        return (app, win, webView, bridge)
    }

    private func events(_ webView: MockWebView, id: UInt64) -> [[String: Any]] {
        webView.deliveredFrames.compactMap { frame in
            guard case let .event(eventID, data, _) = frame, eventID == id else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func error(_ webView: MockWebView, id: UInt64) -> BridgeError? {
        webView.deliveredFrames.compactMap { frame in
            if case let .replyError(errorID, error, _) = frame, errorID == id { return error }
            return nil
        }.first
    }

    // MARK: - The gate

    @Test("an undeclared app is refused before the radio is touched")
    func undeclaredIsRefused() async throws {
        let central = FakeCentral()
        let (app, win, webView, bridge) = setUp(central, declare: false)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.scan", payload: BLEScanFilter())
        try await waitFor { error(webView, id: 1) != nil }
        #expect(error(webView, id: 1)?.code == "E_BLE_DENIED")
        // Not a scan that finds nothing: the radio is never asked.
        #expect(central.scanFilter == nil)
    }

    @Test("the app's own veto refuses it too, distinguishably")
    func vetoIsRefused() async throws {
        let central = FakeCentral()
        let (app, win, webView, bridge) = setUp(central)
        app.permissions.setVeto { permission, _ in permission == .bluetooth }
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.scan", payload: BLEScanFilter())
        try await waitFor { error(webView, id: 1) != nil }
        #expect(error(webView, id: 1)?.message.contains("turned Bluetooth off") == true)
    }

    // MARK: - Scanning

    @Test("an adapter that's switched off is a stated failure, not an empty list")
    func unavailableAdapterFails() async throws {
        let central = FakeCentral()
        central.availabilityResult = BLEAvailability(isAvailable: false, reason: "Bluetooth is switched off")
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        // A scan on a disabled adapter succeeds and finds nothing, which a page
        // can't tell from "no peripherals nearby" — so the plugin checks first.
        try webView.sendSubscribe(id: 1, command: "ble.scan", payload: BLEScanFilter())
        try await waitFor { error(webView, id: 1) != nil }
        let failure = try #require(error(webView, id: 1))
        #expect(failure.code == "E_BLE_UNAVAILABLE")
        #expect(failure.message.contains("switched off"))
    }

    @Test("scan filters are canonicalized, so 'ffe0' reaches the backend as a UUID")
    func scanCanonicalizesFilters() async throws {
        let central = FakeCentral()
        central.advertisements = [BLEAdvertisement(id: "peripheral-1", name: "Plotter-7", timestamp: 0)]
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.scan", payload: BLEScanFilter(services: ["FFE0"]))
        try await waitFor { !events(webView, id: 1).isEmpty }
        #expect(central.scanFilter?.services == ["0000ffe0-0000-1000-8000-00805f9b34fb"])
        #expect(events(webView, id: 1).first?["name"] as? String == "Plotter-7")
    }

    @Test("a UUID that isn't one fails the scan instead of matching nothing")
    func badUUIDIsRefused() async throws {
        let central = FakeCentral()
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.scan", payload: BLEScanFilter(services: ["not-a-uuid"]))
        try await waitFor { error(webView, id: 1) != nil }
        #expect(error(webView, id: 1)?.message.contains("not-a-uuid") == true)
        #expect(central.scanFilter == nil)
    }

    @Test("unsubscribing stops the radio, not just the delivery")
    func unsubscribeStopsScanning() async throws {
        let central = FakeCentral()
        central.advertisements = [BLEAdvertisement(id: "peripheral-1", timestamp: 0)]
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.scan", payload: BLEScanFilter())
        try await waitFor { !events(webView, id: 1).isEmpty }
        try webView.sendUnsubscribe(id: 1)
        try await waitFor { central.scanStopped }
    }

    // MARK: - The link

    @Test("connect yields ready, and a push reaches the peripheral")
    func connectAndWrite() async throws {
        let central = FakeCentral()
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.connect", payload: BLEConnectRequest(id: "peripheral-1"))
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "ready" } }

        try webView.sendPush(id: 1, payload: Push(
            kind: "write", characteristic: "ffe1",
            valueBase64: Data([0x1, 0x2]).base64EncodedString(), withResponse: true, token: 7
        ))
        try await waitFor { !central.link.writes.isEmpty }
        let write = try #require(central.link.writes.first)
        // Canonicalized on the way in as well as out, so a page can push the
        // short form it read off a datasheet.
        #expect(write.characteristic == "0000ffe1-0000-1000-8000-00805f9b34fb")
        #expect(write.value == Data([0x1, 0x2]))

        // `withResponse` means the peripheral acknowledged, and the token is
        // the only way the page can tell which write it acknowledged.
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "ack" } }
        let ack = try #require(events(webView, id: 1).first { $0["kind"] as? String == "ack" })
        #expect(ack["token"] as? Int == 7)
    }

    @Test("a notification arrives as base64, under its canonical UUID")
    func notificationsFlow() async throws {
        let central = FakeCentral()
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.connect", payload: BLEConnectRequest(id: "peripheral-1"))
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "ready" } }

        try central.link.emit(.notify(characteristic: BLEUUID.require("ffe1"), value: Data("hi".utf8)))
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "notify" } }
        let notify = try #require(events(webView, id: 1).first { $0["kind"] as? String == "notify" })
        #expect(notify["value"] as? String == Data("hi".utf8).base64EncodedString())
        #expect(notify["characteristic"] as? String == "0000ffe1-0000-1000-8000-00805f9b34fb")
    }

    @Test("a rejected write reports failure without costing the page its link")
    func failedWriteKeepsTheSession() async throws {
        let central = FakeCentral()
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.connect", payload: BLEConnectRequest(id: "peripheral-1"))
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "ready" } }

        central.link.failWith = .gatt("that characteristic isn't writable")
        try webView.sendPush(id: 1, payload: Push(
            kind: "write", characteristic: "ffe1",
            valueBase64: "", withResponse: true, token: 3
        ))
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "failed" } }
        let failure = try #require(events(webView, id: 1).first { $0["kind"] as? String == "failed" })
        #expect(failure["token"] as? Int == 3)
        #expect(failure["message"] as? String == "that characteristic isn't writable")

        // The session is still open: an error frame would have ended it, which
        // is why a failed operation is a downstream event instead.
        central.link.failWith = nil
        try webView.sendPush(id: 1, payload: Push(
            kind: "write", characteristic: "ffe1", valueBase64: Data([0x9]).base64EncodedString()
        ))
        try await waitFor { central.link.writes.contains { $0.value == Data([0x9]) } }
    }

    @Test("a drop doesn't end the session — the backend keeps trying")
    func dropKeepsTheSessionOpen() async throws {
        let central = FakeCentral()
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.connect", payload: BLEConnectRequest(id: "peripheral-1"))
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "ready" } }

        // The shape this API exists for is a machine that browns out mid-job.
        // Forcing the page back through discovery for that would be worse than
        // what the platforms give you.
        central.link.emit(.state(connected: false, reason: "out of range"))
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "state" } }
        #expect(!webView.deliveredFrames.contains { frame in
            if case let .end(id, _) = frame, id == 1 { return true }
            return false
        })

        central.link.emit(.ready(services: []))
        try await waitFor { events(webView, id: 1).count(where: { $0["kind"] as? String == "ready" }) == 2 }
    }

    @Test("closing the session disconnects the peripheral")
    func closingDisconnects() async throws {
        let central = FakeCentral()
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(id: 1, command: "ble.connect", payload: BLEConnectRequest(id: "peripheral-1"))
        try await waitFor { events(webView, id: 1).contains { $0["kind"] as? String == "ready" } }

        // Most peripherals accept one central at a time, so a link left open
        // locks everyone else out — including this app's next run.
        try webView.sendUnsubscribe(id: 1)
        try await waitFor { central.link.disconnectCount > 0 }
    }

    @Test("a peripheral that never finishes connecting times out")
    func connectTimesOut() async throws {
        let central = FakeCentral()
        central.connectHangs = true
        let (app, win, webView, bridge) = setUp(central)
        defer { bridge.stop() }
        withExtendedLifetime((app, win)) {}

        try webView.sendSubscribe(
            id: 1, command: "ble.connect", payload: BLEConnectRequest(id: "peripheral-1", timeoutMs: 60)
        )
        try await waitFor { error(webView, id: 1) != nil }
        #expect(error(webView, id: 1)?.code == "E_BLE_TIMEOUT")
        try await waitFor { central.link.disconnectCount > 0 }
    }
}
