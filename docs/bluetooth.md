# Bluetooth LE (`ble.*`)

Talking to a Bluetooth LE peripheral from a page, on all five platforms.

> Needs swift-pwa **0.10.1 or newer**. For the hands-on version, see
> [Talking to a Bluetooth peripheral](tutorials/talking-to-a-bluetooth-peripheral.md).

## Why this is a plugin and not a web API

Everything else on the device surface has a web counterpart the runtime merely
had to *answer* for — `getUserMedia` works on every backend now because
something finally responds to the permission request. Bluetooth has no such
counterpart:

- **Web Bluetooth has never shipped in WKWebView or Safari.** Not disabled, not
  behind a flag — it isn't implemented.
- **Android's embedded `WebView` doesn't expose it either.** Chrome does; the
  WebView you get in an app does not.

So there is no polyfill and no degraded path. `ble.*` is the difference between
the capability existing and not existing, which is also why it's the one
permission declared under `permissions.device` rather than `permissions.web` —
no page can ask for it on its own.

**Central role only.** This scans for, connects to and talks to peripherals. It
does not advertise. Peripheral/advertising, bonding and pairing UI, L2CAP
channels and MTU negotiation beyond the platform default are all out of scope;
each is a real feature and none is needed to drive a device.

## Turning it on

```swift
ctx.permissions.declare(.bluetooth)
ctx.use(BLEPlugin(SystemBluetooth()))
```

```json
"permissions": {
  "device": { "bluetooth": { "reason": "Send jobs to your plotter." } }
}
```

Both are required, and `swift-pwa build` fails if they disagree — see
[permissions.md](permissions.md). The `reason` becomes Apple's
`NSBluetoothAlwaysUsageDescription`, Android's `uses-permission` entries and the
MSIX `bluetooth` device capability.

## The API

### `ble.availability`

```js
const { isAvailable, reason } = await __SWIFT_PWA__.invoke('ble.availability', {});
```

Ask before scanning. **An adapter that's switched off scans perfectly happily
and finds nothing**, which a page can't tell from "no peripherals nearby" — so
this is the difference between showing "turn Bluetooth on" and showing an empty
list forever. `reason` is a sentence for the user; it never says "this platform
doesn't do Bluetooth", because all five do.

### `ble.scan`

```js
const stop = __SWIFT_PWA__.subscribe('ble.scan', {
    services: ['5057ab00-0000-4000-b000-000000000001'],  // optional
    namePrefix: 'Plotter-',                              // optional
    timeoutMs: 15000,                                    // optional
}, (peripheral) => {
    // { id, name?, rssi?, services, manufacturerDataBase64?, isConnectable?, timestamp }
});
stop();   // stops the radio, not just the delivery
```

**Results are raw, not de-duplicated.** Watching RSSI settle is how a device
picker gets built, and a scan that de-duplicated has thrown away information the
page can't recover. Two or three lines in the page collapse them by `id`.

A service filter finds *fewer* peripherals, not more: a peripheral only appears
in a filtered scan if it advertises that service, and plenty only mention their
services after you connect.

### `ble.connect`

A connection is a duplex session, because that's what it is — open with the
peripheral, push writes in, take notifications out, close to disconnect. The
bridge ties the connection's lifetime to the session's, which is the bookkeeping
you'd otherwise hand-roll.

```js
const link = __SWIFT_PWA__.session('ble.connect', { id, timeoutMs: 15000 }, {
    onChunk: (event) => {
        // { kind: 'ready',   services: [{ uuid, isPrimary, characteristics: [{ uuid, properties }] }] }
        // { kind: 'notify',  characteristic, value }        value is base64
        // { kind: 'read',    characteristic, value, token }
        // { kind: 'ack',     token }
        // { kind: 'state',   connected, reason }
        // { kind: 'failed',  message, characteristic?, token? }
    },
    onError: (error) => {},   // the session is over
    onEnd: () => {},
});

link.push({ kind: 'subscribe',   characteristic: 'ffe1', token: 1 });
link.push({ kind: 'write',       characteristic: 'ffe1', valueBase64, withResponse: false });
link.push({ kind: 'read',        characteristic: 'ffe1', token: 2 });
link.push({ kind: 'unsubscribe', characteristic: 'ffe1' });
link.close();   // disconnects
```

**`token` is optional and worth using.** It's echoed on the `ack`, `read` or
`failed` that answers a push — without it, `withResponse: true`, whose entire
point is confirmation, has nowhere to report success.

**A failed operation is a `failed` event, not an error.** The bridge ends a
session on a stream error, and a write the peripheral rejects shouldn't cost the
page its connection.

