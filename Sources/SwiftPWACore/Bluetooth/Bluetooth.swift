import Foundation

/// Talking to Bluetooth LE peripherals, in the central role.
///
/// Unlike `net.*` — which buys CORS-freedom and header control over something
/// the page already has — this is the difference between a capability existing
/// and not existing. Web Bluetooth has never shipped in WKWebView or Safari,
/// and Android's embedded `WebView` doesn't expose it either (Chrome does).
/// There is no polyfill and no degraded path, so `ble.*` is the only way a
/// page in this shell reaches a peripheral at all.
///
/// Central role only: this scans for, connects to and talks to peripherals. It
/// does not advertise. See `docs/bluetooth.md` for what that rules out.
public protocol BluetoothCentral: AnyObject, Sendable {
    /// Whether this machine can do Bluetooth *right now*.
    ///
    /// Checked before a scan so the page can say "turn Bluetooth on" instead of
    /// showing an empty device list forever — an adapter that's switched off
    /// scans perfectly happily and finds nothing.
    func availability() async -> BLEAvailability

    /// Peripherals as they're discovered. Raw, not de-duplicated: watching RSSI
    /// settle is how a device picker gets built, and a de-duplicating scan has
    /// thrown away information the page can't recover.
    ///
    /// The stream ends when the subscriber stops, which must stop the radio
    /// scanning — a scan left running is a battery drain the page can no longer
    /// see.
    func scan(_ filter: BLEScanFilter) -> AsyncThrowingStream<BLEAdvertisement, any Error>

    /// Open a link to a peripheral. Returns once the platform has accepted the
    /// request; the link is usable when it emits ``BLELinkEvent/ready``.
    func connect(_ id: String) async throws -> any BluetoothLink
}

/// One open connection to a peripheral.
///
/// A link **survives a drop**. The peripheral going out of range emits
/// `state(connected: false)` and the backend keeps trying, because the shape
/// this exists for is a machine that browns out mid-job — forcing the page back
/// through discovery for that would be a worse API than the platforms'. The
/// page decides when to give up, by closing.
public protocol BluetoothLink: AnyObject, Sendable {
    /// Everything the peripheral says, until the link is closed. Call once —
    /// the link has one event source, not one per caller.
    func events() -> AsyncThrowingStream<BLELinkEvent, any Error>

    /// Write to a characteristic. `withResponse` asks the peripheral to
    /// acknowledge; without it the write is fire-and-forget and much faster,
    /// which is how bulk-ish transfers to a device are normally paced.
    func write(characteristic: String, value: Data, withResponse: Bool) async throws

    func read(characteristic: String) async throws -> Data

    /// Start or stop notifications (or indications — the platform picks
    /// whichever the characteristic supports) for a characteristic.
    func setNotify(characteristic: String, enabled: Bool) async throws

    /// Disconnect and release the platform handles. Idempotent.
    func disconnect() async
}

// MARK: - Wire types

/// Why a scan would find nothing.
public struct BLEAvailability: Sendable, Codable, Equatable {
    /// Ready to scan.
    public var isAvailable: Bool
    /// A sentence for the user when it isn't — "Bluetooth is switched off",
    /// "this machine has no Bluetooth adapter", "bluetoothd isn't running".
    /// Never "this platform doesn't support Bluetooth": every platform here
    /// does, and saying otherwise sends the user looking for a different app.
    public var reason: String?

    public init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = reason
    }

    public static let available = BLEAvailability(isAvailable: true)
}

public struct BLEScanFilter: Sendable, Codable, Equatable {
    /// Advertised service UUIDs to match. Empty scans everything, which is
    /// slower to sift and, on some platforms, finds fewer peripherals — a
    /// peripheral only appears in a filtered scan if it advertises the service,
    /// and plenty only mention their services after you connect.
    public var services: [String]
    /// Case-sensitive prefix match on the advertised name.
    public var namePrefix: String?
    /// Stop scanning after this long. Nil scans until the subscriber stops.
    public var timeoutMs: Int?

    public init(services: [String] = [], namePrefix: String? = nil, timeoutMs: Int? = nil) {
        self.services = services
        self.namePrefix = namePrefix
        self.timeoutMs = timeoutMs
    }

    /// Hand-written so every field is optional on the wire — `ble.scan` with no
    /// arguments is the natural way to ask "what's out there".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        services = try container.decodeIfPresent([String].self, forKey: .services) ?? []
        namePrefix = try container.decodeIfPresent(String.self, forKey: .namePrefix)
        timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
    }

    /// The same filter with every UUID in canonical form, or a thrown error
    /// naming the one that isn't a UUID.
    public func canonicalized() throws -> BLEScanFilter {
        try BLEScanFilter(
            services: services.map { try BLEUUID.require($0) },
            namePrefix: namePrefix,
            timeoutMs: timeoutMs
        )
    }
}

