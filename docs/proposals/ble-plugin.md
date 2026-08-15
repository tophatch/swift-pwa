# Proposal: Bluetooth LE plugin (`ble.*`)

> **Status: proposed.** Written against a concrete consumer: an app that sends
> plotter jobs to a consumer HPGL cutting plotter over BLE. That consumer is
> shipping a host-mediated design first (phone → WebSocket → Node service →
> machine), so **nothing is blocked on this**. It's queued as the later "no host
> awake" tier.
>
> **Revised:** the first draft proposed shipping Apple + Android only, with a
> `None` backend on desktop. That's reversed below — `ble.*` lands on all four
> platforms that have a Bluetooth stack, for the reason in
> [Why desktop is in scope](#why-desktop-is-in-scope).

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
ctx.use(BLEPlugin(BlueZCentral()))             // Linux, BlueZ over D-Bus
ctx.use(BLEPlugin(WinRTBluetoothCentral()))    // Windows, Windows.Devices.Bluetooth
```

As elsewhere, the umbrella picks the platform's conformance, so an app writes
`ctx.use(BLEPlugin())` and the four lines above are what that resolves to.

## Platform parity — the real cost

This is the expensive part, and it's why the consumer isn't waiting on it.

| Platform | Backend | Notes |
| :--- | :--- | :--- |
| Apple | CoreBluetooth | Straightforward; the reference implementation. |
| Android | `BluetoothLeScanner` + `BluetoothGatt` via the Kotlin RPC bridge | Same generic JNI path `vision.preprocessImage` and `net.request` use. Runtime permissions are the work. |
| Linux | BlueZ over D-Bus (`org.bluez.GattCharacteristic1`) | No usable C API — this is D-Bus plumbing, comparable to the StatusNotifierItem tray work. The largest slice. |
| Windows | WinRT `Windows.Devices.Bluetooth` | A C++/WinRT shim alongside `CWebView2Shim`. Cheaper than it looks — see below. |

### Why desktop is in scope

The first draft proposed `NoneBluetoothCentral` on Linux and Windows for v1,
reasoning from the precedent that `process.*` is desktop-only and synthetic input
is macOS + GTK3 only. That precedent doesn't transfer, because it conflates two
different things:

- **The platform can't.** iOS cannot spawn a subprocess. `process.*` answering
  `E_UNIMPLEMENTED` there is honest, and the model an adopter forms from it —
  "mobile OSes don't do this" — is correct and stays correct.
- **We haven't.** Linux and Windows both have perfectly good BLE stacks. A `None`
  backend there is our own debt wearing a platform limit's clothing.

Nothing in an error code distinguishes those, and the cost isn't confusion — it's
that an adopter designs around a constraint that doesn't exist. This proposal's
own fallback is a host-mediated relay; ship BLE on two platforms of five and that
relay becomes permanent for anyone targeting desktop, which is the *likelier*
consumer: a plotter, laser or 3D-printer host is usually a desktop app. A project
whose pitch is one source across five platforms shouldn't answer its most
hardware-shaped capability with "not here".

So: **one API, four real backends.** Two things make that affordable:

- **Windows is cheaper than the table suggests.** `Windows.Devices.Bluetooth` is
  in-box WinRT — no NuGet, no bootstrapper, no unlock token — so the shim is
  strictly less work than [`CPhiSilica`](../../Sources/CPhiSilica/), which already
  proves the C++/WinRT → Swift pattern in this package.
- **Linux is the real cost, but the machinery exists.** BlueZ is D-Bus, and the
  GTK4 tray (StatusNotifierItem + dbusmenu over GDBus) built exactly this kind of
  plumbing twice, including the verification recipe of standing up a fake bus
  service to test against.

Sequence it as four PRs — Apple → Android → Linux → Windows — but don't tag a
release containing `ble.*` until all four are real. Partial landings are fine in
`main`; a partial *release* is the thing that teaches adopters the wrong model.

### What `E_BLE_UNAVAILABLE` means

It stays, and it means **this machine, right now**: no adapter, adapter switched
off, `bluetoothd` not running, permission refused by the user. It must never mean
"this OS, forever". Feature detection via `__platform.info` stays for the same
reason — an app should degrade when the hardware isn't there, which is a
condition it can usefully tell the user about.

### Permissions

- **iOS** — `NSBluetoothAlwaysUsageDescription` in Info.plist. No core change
  needed; the existing `ios.info_plist` passthrough in `pwa.json` covers it, same
  as the `NSFaceIDUsageDescription` story in
  [locking-with-biometrics.md](../tutorials/locking-with-biometrics.md).
- **Android** — `BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT` in
  `AndroidTemplates.swift`, gated on the plugin being used, the way
  `USE_BIOMETRIC` already is. Declare `neverForLocation` on the scan permission
  so it doesn't drag in location. API 31+ needs a **runtime** request, which
  biometrics didn't — that's genuinely new ground in the Android bundler, and it
  is the same ground [permissions-bridge.md](permissions-bridge.md) has to break
  for camera / microphone / location. Whichever lands first should build the
  runtime-request helper; the second should reuse it rather than grow a parallel
  one.
- **Linux** — no manifest concept. BlueZ enforces at the D-Bus layer via polkit;
  a desktop user is normally already authorized, and a refusal surfaces as
  `E_BLE_UNAVAILABLE`.
- **Windows** — nothing for an unpackaged portable `.exe`. An **MSIX** build needs
  the `bluetooth` device capability in its manifest, which the MSIX bundler
  should emit when the plugin is in use.

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

## Resolved questions

- **Is a `None` backend on Linux/Windows acceptable for a first cut?** No — all
  four. See [Why desktop is in scope](#why-desktop-is-in-scope).
- **Deduplicate scan results by peripheral id, or leave them raw?** Raw. Watching
  RSSI settle is how you build a device picker, dedup in the page is a few lines,
  and a plugin that dedups has thrown away information the page can't recover.

## Open questions

- Does the duplex-session mapping hold for a peripheral that drops mid-write?
  The bridge tears a session down on error; a BLE link that reconnects on its own
  (CoreBluetooth will, given the chance) may want to stay one session across the
  gap rather than force the page to re-open. Decide before the Apple PR, since it
  shapes the `state` event.
- Verification needs a real peripheral on four operating systems. The plotter
  covers the consumer's own path; a cheap BLE dev board that advertises a known
  characteristic is probably what the other three get tested against.
