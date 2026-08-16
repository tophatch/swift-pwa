# Talking to a Bluetooth peripheral

**Who this is for:** you have a device — a plotter, a sensor, a laser cutter, a
dev board — and you want your page to drive it. This guide connects to one,
subscribes to what it says, and writes to it, on macOS, iOS, Linux, Windows and
Android.

> Needs swift-pwa **0.10.1 or newer**. The reference is
> [docs/bluetooth.md](../bluetooth.md); this is the hands-on path.

---

## Start here: there is no fallback

Every other native capability in this runtime shadows a web API. Bluetooth
doesn't:

- **Web Bluetooth has never shipped in WKWebView or Safari.** Not disabled, not
  flagged — not implemented.
- **Android's embedded `WebView` doesn't expose it either.** Chrome does. The
  WebView your app gets does not.

So `ble.*` isn't a nicer version of something. It's the only version. That also
means there's nothing to feature-detect against and no graceful degradation to
write — if the app doesn't ship the plugin, the page can't reach a peripheral at
all.

---

## Part 1 — Something to talk to

Bluetooth work is hard to start because you need a peripheral before you can
write a line of client code. This repo ships one, three times over:

```bash
swift Scripts/ble-test-peripheral.swift          # macOS
python3 Scripts/ble-test-peripheral.py           # Linux (BlueZ)
cd Scripts/ble-test-peripheral-android && ./gradlew installDebug   # Android
```

All three publish the same thing:

| | |
| :--- | :--- |
| service | `5057ab00-0000-4000-b000-000000000001` |
| `…0002` | write — echoes what you write to `…0003` |
| `…0003` | notify — that echo, plus a counter every 2 s |
| `…0004` | read — the string `swift-pwa` |

The echo is deliberate: one round trip proves write *and* notify at once.

**Run it on a different machine from the one you're testing.** A host never
hears its own advertisement. And range is what matters, not the network — a
fixture on your desk is invisible to a box in the next room, however good your
WiFi is.

---

## Part 2 — Turn the plugin on

```swift
ctx.permissions.declare(.bluetooth)
ctx.use(BLEPlugin(SystemBluetooth()))
```

```json
"permissions": {
  "device": { "bluetooth": { "reason": "Send jobs to your plotter." } }
}
```