public struct BLEAdvertisement: Sendable, Codable, Equatable {
    /// What to pass to `ble.connect`.
    ///
    /// **Opaque, and local to this machine.** Apple hands out a per-host UUID
    /// that deliberately isn't the peripheral's address; the other three use
    /// the Bluetooth address. So it's stable enough to reconnect to later on
    /// the same device, and meaningless anywhere else — don't parse it, don't
    /// sync it between a user's machines.
    public var id: String
    public var name: String?
    /// Signal strength in dBm (negative; closer to zero is nearer). Nil when
    /// the platform didn't report one for this advertisement.
    public var rssi: Int?
    /// Service UUIDs from the advertisement, canonical form.
    public var services: [String]
    /// The manufacturer-specific advertisement field, which is where a device
    /// that identifies itself without connecting puts it.
    public var manufacturerData: Data?
    /// Whether the advertisement says a connection would be accepted. Nil where
    /// the platform doesn't say.
    public var isConnectable: Bool?
    /// Seconds since 1970, matching every other time value the bridge carries.
    public var timestamp: Double

    public init(
        id: String,
        name: String? = nil,
        rssi: Int? = nil,
        services: [String] = [],
        manufacturerData: Data? = nil,
        isConnectable: Bool? = nil,
        timestamp: Double
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.services = services
        self.manufacturerData = manufacturerData
        self.isConnectable = isConnectable
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id, name, rssi, services
        // Named for its encoding, because that's what a JS caller receives:
        // JSONEncoder writes `Data` as base64, and a field called
        // `manufacturerData` holding a base64 string would be a small lie.
        case manufacturerData = "manufacturerDataBase64"
        case isConnectable, timestamp
    }
}

/// A service and the characteristics discovered on it.
public struct BLEService: Sendable, Codable, Equatable {
    public var uuid: String
    public var isPrimary: Bool
    public var characteristics: [BLECharacteristic]

    public init(uuid: String, isPrimary: Bool = true, characteristics: [BLECharacteristic] = []) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }
}

public struct BLECharacteristic: Sendable, Codable, Equatable {
    public var uuid: String
    /// What the peripheral says it supports: `read`, `write`,
    /// `writeWithoutResponse`, `notify`, `indicate`.
    ///
    /// Worth surfacing rather than swallowing: writing to a characteristic that
    /// only supports `writeWithoutResponse` with `withResponse: true` fails on
    /// every platform, with four different messages.
    public var properties: [String]

    public init(uuid: String, properties: [String] = []) {
        self.uuid = uuid
        self.properties = properties
    }
}

/// Everything a link reports, as one `kind`-tagged union — the shape the bridge
/// session carries downstream.
public enum BLELinkEvent: Sendable, Equatable {
    /// Connected and discovered. Emitted again after a reconnect, because
    /// handles don't survive a drop and the services genuinely may have
    /// changed.
    case ready(services: [BLEService])
    /// A notification or indication.
    case notify(characteristic: String, value: Data)
    /// The answer to a `read` push.
    case read(characteristic: String, value: Data, token: Int?)
    /// A `write` that the peripheral acknowledged, or a `subscribe` that took
    /// effect. Only ever sent for a push that carried a `token`.
    case ack(token: Int)
    /// Connected or dropped. A drop is not the end of the session: the backend
    /// keeps trying until the page closes it.
    case state(connected: Bool, reason: String?)
    /// One operation failed. Deliberately *not* an error on the stream, which
    /// would tear the whole session down — a rejected write shouldn't cost the
    /// page its connection.
    case failed(message: String, characteristic: String?, token: Int?)

    private enum CodingKeys: String, CodingKey {
        case kind, services, characteristic, value, token, connected, reason, message
    }
}

extension BLELinkEvent: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ready(services):
            try container.encode("ready", forKey: .kind)
            try container.encode(services, forKey: .services)
        case let .notify(characteristic, value):
            try container.encode("notify", forKey: .kind)
            try container.encode(characteristic, forKey: .characteristic)
            try container.encode(value, forKey: .value)
        case let .read(characteristic, value, token):
            try container.encode("read", forKey: .kind)
            try container.encode(characteristic, forKey: .characteristic)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(token, forKey: .token)
        case let .ack(token):
            try container.encode("ack", forKey: .kind)
            try container.encode(token, forKey: .token)
        case let .state(connected, reason):
            try container.encode("state", forKey: .kind)
            try container.encode(connected, forKey: .connected)
            try container.encodeIfPresent(reason, forKey: .reason)
        case let .failed(message, characteristic, token):
            try container.encode("failed", forKey: .kind)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(characteristic, forKey: .characteristic)
            try container.encodeIfPresent(token, forKey: .token)
        }
    }
}

