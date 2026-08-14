# Proposal: Bluetooth LE plugin (`ble.*`)

> **Status: proposed.** Written against a concrete consumer: an app that sends
> plotter jobs to a consumer HPGL cutting plotter over BLE. That consumer is
> shipping a host-mediated design first (phone → WebSocket → Node service →
> machine), so **nothing is blocked on this**. It's queued as the later "no host
> awake" tier.

## The problem

A web app in a swift-pwa shell cannot talk to a BLE peripheral at all.

**Web Bluetooth is not a fallback.** It has never shipped in WKWebView or Safari
on iOS, and Android's `WebView` doesn't expose it either (Chrome does; the
embedded WebView doesn't). So unlike `net.*` — where the plugin buys CORS-freedom
and header control over an API the page *already has* — `ble.*` is the difference
between a capability existing and not existing. There is no polyfill and no
degraded path.

This is the same shape as `process.*` and `net.*`: a powerful native capability
the WebView deliberately withholds, exposed as an **opt-in** plugin with an
injected backend.

## Why the bridge is already the right shape

A BLE link is a duplex session, and [duplex sessions
shipped](bidirectional-bridge-sessions.md). A connection maps onto
`registerSession` exactly: open with the peripheral to connect to, push writes
into it, receive notifications and state changes as downstream events, and close
to disconnect. Connection lifetime is then tied to session lifetime by the
bridge, which is precisely the bookkeeping we'd otherwise hand-roll per adopter.

Scanning is a plain `subscribe` — a server-streaming fan-out of discovered
peripherals, terminated by unsubscribing.

So no new bridge primitives are needed. This is a plugin, not a bridge change.

## JS API

```js
// Scan: server-streaming. Filter by advertised service UUIDs or name prefix.
const stop = __SWIFT_PWA__.subscribe('ble.scan', {
    services: ['ffe0'],          // optional; empty scans everything
    namePrefix: 'Plotter-',      // optional
    timeoutMs: 15000,
}, (peripheral) => {
    // { id, name, rssi, services }
});
stop();

// Connect: duplex session. Opens the link, discovers services, holds it open.
const link = __SWIFT_PWA__.session('ble.connect', { id: peripheralId }, {
    onChunk: (event) => {
        // { kind: 'ready',   services: [{ uuid, characteristics: [...] }] }
        // { kind: 'notify',  characteristic, valueBase64 }
        // { kind: 'state',   connected }
    },
    onError: (err) => {},
    onEnd: () => {},
});

link.push({ kind: 'write', characteristic: 'ffe1', valueBase64, withResponse: false });
link.push({ kind: 'subscribe', characteristic: 'ffe1' });
link.close();   // disconnects
```

`valueBase64` rather than raw bytes because the envelope is JSON. Fine for this
class of device — the plotter's whole job is a few tens of KB of HPGL — but it's
the reason `ble.*` should not be sold as a bulk-transfer path.

### Why writes are pushes, not invokes

A `ble.write` unary command would need a peripheral id, a characteristic, and its
own connection lookup on every call, plus a correlation story for which
connection it belongs to. Pushing into the open session gets ordering relative to
the connect for free and makes the disconnect-on-close semantics unambiguous.

## Swift API

Mirrors `NetPlugin`'s injected-backend shape — one protocol, per-platform
implementations, a `None` default so the plugin is registerable everywhere:

```swift
public protocol BluetoothCentral: Sendable {
    func scan(_ filter: BLEScanFilter) -> AsyncThrowingStream<BLEPeripheral, Error>
    func connect(_ id: String) async throws -> any BluetoothLink
}

ctx.use(BLEPlugin(CoreBluetoothCentral()))     // Apple
ctx.use(BLEPlugin(AndroidBluetoothCentral()))  // Android, over the Kotlin RPC bridge
```

## Platform parity — the real cost

This is the expensive part, and it's why the consumer isn't waiting on it.

| Platform | Backend | Notes |
| :--- | :--- | :--- |
| Apple | CoreBluetooth | Straightforward; the reference implementation. |
| Android | `BluetoothLeScanner` + `BluetoothGatt` via the Kotlin RPC bridge | Same generic JNI path `vision.preprocessImage` and `net.request` use. Runtime permissions are the work. |
| Linux | BlueZ over D-Bus (`org.bluez.GattCharacteristic1`) | No usable C API — this is D-Bus plumbing, comparable to the StatusNotifierItem tray work. |
| Windows | WinRT `Windows.Devices.Bluetooth` | Needs a shim target alongside `CWebView2Shim`. |

A staged landing is reasonable: **Apple + Android first** with
`NoneBluetoothCentral` on desktop Linux/Windows (which throws `E_BLE_UNAVAILABLE`,
feature-detectable via `__platform.info`). That covers every device this is
actually for, and desktop hosts have real BLE stacks available through their own
runtimes anyway.

### Permissions

- **iOS** — `NSBluetoothAlwaysUsageDescription` in Info.plist. No core change
  needed; the existing `ios.info_plist` passthrough in `pwa.json` covers it, same
  as the `NSFaceIDUsageDescription` story in
  [locking-with-biometrics.md](../tutorials/locking-with-biometrics.md).
- **Android** — `BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT` in
  `AndroidTemplates.swift`, gated on the plugin being used, the way
  `USE_BIOMETRIC` already is. Declare `neverForLocation` on the scan permission
  so it doesn't drag in location. API 31+ needs a **runtime** request, which
  biometrics didn't — that's genuinely new ground in the Android bundler.

## Scope for v1

In: central role only, scan, connect, discover, read, write (with and without
response), notify/indicate subscribe, disconnect, adapter-state errors.

Out: peripheral/advertising role, bonding and pairing UI, L2CAP channels, MTU
negotiation beyond the platform default, background/state-restoration on iOS,
and bulk transfer. Each is a real feature; none is needed by the consumer, and
`ble.*` shouldn't grow them speculatively.

## Alternatives considered

- **Web Bluetooth.** Doesn't exist on either target WebView. Not available.
- **A `serial.*` plugin instead.** Would cover a GRBL laser as well as the
  plotter, but iOS has no USB serial path for a non-MFi device at all, so it
  would be desktop-and-Android-only — solving less of the actual problem for
  comparable effort.
- **Host-mediated only** (what the consumer is building). No swift-pwa work,
  covers both machines, needs a host awake and in range. This plugin's whole
  value is removing that last condition, for BLE devices only.

## Open questions

- Is a `None` backend on Linux/Windows acceptable for a first cut, or does the
  parity bar mean all four or nothing?
- Should scan results be deduplicated by peripheral id in the plugin, or left raw
  so adopters can watch RSSI change over time?