Two declarations, and `swift-pwa build` fails if they disagree — the Swift one
is the runtime ceiling, the `pwa.json` one shapes the platform artifact (Android
manifest entries, Apple's usage description, the MSIX capability). Note the key
is **`device`**, not `web`: `permissions.web` is for things a page can ask for
on its own, and no page can ask for this.

Getting it wrong is worth seeing once. Delete the Swift line and build:

```text
pwa.json and the app disagree about permissions:
  'bluetooth' declared in pwa.json but never passed to `ctx.permissions.declare`,
so the app refuses it at runtime.
```

And putting it under the wrong key tells you which one to use, rather than
implying you typo'd:

```text
pwa.json's permissions.web names 'bluetooth', which belongs under
permissions.device instead. No webview here exposes it to a page — it's
reached through a plugin.
```

---

## Part 3 — Find the device

Ask whether Bluetooth is even on before you scan. This is not defensive
programming: **a switched-off adapter scans perfectly happily and finds
nothing**, which your page cannot tell from "nothing is nearby".

```js
const { isAvailable, reason } = await __SWIFT_PWA__.invoke('ble.availability', {});
if (!isAvailable) return show(reason);   // "Bluetooth is switched off"
```

Then scan:

```js
const seen = new Map();
const stop = __SWIFT_PWA__.subscribe('ble.scan', { services: [SERVICE] }, (p) => {
    seen.set(p.id, p);           // raw results — de-duplicate here
    render([...seen.values()].sort((a, b) => b.rssi - a.rssi));
});
```

Results arrive **raw**, one per advertisement. That looks like noise until you
build a picker: RSSI updating is what lets the nearest device float to the top,
and a runtime that de-duplicated would have thrown that away.

Two things to know about filters:

- **A service filter finds fewer peripherals, not more.** A device only appears
  if it *advertises* that service, and many only mention their services after
  you connect. Scan unfiltered while you're exploring.
- **UUIDs come back as full 128-bit lower-case**, always, on every platform.
  You can pass `'ffe1'` in — it's expanded for you — but comparisons on the way
  out should use the long form. This is the single most likely reason for code
  that works on your Mac and silently matches nothing on Android.

---

## Part 4 — Connect, and stay connected

A connection is a duplex session, because that's what a connection is:

```js
const link = __SWIFT_PWA__.session('ble.connect', { id: peripheral.id }, {
    onChunk: (event) => {
        switch (event.kind) {
        case 'ready':
            // Handles are new every time this fires — see below.
            link.push({ kind: 'subscribe', characteristic: NOTIFY, token: 1 });
            break;
        case 'ack':
            if (event.token === 1) {
                link.push({ kind: 'write', characteristic: WRITE,
                            valueBase64: btoa('ping'), withResponse: true, token: 2 });
            }
            break;
        case 'notify':
            console.log('device says', atob(event.value));
            break;
        case 'state':
            setStatus(event.connected ? 'connected' : 'reconnecting…');
            break;
        case 'failed':
            console.warn(event.message);   // this operation failed; the link is fine
            break;
        }
    },
});
```

Three things in there are worth dwelling on.

**`token` is how you know which push was answered.** It's optional, and without
it a `withResponse: true` write — whose whole point is that the peripheral
acknowledged — has nowhere to report success.

**`failed` is an event, not an error.** A rejected write doesn't tear down the
link. An `onError` means the session itself is over.

**`ready` fires again after a reconnect.** A peripheral going out of range emits
`state{connected:false}` and the runtime keeps trying; when it comes back you
get a fresh `ready` with newly discovered services, because the old handles no
longer resolve. Re-subscribe there — as the snippet does — rather than assuming
your subscription survived. Closing is how you give up:

```js
link.close();   // disconnects, and releases the peripheral for everyone else
```

That last part matters more than it sounds: most peripherals accept **one**
central at a time, so a link you forgot to close locks out your own next run.

---

## Part 5 — Ship it

The build emits what each platform needs from your one `reason` string, but the
platforms differ in ways that will reach your users:

| | What happens |
| :--- | :--- |
| **macOS / iOS** | The OS prompts once, showing your `reason` verbatim. |
| **Android** | The OS prompts on first use. |
| **Linux** | No prompt — polkit governs it and a desktop user is normally already allowed. |
| **Windows** | A portable `.exe` needs nothing. An **MSIX** build is capability-gated. |

That last row is a trap with a happy ending: an app that declares Bluetooth in
Swift but not in `pwa.json` works perfectly when run from a folder and fails
once installed as an MSIX. The build's cross-check is what catches it, which is
the whole reason the declaration lives in two places.

### Traps worth knowing before you hit them

- **Android's Bluetooth permissions changed completely at API 31.** Before it, a
  BLE *scan* required `ACCESS_FINE_LOCATION` — scanning reveals where you are.
  The bundler emits the modern pair with `neverForLocation` (your app promising
  not to infer a position from scan results) plus the superseded ones capped at
  API 30, so both eras work and a modern device isn't asked for location.
- **Connecting from Linux to a phone or a Mac fails.** Those are dual-mode: they
  advertise over LE from the same address their classic radio uses, so BlueZ
  keeps one device object with both identities and tries classic Bluetooth
  first, ending at `br-connection-key-missing`. Pair it once and it works. A
  real LE-only peripheral never takes that path — which is why the Android
  fixture above is the best one to test Linux against.
- **A characteristic that "can't notify" usually has no CCCD.** Subscribing
  works by writing the Client Characteristic Configuration descriptor; a
  peripheral that didn't publish one can't be subscribed to anywhere.
- **Don't store a peripheral id anywhere shared.** Apple hands out a per-host
  UUID, the others a Bluetooth address. Both are stable on that one machine and
  meaningless on any other.

---

## See it running

The **Bluetooth** card in [`Examples/HelloPWA`](../../Examples/HelloPWA) does
everything above, and works without setting up a fixture at all: scan, then pick
anything that turns up — a watch, headphones, a sensor — and it reads that
device's GATT tree, which is where any real conversation starts. It only
*writes* when the peripheral is one of the fixtures, which then gets the full
subscribe / `ping` / read round trip.

```bash
cd Examples/HelloPWA
swift run swift-pwa build --target macos --configuration debug
open build/macos/HelloPWA.app
```

## Where to go next

- [docs/bluetooth.md](../bluetooth.md) — the full reference, including what each
  backend does and every error code.
- [Using the camera and location](using-the-camera-and-location.md) — the rest
  of the device surface, and the permission model this shares.
- [Talking to the native side](talking-to-the-native-side.md) — for a device
  this surface doesn't cover, that's how you add your own command.
