#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore

    /// WinRT `Windows.Devices.Bluetooth` ``BluetoothCentral``.
    ///
    /// Built-in WinRT, so unlike the Phi Silica tier there's no NuGet package,
    /// no Windows App SDK bootstrapper and nothing to provision — it rides the
    /// `WindowsApp.lib` the shim target already links.
    ///
    /// A portable `.exe` reaches the radio with no capability and no prompt. A
    /// **packaged** (MSIX) build is gated on the `bluetooth` device capability,
    /// which `swift-pwa build` emits from `permissions.device` — so an app that
    /// declares Bluetooth in Swift and not in `pwa.json` works when run from a
    /// folder and fails once installed, which is exactly the drift the build's
    /// cross-check exists to catch.
    public final class SystemBluetooth: BluetoothCentral, @unchecked Sendable {
        public init() {}

        public func availability() async -> BLEAvailability {
            await withCheckedContinuation { continuation in
                // The shim blocks on WinRT's async operations, so it runs off
                // the calling task's thread rather than stalling it.
                DispatchQueue.global().async {
                    var reason: UnsafeMutablePointer<CChar>?
                    let available = swiftpwa_ble_available(&reason)
                    defer { swiftpwa_ble_free_string(reason) }
                    continuation.resume(returning: available != 0
                        ? .available
                        : BLEAvailability(
                            isAvailable: false,
                            reason: reason.map { String(cString: $0) }
                                ?? "Bluetooth isn't available on this machine right now"
                        ))
                }
            }
        }

        public func scan(_ filter: BLEScanFilter) -> AsyncThrowingStream<BLEAdvertisement, any Error> {
            AsyncThrowingStream { continuation in
                struct Update: Decodable { var advertisement: BLEAdvertisement }
                let box = WinBluetoothBox { data in
                    guard var update = try? JSONDecoder().decode(Update.self, from: data) else { return }
                    update.advertisement.services = update.advertisement.services
                        .compactMap(BLEUUID.canonical)
                    // Name filtering stays on this side: the watcher has no
                    // name predicate, and doing it here keeps one definition of
                    // what `namePrefix` means across the five backends.
                    if let prefix = filter.namePrefix,
                       !(update.advertisement.name ?? "").hasPrefix(prefix) { return }
                    continuation.yield(update.advertisement)
                }

                var handle: OpaquePointer?
                var error: UnsafeMutablePointer<CChar>?
                let uuids = filter.services
                let boxBits = UInt(bitPattern: Unmanaged.passRetained(box).toOpaque())
                withArrayOfCStrings(uuids) { pointers in
                    handle = swiftpwa_ble_scan_start(
                        pointers, Int32(uuids.count), winBluetoothTrampoline,
                        UnsafeMutableRawPointer(bitPattern: boxBits), &error
                    )
                }
                guard let handle else {
                    let message = error.map { String(cString: $0) } ?? "the scan could not start"
                    swiftpwa_ble_free_string(error)
                    continuation.finish(throwing: BLEError.unavailable(message).bridgeError)
                    return
                }
                let address = UInt(bitPattern: handle)
                continuation.onTermination = { _ in
                    swiftpwa_ble_scan_stop(OpaquePointer(bitPattern: address))
                }
            }
        }

        public func connect(_ id: String) async throws -> any BluetoothLink {
            let link = WindowsBluetoothLink()
            let box = WinBluetoothBox { [weak link] data in link?.deliver(data) }
            // Retained here and laundered through `UInt`, because the box isn't
            // `Sendable` and the work has to hop off this task's thread: the
            // shim blocks on WinRT's async operations, and Windows opens a GATT
            // link by *reading* the service tree, so `connect` is seconds of
            // waiting rather than a call that returns.
            let boxBits = UInt(bitPattern: Unmanaged.passRetained(box).toOpaque())
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    var error: UnsafeMutablePointer<CChar>?
                    let handle = swiftpwa_ble_connect(
                        id, winBluetoothTrampoline, UnsafeMutableRawPointer(bitPattern: boxBits), &error
                    )
                    guard let handle else {
                        let message = error.map { String(cString: $0) }
                            ?? "the peripheral could not be reached"
                        swiftpwa_ble_free_string(error)
                        continuation.resume(throwing: message.contains("no peripheral")
                            ? BLEError.notFound(message)
                            : BLEError.unavailable(message))
                        return
                    }
                    link.adopt(handle)
                    continuation.resume(returning: link)
                }
            }
        }
    }

    /// Owns the Swift closure a C callback fires into, since the shim can only
    /// carry a `void *`.
    final class WinBluetoothBox {
        let handle: (Data) -> Void
        init(_ handle: @escaping (Data) -> Void) { self.handle = handle }
    }

    /// Non-capturing, which is what lets it convert to a C function pointer.
    private let winBluetoothTrampoline: @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { json, context in
        guard let json, let context else { return }
        let box = Unmanaged<WinBluetoothBox>.fromOpaque(context).takeUnretainedValue()
        box.handle(Data(String(cString: json).utf8))
    }

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

    /// One WinRT connection.
    final class WindowsBluetoothLink: BluetoothLink, @unchecked Sendable {
        private let lock = NSLock()
        private var linkAddress: UInt = 0
        private var continuation: AsyncThrowingStream<BLELinkEvent, any Error>.Continuation?
        private var buffered: [BLELinkEvent] = []

        func adopt(_ link: OpaquePointer) {
            lock.withLock { linkAddress = UInt(bitPattern: link) }
        }

        private var handle: OpaquePointer? {
            lock.withLock { OpaquePointer(bitPattern: linkAddress) }
        }

        func events() -> AsyncThrowingStream<BLELinkEvent, any Error> {
            AsyncThrowingStream { continuation in
                let pending: [BLELinkEvent] = lock.withLock {
                    self.continuation = continuation
                    defer { buffered = [] }
                    return buffered
                }
                // Windows discovers as part of connecting, so `ready` is
                // already out before the plugin subscribes — dropping it would
                // leave the page waiting for a link that is in fact usable.
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
            try await run { handle, error in
                value.withUnsafeBytes { bytes in
                    swiftpwa_ble_write(
                        handle, characteristic,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        Int32(value.count), withResponse ? 1 : 0, error
                    )
                }
            }
        }

        func read(characteristic: String) async throws -> Data {
            guard let handle else { throw BLEError.disconnected("the link is closed") }
            let address = UInt(bitPattern: handle)
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    var error: UnsafeMutablePointer<CChar>?
                    guard let encoded = swiftpwa_ble_read(
                        OpaquePointer(bitPattern: address), characteristic, &error
                    ) else {
                        let message = error.map { String(cString: $0) } ?? "the read failed"
                        swiftpwa_ble_free_string(error)
                        continuation.resume(throwing: BLEError.gatt(message))
                        return
                    }
                    defer { swiftpwa_ble_free_string(encoded) }
                    guard let value = Data(base64Encoded: String(cString: encoded)) else {
                        continuation.resume(throwing: BLEError.gatt("the peripheral's value wasn't readable"))
                        return
                    }
                    continuation.resume(returning: value)
                }
            }
        }

        func setNotify(characteristic: String, enabled: Bool) async throws {
            try await run { handle, error in
                swiftpwa_ble_set_notify(handle, characteristic, enabled ? 1 : 0, error)
            }
        }

        func disconnect() async {
            let address: UInt = lock.withLock {
                let held = linkAddress
                linkAddress = 0
                continuation?.finish()
                continuation = nil
                return held
            }
            guard address != 0 else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    swiftpwa_ble_disconnect(OpaquePointer(bitPattern: address))
                    continuation.resume()
                }
            }
        }

        private func run(
            _ body: @escaping @Sendable (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>)
                -> Int32
        ) async throws {
            guard let handle else { throw BLEError.disconnected("the link is closed") }
            let address = UInt(bitPattern: handle)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global().async {
                    var error: UnsafeMutablePointer<CChar>?
                    let ok = body(OpaquePointer(bitPattern: address), &error)
                    if ok != 0 {
                        continuation.resume()
                        return
                    }
                    let message = error.map { String(cString: $0) } ?? "the operation failed"
                    swiftpwa_ble_free_string(error)
                    continuation.resume(throwing: BLEError.gatt(message))
                }
            }
        }

        /// The shim emits the same `kind`-tagged shapes the Linux shim and the
        /// Android RPC do, so all three decode into the same events.
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