**A link survives a drop.** Going out of range emits
`{ kind: 'state', connected: false }` and the backend keeps trying; a reconnect
emits `ready` again, with freshly discovered services because the handles are
new. The page decides when to give up, by closing. The shape this exists for is
a machine that browns out mid-job — forcing the page back through discovery for
that would be worse than what the platforms give you.

### UUIDs

**Always the full 128-bit lower-case form on the wire, in and out.** Short forms
(`ffe1`, `0000ffe1`), upper case, and `{braces}` are all accepted as input and
canonicalized.

This is not tidiness. CoreBluetooth returns `"FFE1"` for an assigned 16-bit
UUID and an upper-case 128-bit string otherwise; BlueZ and Android always return
lower-case 128-bit; WinRT returns a `GUID`. A page written against one
(`event.characteristic === 'ffe1'`) breaks silently on the other three — a
mismatch, not an error, so nothing is reported and the notifications simply
never seem to arrive.

### Errors

| Code | Means |
| :--- | :--- |
| `E_BLE_DENIED` | The app didn't declare `bluetooth`, or its own veto refused. A code change or a settings change, not something to retry. |
| `E_BLE_UNAVAILABLE` | **This machine, right now**: no adapter, switched off, `bluetoothd` not running, the user refused the OS prompt. Never "this OS". |
| `E_BLE_NOT_FOUND` | No peripheral with that id, or it's gone. |
| `E_BLE_DISCONNECTED` | The link dropped and didn't come back. |
| `E_BLE_GATT` | The peripheral refused an operation, or the characteristic isn't there. |
| `E_BLE_TIMEOUT` | Nothing finished connecting in `timeoutMs`. |

### Peripheral ids are opaque and local

Apple hands out a per-host UUID that deliberately isn't the peripheral's
address; the other three use the Bluetooth address. Both are stable enough to
reconnect to later on the same device, and meaningless anywhere else. Don't
parse them, and don't sync them between a user's machines.

## What each platform does

| | Backend | Notes |
| :--- | :--- | :--- |
| **macOS / iOS** | CoreBluetooth | Needs `NSBluetoothAlwaysUsageDescription`; the OS prompts once, per app. |
| **Linux** | BlueZ over GDBus | No consent layer — polkit governs it, and a desktop user is normally already authorized. |
| **Windows** | WinRT `Windows.Devices.Bluetooth` | A portable `.exe` needs nothing; an MSIX build is gated on the `bluetooth` device capability. |
| **Android** | `BluetoothLeScanner` + `BluetoothGatt` | Runtime permission, asked for on first use. |

### Things that will bite you

- **Android declares Bluetooth twice over.** API 31 replaced the whole scheme:
  before it, a BLE *scan* needed `ACCESS_FINE_LOCATION`, because scanning
  reveals where you are. The bundler emits `BLUETOOTH_SCAN` (with
  `neverForLocation`, the app promising not to infer a position from scan
  results) and `BLUETOOTH_CONNECT`, plus the three superseded permissions capped
  at API 30 when your `minSdk` can still reach them.
- **Linux and a dual-mode peripheral.** A Mac, a phone — anything that is also a
  classic Bluetooth device — advertises over LE from the same address its
  classic radio uses, so BlueZ keeps one device object with both identities and
  `Connect()` takes the classic route, failing `br-connection-key-missing`.
  Pairing it once is the usual fix. An LE-only peripheral never takes that path,
  and that is what most real peripherals are.
- **Windows holds the link only while something needs it.** The backend keeps a
  `GattSession` with `MaintainConnection` for you; without one the link drops
  and re-establishes on the next call, which surfaces as `ready` firing
  repeatedly.
- **A characteristic that can't notify usually has no CCCD.** Subscribing writes
  the Client Characteristic Configuration descriptor; a peripheral that didn't
  publish one can't be subscribed to, on any platform.

## Testing without a peripheral

`Scripts/ble-test-peripheral.swift` (macOS), `.py` (Linux/BlueZ) and
`ble-test-peripheral-android/` all publish the same service: a write
characteristic that echoes to a notify characteristic, plus a read returning a
fixed string, plus a counter every two seconds. One round trip proves write and
notify at once.

Radio range, not the network, is what bounds this — a fixture only helps the
machines within a few metres of it. Prefer the Android one where you can: it's
portable, and it's the only LE-only one (see the BlueZ note above).

`Scripts/verify-linux-ble.sh` drives the whole surface on a Linux box against
whichever fixture is in range, including the undeclared and vetoed cases.