/// What a page pushes into an open link.
public enum BLECommand: Sendable, Equatable {
    case write(characteristic: String, value: Data, withResponse: Bool, token: Int?)
    case read(characteristic: String, token: Int?)
    case subscribe(characteristic: String, token: Int?)
    case unsubscribe(characteristic: String, token: Int?)

    /// The page's own correlation id, echoed back on the `ack`, `read` or
    /// `failed` that answers this push.
    ///
    /// Optional because most pushes don't need one, and present because
    /// otherwise `withResponse: true` — a write whose entire point is
    /// confirmation — has nowhere to report that it succeeded.
    public var token: Int? {
        switch self {
        case let .write(_, _, _, token), let .read(_, token),
             let .subscribe(_, token), let .unsubscribe(_, token):
            token
        }
    }

    public var characteristic: String {
        switch self {
        case let .write(characteristic, _, _, _), let .read(characteristic, _),
             let .subscribe(characteristic, _), let .unsubscribe(characteristic, _):
            characteristic
        }
    }
}

extension BLECommand: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, characteristic, value = "valueBase64", withResponse, token
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let characteristic = try container.decode(String.self, forKey: .characteristic)
        let token = try container.decodeIfPresent(Int.self, forKey: .token)
        switch kind {
        case "write":
            self = try .write(
                characteristic: characteristic,
                value: container.decode(Data.self, forKey: .value),
                withResponse: container.decodeIfPresent(Bool.self, forKey: .withResponse) ?? false,
                token: token
            )
        case "read":
            self = .read(characteristic: characteristic, token: token)
        case "subscribe":
            self = .subscribe(characteristic: characteristic, token: token)
        case "unsubscribe":
            self = .unsubscribe(characteristic: characteristic, token: token)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown ble push kind '\(kind)' (expected write, read, subscribe, unsubscribe)"
            )
        }
    }
}

// MARK: - Errors

public enum BLEError: Error, Sendable, Equatable {
    /// The app never declared `bluetooth`, or vetoed it. Recoverable by
    /// consent or a code change, not by waiting.
    case denied(String)
    /// **This machine, right now**: no adapter, adapter switched off,
    /// `bluetoothd` not running, the user refused the OS prompt.
    ///
    /// Never "this OS, forever" — every platform this runtime targets has a
    /// Bluetooth stack, and an app told otherwise would design around a
    /// constraint that doesn't exist.
    case unavailable(String)
    /// No peripheral with that id, or it's gone away.
    case notFound(String)
    /// The link dropped and didn't come back before the page gave up.
    case disconnected(String)
    /// The peripheral refused an operation, or the characteristic isn't there.
    case gatt(String)
    case timedOut(String)
    /// A malformed UUID or an argument that can't mean anything.
    case invalidArgument(String)

    public var bridgeError: BridgeError {
        switch self {
        case let .denied(message): BridgeError(code: "E_BLE_DENIED", message: message)
        case let .unavailable(message): BridgeError(code: "E_BLE_UNAVAILABLE", message: message)
        case let .notFound(message): BridgeError(code: "E_BLE_NOT_FOUND", message: message)
        case let .disconnected(message): BridgeError(code: "E_BLE_DISCONNECTED", message: message)
        case let .gatt(message): BridgeError(code: "E_BLE_GATT", message: message)
        case let .timedOut(message): BridgeError(code: "E_BLE_TIMEOUT", message: message)
        case let .invalidArgument(message): BridgeError(code: BridgeError.decode, message: message)
        }
    }
}

/// The central installed where a platform has no implementation. Answers
/// `unavailable` with a sentence saying so, rather than hanging or trapping.
///
/// Not used by any platform this runtime ships — all five have a real backend —
/// and it exists for tests and for an app injecting its own.
public final class NoneBluetoothCentral: BluetoothCentral {
    private let reason: String

    public init(reason: String = "this build has no Bluetooth backend installed") {
        self.reason = reason
    }

    public func availability() async -> BLEAvailability {
        BLEAvailability(isAvailable: false, reason: reason)
    }

    public func scan(_: BLEScanFilter) -> AsyncThrowingStream<BLEAdvertisement, any Error> {
        AsyncThrowingStream { $0.finish(throwing: BLEError.unavailable(reason).bridgeError) }
    }

    public func connect(_: String) async throws -> any BluetoothLink {
        throw BLEError.unavailable(reason).bridgeError
    }
}
