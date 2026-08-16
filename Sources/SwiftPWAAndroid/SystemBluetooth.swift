#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `BluetoothLeScanner` / `BluetoothGatt`-backed ``BluetoothCentral``, over
    /// the Kotlin RPC bridge.
    ///
    /// Android needs the OS runtime permission on top of the app's own
    /// declaration and only an Activity can ask for it, so the Kotlin side
    /// requests it — reusing the launcher the WebView capture path already
    /// owns, since only one runtime request can be in flight at a time.
    ///
    /// The peripheral `id` here is a Bluetooth address (`AA:BB:…`), not the
    /// per-host UUID Apple hands out. Both are opaque to a page, which is why
    /// the contract says so.
    public final class SystemBluetooth: BluetoothCentral, @unchecked Sendable {
        public init() {}

        public func availability() async -> BLEAvailability {
            guard let availability: BLEAvailability = try? await AndroidRPC.call(
                "ble.availability", [String: String]()
            ) else {
                return BLEAvailability(isAvailable: false, reason: "the Bluetooth adapter could not be reached")
            }
            return availability
        }

        public func scan(_ filter: BLEScanFilter) -> AsyncThrowingStream<BLEAdvertisement, any Error> {
            AsyncThrowingStream { continuation in
                let channel = "ble.scan.\(UUID().uuidString)"
                struct Update: Decodable {
                    var advertisement: BLEAdvertisement?
                    /// The scan couldn't start. Reported on the channel rather
                    /// than as an RPC failure because `startScan` is void and
                    /// only tells you through its callback.
                    var failed: String?
                }
                AndroidHostEventRouter.subscribe(channel: channel) { data in
                    guard let update = try? JSONDecoder().decode(Update.self, from: data) else { return }
                    if let failure = update.failed {
                        continuation.finish(throwing: BLEError.unavailable(failure).bridgeError)
                        return
                    }
                    guard var advertisement = update.advertisement else { return }
                    // Canonicalized here rather than in Kotlin: one place
                    // decides what a UUID looks like on the wire.
                    advertisement.services = advertisement.services.compactMap(BLEUUID.canonical)
                    continuation.yield(advertisement)
                }

                let task = Task {
                    do {
                        let reply: Reply = try await AndroidRPC.call("ble.scan.start", ScanArgs(
                            channel: channel, services: filter.services, namePrefix: filter.namePrefix
                        ))
                        guard reply.ok else { throw Self.error(from: reply).bridgeError }
                    } catch {
                        AndroidHostEventRouter.unsubscribe(channel: channel)
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { _ in
                    AndroidHostEventRouter.unsubscribe(channel: channel)
                    task.cancel()
                    // Fire-and-forget: nobody is left to report to, but the
                    // radio has to stop.
                    Task { _ = try? await AndroidRPC.call("ble.scan.stop", [String: String](), as: Reply.self) }
                }
            }
        }

        public func connect(_ id: String) async throws -> any BluetoothLink {
            let channel = "ble.link.\(UUID().uuidString)"
            let link = AndroidBluetoothLink(id: id, channel: channel)
            let reply: Reply = try await AndroidRPC.call(
                "ble.connect", ConnectArgs(id: id, channel: channel)
            )
            guard reply.ok else {
                link.tearDown()
                throw Self.error(from: reply)
            }
            return link
        }

        // MARK: - Wire

        private struct ScanArgs: Encodable {
            var channel: String
            var services: [String]
            var namePrefix: String?
        }

        private struct ConnectArgs: Encodable {
            var id: String
            var channel: String
        }

        /// Kotlin answers with a classified failure rather than a bare string,
        /// so the `BLEError` cases survive the trip instead of being re-derived
        /// by sniffing a message.
        struct Reply: Decodable {
            var ok: Bool
            var kind: String?
            var message: String?
            var valueBase64: Data?
        }

        static func error(from reply: Reply) -> BLEError {
            let message = reply.message ?? "the Bluetooth operation failed"
            return switch reply.kind {
            case "denied": .denied(message)
            case "notFound": .notFound(message)
            case "gatt": .gatt(message)
            case "disconnected": .disconnected(message)
            default: .unavailable(message)
            }
        }
    }

    /// One GATT connection, addressed by the peripheral's Bluetooth address.
    ///
    /// The Kotlin side owns the queue that serialises GATT operations (Android
    /// allows one outstanding request per connection), so this is a thin
    /// translation layer: each method is one RPC, and the peripheral's own
    /// traffic arrives on the host-event channel.
    final class AndroidBluetoothLink: BluetoothLink, @unchecked Sendable {
        private let id: String
        private let channel: String
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<BLELinkEvent, any Error>.Continuation?
        private var buffered: [BLELinkEvent] = []

        init(id: String, channel: String) {
            self.id = id
            self.channel = channel
            AndroidHostEventRouter.subscribe(channel: channel) { [weak self] data in
                guard let self, let event = Self.decode(data) else { return }
                deliver(event)
            }
        }

        func events() -> AsyncThrowingStream<BLELinkEvent, any Error> {
            AsyncThrowingStream { continuation in
                lock.lock()
                self.continuation = continuation
                let pending = buffered
                buffered = []
                lock.unlock()
                // Discovery can finish before the plugin subscribes, and a
                // dropped `ready` leaves the page waiting for a link that is in
                // fact usable.
                for event in pending { continuation.yield(event) }
            }
        }

        func write(characteristic: String, value: Data, withResponse: Bool) async throws {
            let reply: SystemBluetooth.Reply = try await AndroidRPC.call("ble.write", WriteArgs(
                id: id, characteristic: characteristic,
                valueBase64: value, withResponse: withResponse
            ))
            guard reply.ok else { throw SystemBluetooth.error(from: reply) }
        }

        func read(characteristic: String) async throws -> Data {
            let reply: SystemBluetooth.Reply = try await AndroidRPC.call("ble.read", CharacteristicArgs(
                id: id, characteristic: characteristic, enabled: nil
            ))
            guard reply.ok, let value = reply.valueBase64 else { throw SystemBluetooth.error(from: reply) }
            return value
        }

        func setNotify(characteristic: String, enabled: Bool) async throws {
            let reply: SystemBluetooth.Reply = try await AndroidRPC.call("ble.setNotify", CharacteristicArgs(
                id: id, characteristic: characteristic, enabled: enabled
            ))
            guard reply.ok else { throw SystemBluetooth.error(from: reply) }
        }

        func disconnect() async {
            tearDown()
            _ = try? await AndroidRPC.call("ble.disconnect", ["id": id], as: SystemBluetooth.Reply.self)
        }

        func tearDown() {
            AndroidHostEventRouter.unsubscribe(channel: channel)
            lock.withLock {
                continuation?.finish()
                continuation = nil
            }
        }

        /// Deliberately not `lock.withLock { guard let … }`: that form crashes
        /// SILGen on the Swift 6.2 toolchain the Android SDK pins ("memory is
        /// not initialized, but should be"), while compiling fine on a newer
        /// host compiler. Taking a copy and yielding outside the lock is the
        /// better shape anyway — a subscriber's `yield` shouldn't run with the
        /// link's lock held.
        private func deliver(_ event: BLELinkEvent) {
            lock.lock()
            let target = continuation
            if target == nil { buffered.append(event) }
            lock.unlock()
            target?.yield(event)
        }

        /// Kotlin sends the same `kind`-tagged shape the bridge carries
        /// downstream, so this decodes rather than re-derives it.
        private static func decode(_ data: Data) -> BLELinkEvent? {
            struct Wire: Decodable {
                var kind: String
                var services: [BLEService]?
                var characteristic: String?
                var value: Data?
                var connected: Bool?
                var reason: String?
            }
            guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
            switch wire.kind {
            case "ready":
                return .ready(services: (wire.services ?? []).map(canonicalized))
            case "notify":
                guard let characteristic = wire.characteristic.flatMap(BLEUUID.canonical),
                      let value = wire.value else { return nil }
                return .notify(characteristic: characteristic, value: value)
            case "state":
                return .state(connected: wire.connected ?? false, reason: wire.reason)
            default:
                return nil
            }
        }

        private static func canonicalized(_ service: BLEService) -> BLEService {
            BLEService(
                uuid: BLEUUID.canonical(service.uuid) ?? service.uuid,
                isPrimary: service.isPrimary,
                characteristics: service.characteristics.map {
                    BLECharacteristic(uuid: BLEUUID.canonical($0.uuid) ?? $0.uuid, properties: $0.properties)
                }
            )
        }

        private struct WriteArgs: Encodable {
            var id: String
            var characteristic: String
            var valueBase64: Data
            var withResponse: Bool
        }

        private struct CharacteristicArgs: Encodable {
            var id: String
            var characteristic: String
            var enabled: Bool?
        }
    }
#endif
