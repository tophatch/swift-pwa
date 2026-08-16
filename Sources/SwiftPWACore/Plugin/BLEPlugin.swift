import Foundation

/// Optional plugin exposing `ble.*` to JS:
///
/// ```js
/// const stop = __SWIFT_PWA__.subscribe('ble.scan', { services: ['ffe0'] }, (found) => { … });
///
/// const link = __SWIFT_PWA__.session('ble.connect', { id }, {
///     onChunk: (event) => { … },   // ready / notify / read / ack / state / failed
/// });
/// link.push({ kind: 'write', characteristic: 'ffe1', valueBase64, withResponse: false });
/// link.close();                    // disconnects
/// ```
///
/// Opt-in, like every plugin that touches hardware, and gated on the
/// `bluetooth` permission — so an app's own privacy switch covers Bluetooth
/// the same way it covers the camera, and an app that forgot to declare it
/// gets a diagnostic naming the fix rather than an empty device list.
///
/// ```swift
/// ctx.permissions.declare(.bluetooth)
/// ctx.use(BLEPlugin(SystemBluetooth()))
/// ```
public struct BLEPlugin: Plugin {
    public static let pluginName = "ble"

    private let central: any BluetoothCentral

    public init(_ central: any BluetoothCentral) {
        self.central = central
    }

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let central = central
        let permissions = app.permissions

        registry.register(
            "ble.availability",
            typed: { (_: EmptyArgs, _) async throws -> BLEAvailability in
                try Self.checkPermitted(permissions)
                return await central.availability()
            }
        )

        registry.registerStream(
            "ble.scan",
            typed: { (request: BLEScanFilter, _) -> AsyncThrowingStream<BLEAdvertisement, any Error> in
                AsyncThrowingStream { continuation in
                    let filter: BLEScanFilter
                    do {
                        try Self.checkPermitted(permissions)
                        filter = try request.canonicalized()
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    let task = Task {
                        // Availability is checked here rather than left to the
                        // backend so all four fail the same way: an adapter
                        // that's off scans happily and finds nothing, which a
                        // page can't tell from "no peripherals nearby".
                        let availability = await central.availability()
                        guard availability.isAvailable else {
                            continuation.finish(throwing: BLEError.unavailable(
                                availability.reason ?? "Bluetooth isn't available on this machine right now"
                            ).bridgeError)
                            return
                        }
                        do {
                            for try await found in central.scan(filter) {
                                continuation.yield(found)
                            }
                            continuation.finish()
                        } catch let error as BLEError {
                            continuation.finish(throwing: error.bridgeError)
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    // Unsubscribing has to stop the radio, not just the
                    // delivery — the page can no longer see a scan it left on.
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )

        registry.registerSession(
            "ble.connect",
            typed: { (request: BLEConnectRequest, inbound, _) -> AsyncThrowingStream<BLELinkEvent, any Error> in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            try Self.checkPermitted(permissions)
                            try await Self.runLink(
                                request: request, central: central, inbound: inbound, continuation: continuation
                            )
                            continuation.finish()
                        } catch let error as BLEError {
                            continuation.finish(throwing: error.bridgeError)
                        } catch is CancellationError {
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }

    /// Open the link, then pump its events downstream and the page's pushes
    /// into it until either side stops.
    private static func runLink(
        request: BLEConnectRequest,
        central: any BluetoothCentral,
        inbound: BridgeInbound<BLECommand>,
        continuation: AsyncThrowingStream<BLELinkEvent, any Error>.Continuation
    ) async throws {
        let link = try await central.connect(request.id)
        // Whatever happens next — a throw, the page closing, cancellation —
        // the radio link has to be released. A leaked connection keeps the
        // peripheral occupied, and most only accept one central at a time.
        defer { Task { await link.disconnect() } }

        let ready = OneWayFlag()
        // The deadline covers the *first* `ready` only. A reconnect after a
        // drop deliberately has no deadline: the page asked for a link that
        // survives one, and it can close the session whenever it's done
        // waiting.
        let watchdog = Task {
            try await Task.sleep(for: .milliseconds(request.timeoutMs ?? 15000))
            guard !ready.isSet else { return }
            continuation.finish(throwing: BLEError.timedOut(
                "the peripheral didn't finish connecting within \(request.timeoutMs ?? 15000)ms"
            ).bridgeError)
        }
        defer { watchdog.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await event in link.events() {
                    if case .ready = event { ready.set() }
                    continuation.yield(event)
                }
            }
            group.addTask {
                for await command in inbound {
                    await perform(command, on: link, continuation: continuation)
                }
                // The page closed the session. `defer` disconnects.
            }
            // Whichever finishes first ends the session: the page closing, or
            // the link's own event stream running out.
            try await group.next()
            group.cancelAll()
        }
    }

    /// Run one push, reporting failure as a downstream `failed` event rather
    /// than an error on the stream — a rejected write shouldn't cost the page
    /// its connection, and the bridge ends a session on a stream error.
    private static func perform(
        _ command: BLECommand,
        on link: any BluetoothLink,
        continuation: AsyncThrowingStream<BLELinkEvent, any Error>.Continuation
    ) async {
        do {
            let characteristic = try BLEUUID.require(command.characteristic)
            switch command {
            case let .write(_, value, withResponse, token):
                try await link.write(characteristic: characteristic, value: value, withResponse: withResponse)
                // Only a write the peripheral acknowledged can be reported as
                // done. Without a response there's nothing to report — the
                // radio took it, and that's all anyone knows.
                if let token, withResponse { continuation.yield(.ack(token: token)) }
            case let .read(_, token):
                let value = try await link.read(characteristic: characteristic)
                continuation.yield(.read(characteristic: characteristic, value: value, token: token))
            case let .subscribe(_, token):
                try await link.setNotify(characteristic: characteristic, enabled: true)
                if let token { continuation.yield(.ack(token: token)) }
            case let .unsubscribe(_, token):
                try await link.setNotify(characteristic: characteristic, enabled: false)
                if let token { continuation.yield(.ack(token: token)) }
            }
        } catch {
            let message = if case let BLEError.gatt(text) = error { text } else { "\(error)" }
            continuation.yield(.failed(
                message: message, characteristic: command.characteristic, token: command.token
            ))
        }
    }

    /// The `bluetooth` permission, checked before the radio is touched.
    ///
    /// The origin is the app itself rather than a page URL: no document is
    /// behind this call, and inventing one would make the veto's origin
    /// argument lie.
    private static func checkPermitted(_ permissions: PermissionPolicy) throws {
        switch permissions.decide(.bluetooth, origin: "ble.*") {
        case .allow:
            return
        case let .deny(reason):
            throw BLEError.denied(
                reason == .vetoed
                    ? "this app has turned Bluetooth off"
                    : "this app has not declared the 'bluetooth' permission"
            ).bridgeError
        }
    }
}

public struct BLEConnectRequest: Sendable, Codable, Equatable {
    /// A peripheral `id` from `ble.scan`.
    public var id: String
    /// How long to wait for the first `ready` before giving up. Default 15s.
    public var timeoutMs: Int?

    public init(id: String, timeoutMs: Int? = nil) {
        self.id = id
        self.timeoutMs = timeoutMs
    }
}

/// A flag that only ever goes one way, for "has the first `ready` arrived".
/// Lock-guarded rather than actor-isolated so the watchdog can read it without
/// a suspension point that would let the answer change underneath it.
private final class OneWayFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}
