#if os(Linux)
    import CBlueZShim
    import Foundation
    import SwiftPWACore

    /// The shim's session handle. Spelled out because the struct is complete in
    /// the header, so Swift imports it as a typed pointer rather than an
    /// `OpaquePointer`.
    typealias BlueZSession = UnsafeMutablePointer<swiftpwa_ble_session>

    /// BlueZ-backed ``BluetoothCentral`` for Linux, over GDBus.
    ///
    /// Linux has no consent layer for Bluetooth the way iOS and Android do:
    /// BlueZ enforces at the D-Bus layer through polkit, and a desktop user is
    /// normally already authorized. So the app's own declaration — and the
    /// veto above it — is the whole decision here, exactly as it is for
    /// capture.
    ///
    /// The shim runs its own GMainContext on its own thread, so nothing here
    /// waits on the GTK main loop being free.
    public final class SystemBluetooth: BluetoothCentral, @unchecked Sendable {
        public init() {}

        public func availability() async -> BLEAvailability {
            var reason: UnsafeMutablePointer<CChar>?
            let available = swiftpwa_ble_available(&reason)
            defer { if let reason { free(reason) } }
            guard available == 0 else { return .available }
            return BLEAvailability(
                isAvailable: false,
                reason: reason.map { String(cString: $0) } ?? "Bluetooth isn't available right now"
            )
        }

        public func scan(_ filter: BLEScanFilter) -> AsyncThrowingStream<BLEAdvertisement, any Error> {
            AsyncThrowingStream { continuation in
                struct Update: Decodable { var advertisement: BLEAdvertisement }
                let box = BlueZCallbackBox { data in
                    guard var update = try? JSONDecoder().decode(Update.self, from: data) else { return }
                    update.advertisement.services = update.advertisement.services
                        .compactMap(BLEUUID.canonical)
                    if let prefix = filter.namePrefix,
                       !(update.advertisement.name ?? "").hasPrefix(prefix) { return }
                    continuation.yield(update.advertisement)
                }

                var handle: BlueZSession?
                var error: UnsafeMutablePointer<CChar>?
                let uuids = filter.services
                withArrayOfCStrings(uuids) { pointers in
                    handle = swiftpwa_ble_scan_start(
                        pointers, Int32(uuids.count), blueZTrampoline,
                        Unmanaged.passRetained(box).toOpaque(), &error
                    )
                }
                guard let handle else {
                    let message = error.map { String(cString: $0) }
                        ?? "the scan could not start"
                    if let error { free(error) }
                    continuation.finish(throwing: BLEError.unavailable(message).bridgeError)
                    return
                }
                // Laundered through `UInt`: the session pointer isn't
                // `Sendable`, and the termination handler is.
                let address = UInt(bitPattern: handle)
                continuation.onTermination = { _ in
                    swiftpwa_ble_scan_stop(BlueZSession(bitPattern: address))
                }
            }
        }

        public func connect(_ id: String) async throws -> any BluetoothLink {
            let link = BlueZLink()
            var error: UnsafeMutablePointer<CChar>?
            let box = BlueZCallbackBox { [weak link] data in link?.deliver(data) }
            let handle = swiftpwa_ble_connect(
                id, blueZTrampoline, Unmanaged.passRetained(box).toOpaque(), &error
            )
            guard let handle else {
                let message = error.map { String(cString: $0) } ?? "the peripheral could not be reached"
                if let error { free(error) }
                // BlueZ says "Software caused connection abort" for a device
                // it has never seen, which is a sentence about sockets, not
                // about the thing the caller got wrong.
                throw message.contains("not available") || message.contains("Does Not Exist")
                    ? BLEError.notFound("no peripheral \(id) — scan for it first, or it may have gone away")
                    : BLEError.unavailable(message)
            }
            link.adopt(handle)
            return link
        }
    }

    /// Owns the Swift closure a C callback fires into, since the shim can only
    /// carry a `void *`.
    final class BlueZCallbackBox {
        let handle: (Data) -> Void
        init(_ handle: @escaping (Data) -> Void) { self.handle = handle }
    }

    /// The C function pointer every shim callback goes through. Kept
    /// non-capturing, which is what lets it convert to a C function pointer at
    /// all.
    private let blueZTrampoline: @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { json, context in
        guard let json, let context else { return }
        let box = Unmanaged<BlueZCallbackBox>.fromOpaque(context).takeUnretainedValue()
        box.handle(Data(String(cString: json).utf8))
    }

    /// `[String]` as the `const char *const *` the shim wants, valid for the
    /// duration of the call.
    private func withArrayOfCStrings<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R
    ) -> R {
        guard !strings.isEmpty else { return body(nil) }
        var pointers = strings.map { strdup($0).map { UnsafePointer($0) } }
        defer { for pointer in pointers { free(UnsafeMutableRawPointer(mutating: pointer)) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(UnsafePointer(buffer.baseAddress))
        }
    }

    /// One BlueZ connection.
    ///
    /// The shim's calls are synchronous D-Bus round trips, so each `async`
    /// method here runs one on a detached task rather than blocking the
    /// cooperative pool's thread.
    final class BlueZLink: BluetoothLink, @unchecked Sendable {
        private let lock = NSLock()
        /// Held as an integer so the handle can cross into a `@Sendable`
        /// closure; the shim's session isn't `Sendable` and the queue inside
        /// it is what makes touching it safe.
        private var sessionAddress: UInt = 0
        private var continuation: AsyncThrowingStream<BLELinkEvent, any Error>.Continuation?
        private var buffered: [BLELinkEvent] = []

        func adopt(_ session: BlueZSession) {
            lock.withLock { sessionAddress = UInt(bitPattern: session) }
        }

        private var session: BlueZSession? {
            lock.withLock { BlueZSession(bitPattern: sessionAddress) }
        }

        func events() -> AsyncThrowingStream<BLELinkEvent, any Error> {
            AsyncThrowingStream { continuation in
                let pending: [BLELinkEvent] = lock.withLock {
                    self.continuation = continuation
                    defer { buffered = [] }
                    return buffered
                }
                // `connect` can resolve the whole service tree before the
                // plugin subscribes, and a dropped `ready` leaves the page
                // waiting for a link that is in fact usable.
                for event in pending { continuation.yield(event) }
            }
        }

        func deliver(_ data: Data) {
            guard let event = Self.decode(data) else { return }
            let target = lock.withLock { () -> AsyncThrowingStream<BLELinkEvent, any Error>.Continuation? in
                if continuation == nil { buffered.append(event) }
                return continuation
            }
            target?.yield(event)
        }

        func write(characteristic: String, value: Data, withResponse: Bool) async throws {
            try await run { session, error in
                value.withUnsafeBytes { bytes in
                    swiftpwa_ble_write(
                        session, characteristic,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        Int32(value.count), withResponse ? 1 : 0, error
                    )
                }
            }
        }

        func read(characteristic: String) async throws -> Data {
            guard let session else { throw BLEError.disconnected("the link is closed") }
            let address = UInt(bitPattern: session)
            return try await withCheckedThrowingContinuation { continuation in
                Task.detached {
                    guard let session = BlueZSession(bitPattern: address) else {
                        continuation.resume(throwing: BLEError.disconnected("the link is closed"))
                        return
                    }
                    var error: UnsafeMutablePointer<CChar>?
                    guard let encoded = swiftpwa_ble_read(session, characteristic, &error) else {
                        let message = error.map { String(cString: $0) } ?? "the read failed"
                        if let error { free(error) }
                        continuation.resume(throwing: BLEError.gatt(message))
                        return
                    }
                    defer { free(encoded) }
                    guard let value = Data(base64Encoded: String(cString: encoded)) else {
                        continuation.resume(throwing: BLEError.gatt("the peripheral's value wasn't readable"))
                        return
                    }
                    continuation.resume(returning: value)
                }
            }
        }

        func setNotify(characteristic: String, enabled: Bool) async throws {
            try await run { session, error in
                swiftpwa_ble_set_notify(session, characteristic, enabled ? 1 : 0, error)
            }
        }

        func disconnect() async {
            let address: UInt = lock.withLock {
                let held = sessionAddress
                sessionAddress = 0
                continuation?.finish()
                continuation = nil
                return held
            }
            guard address != 0 else { return }
            // Detached because the shim's disconnect is a synchronous D-Bus
            // round trip, and blocking a cooperative-pool thread on one is how
            // a runtime with a small pool wedges.
            await Task.detached { swiftpwa_ble_disconnect(BlueZSession(bitPattern: address)) }.value
        }

        /// One shim call that returns 0 on failure and fills `error`.
        private func run(
            _ body: @escaping @Sendable (BlueZSession, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        ) async throws {
            guard let session else { throw BLEError.disconnected("the link is closed") }
            let address = UInt(bitPattern: session)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Task.detached {
                    guard let session = BlueZSession(bitPattern: address) else {
                        continuation.resume(throwing: BLEError.disconnected("the link is closed"))
                        return
                    }
                    var error: UnsafeMutablePointer<CChar>?
                    let ok = body(session, &error)
                    if ok != 0 {
                        continuation.resume()
                        return
                    }
                    let message = error.map { String(cString: $0) } ?? "the operation failed"
                    if let error { free(error) }
                    continuation.resume(throwing: BLEError.gatt(message))
                }
            }
        }

        /// The shim emits the same `kind`-tagged shapes the Android RPC does,
        /// so both decode into the same events rather than each backend
        /// inventing its own.
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
    }
#endif
