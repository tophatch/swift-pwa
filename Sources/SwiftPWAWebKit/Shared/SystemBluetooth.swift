#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import SwiftPWACore

    /// CoreBluetooth-backed ``BluetoothCentral`` for macOS and iOS.
    ///
    /// **Info.plist.** `NSBluetoothAlwaysUsageDescription` must be present or
    /// the OS refuses — and on iOS it *terminates the process*.
    /// `permissions.device`'s `reason` emits it; without a bundle (a bare
    /// `swift run`) there's no Info.plist to read, which is why Bluetooth work
    /// has to be checked against a real `.app`.
    ///
    /// **Threading.** Everything CoreBluetooth runs on one private serial
    /// queue, which is also the lock: delegate callbacks and the calls the
    /// bridge makes from the cooperative pool both land there, so no state
    /// here needs its own lock. Callers get `async` methods that hop onto it.
    public final class SystemBluetooth: NSObject, BluetoothCentral, @unchecked Sendable {
        private let queue = DispatchQueue(label: "swift-pwa.bluetooth")
        private var manager: CBCentralManager!

        /// Waiting for the manager's first state, which arrives asynchronously
        /// after `init` — `.unknown` until then, and answering "unavailable"
        /// from that would make every first call fail.
        private var stateWaiters: [(CBManagerState) -> Void] = []

        private var scans: [UUID: ScanSubscription] = [:]
        /// Peripherals seen this session, so `connect` can resolve an id that
        /// `retrievePeripherals` doesn't know (it only remembers peripherals
        /// the system has connected to before).
        private var discovered: [UUID: CBPeripheral] = [:]
        private var links: [UUID: CoreBluetoothLink] = [:]

        private struct ScanSubscription {
            let filter: BLEScanFilter
            let continuation: AsyncThrowingStream<BLEAdvertisement, any Error>.Continuation
        }

        override public init() {
            super.init()
            // `showPowerAlert: false` — the runtime decides what to tell the
            // user about a switched-off adapter (through `ble.availability`),
            // and a system alert raised by merely *constructing* the manager
            // would fire before the app ever asked for anything.
            manager = CBCentralManager(
                delegate: self, queue: queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }

        // MARK: - BluetoothCentral

        public func availability() async -> BLEAvailability {
            let state = await currentState()
            return Self.availability(for: state)
        }

        public func scan(_ filter: BLEScanFilter) -> AsyncThrowingStream<BLEAdvertisement, any Error> {
            AsyncThrowingStream { continuation in
                let id = UUID()
                queue.async { [self] in
                    scans[id] = ScanSubscription(filter: filter, continuation: continuation)
                    applyScanState()
                    if let timeoutMs = filter.timeoutMs {
                        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [self] in
                            scans[id]?.continuation.finish()
                            scans[id] = nil
                            applyScanState()
                        }
                    }
                }
                continuation.onTermination = { [self] _ in
                    queue.async { [self] in
                        scans[id] = nil
                        // Stops the radio when the last subscriber goes, not
                        // just the delivery: a scan nobody is reading is a
                        // battery drain the page can no longer see.
                        applyScanState()
                    }
                }
            }
        }

        public func connect(_ id: String) async throws -> any BluetoothLink {
            let state = await currentState()
            let availability = Self.availability(for: state)
            guard availability.isAvailable else {
                throw BLEError.unavailable(availability.reason ?? "Bluetooth isn't available right now")
            }
            guard let uuid = UUID(uuidString: id) else {
                throw BLEError.notFound("'\(id)' isn't a peripheral id from this platform's ble.scan")
            }
            // One hop, so the `CBPeripheral` never crosses a suspension point:
            // it isn't `Sendable`, and the queue is what makes touching it safe.
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard let peripheral = discovered[uuid]
                        ?? manager.retrievePeripherals(withIdentifiers: [uuid]).first
                    else {
                        continuation.resume(throwing: BLEError.notFound(
                            "no peripheral \(id) — scan for it first, or it may have gone away"
                        ))
                        return
                    }
                    discovered[uuid] = peripheral
                    let link = CoreBluetoothLink(peripheral: peripheral, manager: manager, queue: queue)
                    links[uuid] = link
                    link.onRelease = { [weak self] in
                        guard let self else { return }
                        queue.async { self.links[uuid] = nil }
                    }
                    peripheral.delegate = link
                    manager.connect(peripheral)
                    continuation.resume(returning: link)
                }
            }
        }

        // MARK: - Plumbing

        private func currentState() async -> CBManagerState {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard manager.state == .unknown else {
                        continuation.resume(returning: manager.state)
                        return
                    }
                    stateWaiters.append { continuation.resume(returning: $0) }
                }
            }
        }

        private static func availability(for state: CBManagerState) -> BLEAvailability {
            switch state {
            case .poweredOn:
                .available
            case .poweredOff:
                BLEAvailability(isAvailable: false, reason: "Bluetooth is switched off")
            case .unauthorized:
                // The OS asked and the user said no — or, on a bare `swift run`
                // with no Info.plist, it never asked at all.
                BLEAvailability(isAvailable: false, reason: "this app isn't allowed to use Bluetooth")
            case .unsupported:
                BLEAvailability(isAvailable: false, reason: "this device has no Bluetooth LE")
            case .resetting:
                BLEAvailability(isAvailable: false, reason: "the Bluetooth stack is restarting")
            default:
                BLEAvailability(isAvailable: false, reason: "Bluetooth isn't ready")
            }
        }

        /// One radio, any number of subscribers: scan for the union of what
        /// they asked for, and sift per-subscriber on the way out. Scanning
        /// unfiltered whenever *someone* wants everything is deliberate — a
        /// service-filtered scan on Apple only reports peripherals advertising
        /// that service, so a narrower scan would starve the broad subscriber.
        private func applyScanState() {
            guard !scans.isEmpty else {
                if manager.isScanning { manager.stopScan() }
                return
            }
            let wantsEverything = scans.values.contains { $0.filter.services.isEmpty }
            let services: [CBUUID]? = wantsEverything
                ? nil
                : scans.values.flatMap(\.filter.services).map { CBUUID(string: $0) }
            if manager.isScanning { manager.stopScan() }
            manager.scanForPeripherals(
                withServices: services,
                // Without this a peripheral is reported once and then never
                // again, so RSSI never updates and a picker can't show the
                // device getting nearer.
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    // MARK: - CBCentralManagerDelegate

    extension SystemBluetooth: CBCentralManagerDelegate {
        public func centralManagerDidUpdateState(_ central: CBCentralManager) {
            let waiters = stateWaiters
            stateWaiters = []
            for waiter in waiters { waiter(central.state) }

            guard central.state != .poweredOn else { return }
            // The radio went away under an open scan. Fail the subscribers
            // rather than leaving them waiting for advertisements that can no
            // longer arrive.
            let reason = Self.availability(for: central.state).reason ?? "Bluetooth stopped being available"
            for subscription in scans.values {
                subscription.continuation.finish(throwing: BLEError.unavailable(reason).bridgeError)
            }
            scans = [:]
        }

        public func centralManager(
            _: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String: Any],
            rssi RSSI: NSNumber
        ) {
            discovered[peripheral.identifier] = peripheral
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                .compactMap { BLEUUID.canonical($0.uuidString) }
            // 127 is CoreBluetooth's "not available", not a very strong signal.
            let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
            let advertisement = BLEAdvertisement(
                id: peripheral.identifier.uuidString,
                name: name,
                rssi: rssi,
                services: services,
                manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
                timestamp: Date().timeIntervalSince1970
            )
            for subscription in scans.values where matches(advertisement, subscription.filter) {
                subscription.continuation.yield(advertisement)
            }
        }

        private func matches(_ advertisement: BLEAdvertisement, _ filter: BLEScanFilter) -> Bool {
            if let prefix = filter.namePrefix, !(advertisement.name ?? "").hasPrefix(prefix) { return false }
            guard !filter.services.isEmpty else { return true }
            return !Set(filter.services).isDisjoint(with: advertisement.services)
        }

        public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
            links[peripheral.identifier]?.didConnect()
        }

        public func centralManager(
            _: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?
        ) {
            links[peripheral.identifier]?.didDisconnect(error: error, willRetry: true)
        }

        public func centralManager(
            _: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?
        ) {
            guard let link = links[peripheral.identifier] else { return }
            link.didDisconnect(error: error, willRetry: !link.isReleased)
            // A link outlives a drop, so ask for it back. CoreBluetooth's
            // `connect` has no timeout — it stays pending until the peripheral
            // shows up again, which is exactly the behaviour wanted here.
            if !link.isReleased { manager.connect(peripheral) }
        }
    }

    // MARK: - One connection

    /// A live link to one peripheral.
    ///
    /// All state is touched only on the central's queue; the `async` methods
    /// hop onto it and park a continuation, which the matching delegate
    /// callback resumes.
    final class CoreBluetoothLink: NSObject, BluetoothLink, @unchecked Sendable {
        private let peripheral: CBPeripheral
        private let manager: CBCentralManager
        private let queue: DispatchQueue

        private var continuation: AsyncThrowingStream<BLELinkEvent, any Error>.Continuation?
        private var buffered: [BLELinkEvent] = []
        /// Characteristics by canonical UUID, refreshed on every (re)discovery
        /// because the handles don't survive a drop.
        private var characteristics: [String: CBCharacteristic] = [:]
        private var servicesPendingDiscovery = 0

        private var pendingReads: [String: [(Result<Data, any Error>) -> Void]] = [:]
        private var pendingWrites: [String: [(Result<Void, any Error>) -> Void]] = [:]
        private var pendingNotifies: [String: [(Result<Void, any Error>) -> Void]] = [:]

        private(set) var isReleased = false
        var onRelease: (() -> Void)?

        init(peripheral: CBPeripheral, manager: CBCentralManager, queue: DispatchQueue) {
            self.peripheral = peripheral
            self.manager = manager
            self.queue = queue
            super.init()
        }

        // MARK: BluetoothLink

        func events() -> AsyncThrowingStream<BLELinkEvent, any Error> {
            AsyncThrowingStream { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    // Discovery can finish before the plugin subscribes, and a
                    // `ready` dropped on the floor leaves the page waiting for
                    // a link that is in fact usable.
                    for event in buffered { continuation.yield(event) }
                    buffered = []
                }
            }
        }

        func write(characteristic: String, value: Data, withResponse: Bool) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    guard let target = characteristics[characteristic] else {
                        continuation.resume(throwing: missing(characteristic))
                        return
                    }
                    guard !withResponse else {
                        pendingWrites[characteristic, default: []].append { continuation.resume(with: $0) }
                        peripheral.writeValue(value, for: target, type: .withResponse)
                        return
                    }
                    peripheral.writeValue(value, for: target, type: .withoutResponse)
                    // Nothing to wait for: the radio took it, and that is all
                    // anyone can know about a write without a response.
                    continuation.resume()
                }
            }
        }

        func read(characteristic: String) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard let target = characteristics[characteristic] else {
                        continuation.resume(throwing: missing(characteristic))
                        return
                    }
                    pendingReads[characteristic, default: []].append { continuation.resume(with: $0) }
                    peripheral.readValue(for: target)
                }
            }
        }

        func setNotify(characteristic: String, enabled: Bool) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    guard let target = characteristics[characteristic] else {
                        continuation.resume(throwing: missing(characteristic))
                        return
                    }
                    pendingNotifies[characteristic, default: []].append { continuation.resume(with: $0) }
                    peripheral.setNotifyValue(enabled, for: target)
                }
            }
        }

        func disconnect() async {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !isReleased else {
                        continuation.resume()
                        return
                    }
                    isReleased = true
                    peripheral.delegate = nil
                    manager.cancelPeripheralConnection(peripheral)
                    failEverythingPending(with: BLEError.disconnected("the link was closed"))
                    self.continuation?.finish()
                    self.continuation = nil
                    onRelease?()
                    continuation.resume()
                }
            }
        }

        // MARK: Central callbacks (already on `queue`)

        func didConnect() {
            emit(.state(connected: true, reason: nil))
            servicesPendingDiscovery = 0
            characteristics = [:]
            peripheral.discoverServices(nil)
        }

        func didDisconnect(error: (any Error)?, willRetry: Bool) {
            characteristics = [:]
            // Anything in flight died with the link. Failing it here is what
            // turns "the app hangs after the machine browns out" into a
            // `failed` event the page can show.
            failEverythingPending(with: BLEError
                .disconnected(error?.localizedDescription ?? "the peripheral disconnected"))
            guard !isReleased else { return }
            emit(.state(connected: false, reason: error?.localizedDescription ?? (willRetry ? "reconnecting" : nil)))
        }

        // MARK: Helpers

        private func emit(_ event: BLELinkEvent) {
            guard let continuation else {
                buffered.append(event)
                return
            }
            continuation.yield(event)
        }

        private func missing(_ characteristic: String) -> BLEError {
            .gatt("this peripheral has no characteristic \(characteristic) (or it hasn't been discovered yet)")
        }

        private func failEverythingPending(with error: BLEError) {
            for (_, waiters) in pendingReads { for resume in waiters { resume(.failure(error)) } }
            for (_, waiters) in pendingWrites { for resume in waiters { resume(.failure(error)) } }
            for (_, waiters) in pendingNotifies { for resume in waiters { resume(.failure(error)) } }
            pendingReads = [:]
            pendingWrites = [:]
            pendingNotifies = [:]
        }

        private func resumeFirst<T>(
            _ table: inout [String: [(Result<T, any Error>) -> Void]],
            _ key: String,
            with result: Result<T, any Error>
        ) -> Bool {
            guard var waiters = table[key], !waiters.isEmpty else { return false }
            let resume = waiters.removeFirst()
            table[key] = waiters.isEmpty ? nil : waiters
            resume(result)
            return true
        }
    }

    // MARK: - CBPeripheralDelegate

    extension CoreBluetoothLink: CBPeripheralDelegate {
        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
            if let error {
                emit(.failed(
                    message: "service discovery failed: \(error.localizedDescription)",
                    characteristic: nil,
                    token: nil
                ))
                return
            }
            let services = peripheral.services ?? []
            servicesPendingDiscovery = services.count
            guard servicesPendingDiscovery > 0 else {
                emit(.ready(services: []))
                return
            }
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }

        func peripheral(
            _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error _: (any Error)?
        ) {
            for characteristic in service.characteristics ?? [] {
                if let uuid = BLEUUID.canonical(characteristic.uuid.uuidString) {
                    characteristics[uuid] = characteristic
                }
            }
            servicesPendingDiscovery -= 1
            guard servicesPendingDiscovery <= 0 else { return }
            // Emitted again after every reconnect, deliberately: the handles
            // are new, and the peripheral's services genuinely may have changed.
            emit(.ready(services: (peripheral.services ?? []).map(Self.describe)))
        }

        func peripheral(
            _: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?
        ) {
            guard let uuid = BLEUUID.canonical(characteristic.uuid.uuidString) else { return }
            let result: Result<Data, any Error> = if let error {
                .failure(BLEError.gatt(error.localizedDescription))
            } else {
                .success(characteristic.value ?? Data())
            }
            // One callback serves both `readValue` and a notification, so a
            // pending read claims it and anything else is an unsolicited
            // update — which is what a notification is.
            guard !resumeFirst(&pendingReads, uuid, with: result) else { return }
            if case let .success(value) = result {
                emit(.notify(characteristic: uuid, value: value))
            }
        }

        func peripheral(
            _: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?
        ) {
            guard let uuid = BLEUUID.canonical(characteristic.uuid.uuidString) else { return }
            _ = resumeFirst(
                &pendingWrites, uuid,
                with: error.map { .failure(BLEError.gatt($0.localizedDescription)) } ?? .success(())
            )
        }

        func peripheral(
            _: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?
        ) {
            guard let uuid = BLEUUID.canonical(characteristic.uuid.uuidString) else { return }
            _ = resumeFirst(
                &pendingNotifies, uuid,
                with: error.map { .failure(BLEError.gatt($0.localizedDescription)) } ?? .success(())
            )
        }

        private static func describe(_ service: CBService) -> BLEService {
            BLEService(
                uuid: BLEUUID.canonical(service.uuid.uuidString) ?? service.uuid.uuidString,
                isPrimary: service.isPrimary,
                characteristics: (service.characteristics ?? []).map { characteristic in
                    BLECharacteristic(
                        uuid: BLEUUID.canonical(characteristic.uuid.uuidString) ?? characteristic.uuid.uuidString,
                        properties: properties(of: characteristic)
                    )
                }
            )
        }

        /// What the peripheral says it supports. Worth surfacing rather than
        /// swallowing: writing `withResponse: true` to a characteristic that
        /// only does `writeWithoutResponse` fails on every platform, with four
        /// different messages.
        private static func properties(of characteristic: CBCharacteristic) -> [String] {
            var names: [String] = []
            let properties = characteristic.properties
            if properties.contains(.read) { names.append("read") }
            if properties.contains(.write) { names.append("write") }
            if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
            if properties.contains(.notify) { names.append("notify") }
            if properties.contains(.indicate) { names.append("indicate") }
            return names
        }
    }
#endif
