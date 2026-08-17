# Proposal: Serial port plugin (`serial.*`)

> **Status: proposed**, not scheduled and with no adopter asking for it yet.
> The README roadmap currently has platform audio at #3 and no serial entry, so
> this is a re-prioritization to decide rather than a pickup.
>
> Serial was already weighed once and set aside, in
> [ble-plugin.md](ble-plugin.md#alternatives-considered): *"iOS has no USB serial
> path for a non-MFi device at all, so it would be desktop-and-Android-only —
> solving less of the actual problem for comparable effort."* That was the right
> call between the two. It isn't a reason not to do serial next, and this
> proposal argues why.

## The problem

A page in a swift-pwa shell cannot open a serial port.

**Web Serial is not a fallback.** It exists in Chrome and Edge on the desktop and
in none of the webviews this project ships on — not WKWebView, not WebKitGTK, not
Android's embedded `WebView` (and not Chrome for Android either; Web Serial is
desktop-only in Chromium). Even where the engine has the code, the API is built
around a device-chooser UI the embedder has to supply, which an embedded webview
does not. WebView2 is the one cell worth *checking* rather than assuming — see
[Open questions](#open-questions).

So this is the same shape as `ble.*`: not a web API answered properly, but the
difference between a capability existing and not existing. And the same shape as
`process.*` and `net.*` structurally — an opt-in plugin with an injected backend.

## Who it's for

GRBL lasers and CNC controllers, 3D printers taking GCode over USB, Arduino and
ESP32 boards, pen plotters, lab instruments, GPS and LiDAR modules, receipt and
label printers.

That list overlaps `ble.*`'s consumers heavily — a lot of this hardware ships
both a radio and a USB port, and the USB port is the one that runs an order of
magnitude faster and doesn't drop when someone walks between the machines. A
sender that streams a job to a machine is the shape both plugins exist for.

Unlike `ble.*`, **no concrete adopter is asking**. That is the main thing this
proposal lacks, and it should decide the Android question below rather than being
papered over.

## iOS genuinely can't — and that needs a different error

There is no public serial API on iOS. A USB or Lightning accessory can only be
reached through ExternalAccessory, which requires the *peripheral's* manufacturer
to be enrolled in Apple's MFi program with an Apple authentication coprocessor in
the device. That is a hardware licensing wall, not our debt: no amount of work in
this repo makes a generic CH340 dongle reachable from an iPhone.

This is exactly the distinction
[ble-plugin.md](ble-plugin.md#why-desktop-is-in-scope) drew, landing on the other
side of it. iOS cannot spawn a subprocess, so `process.*` answering
`E_UNIMPLEMENTED` there is honest and the model an adopter forms stays correct.
Serial on iOS is the same: honest, permanent, and worth saying plainly in the
docs rather than encoding as a runtime condition.

Which means **two error codes that must not be confused**:

| Code | Means |
| :--- | :--- |
| `E_UNIMPLEMENTED` | iOS. This OS, forever. A design fact the page can branch on at startup. |
| `E_SERIAL_UNAVAILABLE` | **This machine, right now**: no port by that id, the cable was pulled, the user isn't in `dialout`, the Android device refused the USB permission. |

Collapsing them is the failure `ble.*` was careful to avoid, and it's easier to
get wrong here because there is a real permanent case to model.

## Why the bridge is already the right shape

An open port is a duplex session, and [duplex sessions
shipped](bidirectional-bridge-sessions.md). `serial.open` maps onto
`registerSession` the way `ble.connect` does: open with the port and its line
settings, push writes in, take incoming bytes and state changes downstream, close
to hang up. Port lifetime is tied to session lifetime by the bridge, which is the
bookkeeping every adopter would otherwise hand-roll — and for a serial port that
bookkeeping is worse than for BLE, because a file descriptor left open blocks the
next process that wants the device.

Enumeration is a plain `invoke`. No new bridge primitives. This is a plugin.

## JS API

```js
const ports = await __SWIFT_PWA__.invoke('serial.list', {});
// [{ id, name, vendorId?, productId?, serialNumber?, transport }]

const port = __SWIFT_PWA__.session('serial.open', {
    id,
    baudRate: 115200,
    dataBits: 8, stopBits: 1, parity: 'none',   // defaults, shown for completeness
    flowControl: 'none',                        // 'none' | 'hardware'
    dtr: true, rts: true,                       // asserted on open unless told otherwise
    readDelimiter: '\n',                        // optional; frames incoming bytes
}, {
    onChunk: (event) => {
        // { kind: 'open',     settings }
        // { kind: 'data',     value }               base64
        // { kind: 'overflow', droppedBytes }
        // { kind: 'ack',      token }
        // { kind: 'state',    open, reason }
        // { kind: 'failed',   message, token? }
    },
    onError: (error) => {},   // the session is over
    onEnd: () => {},
});

port.push({ kind: 'write',   valueBase64, token: 1 });
port.push({ kind: 'signals', dtr: false, rts: false });
port.push({ kind: 'break',   durationMs: 250 });
port.push({ kind: 'flush',   input: true, output: true });
port.close();   // closes the fd
```

The optional `token`, echoed on the `ack` or `failed` that answers a push, and
the rule that **a failed operation is a downstream event rather than a stream
error**, are both carried over from `ble.*` unchanged — same reasoning, and a
second surface inventing a second convention would be its own cost.

## The genuinely new problem: throughput

`ble.*` was explicitly sold as *not* a bulk-transfer path, and its traffic is
20–244 byte notifications arriving tens of times a second. Serial is a different
regime: 115200 baud is 11.5 KB/s sustained, 921600 is 90 KB/s, and a CDC-ACM
device on USB Full Speed will go faster if asked. Base64 costs 4/3 before JSON
string-escaping, and every frame takes a hop to the UI thread.

Three decisions fall out, none of which BLE forced:

1. **Coalescing.** One bridge frame per read syscall would melt. Deliver on
   whichever of a byte threshold or a short timer comes first — something like
   8 KB or 16 ms — so an idle port still delivers a single prompt character
   promptly while a firehose batches. Both numbers want measuring, not guessing.
2. **Backpressure.** If the page can't keep up, something has to give. The
   proposal: a bounded buffer (default ~1 MB), then drop the **oldest** bytes and
   emit `overflow` with a count. A page tailing a log wants the newest bytes, a
   page speaking a protocol should be draining fast enough, and *neither* is
   served by unbounded growth or by silent loss. The event is the point — a
   protocol page can treat `overflow` as fatal and resync.
3. **Where the ceiling actually is.** Measure the bridge's real sustained
   throughput before documenting a supported baud rate. If it tops out well below
   921600 the docs should say the number rather than let an adopter discover it
   as corruption under load.

## Framing

A serial port is a byte stream with no message boundaries; BLE handed us
characteristic-shaped messages for free. Nearly every consumer wants lines — GRBL,
GCode, AT commands, `println` debugging — and nearly every page reimplements
partial-chunk buffering and gets it wrong at exactly the boundary that only shows
up under load.

So: raw `data` events by default, and an optional `readDelimiter` that makes the
backend emit one event per delimited frame. Small, and it removes the most
reliably-rewritten twenty lines in this domain.

## Control signals are a footgun

**Asserting DTR resets an Arduino.** That is how the bootloader is entered, and
it means a page that merely opens a port to watch output reboots the device it's
watching. So `dtr` and `rts` are explicit on open and changeable afterwards,
rather than implied.

Related, and the reason for a specific implementation choice on macOS: `/dev/tty.*`
blocks on carrier detect, `/dev/cu.*` (call-out) does not. The backend uses `cu`,
and on Linux sets `CLOCAL` for the same reason — otherwise `open()` hangs
forever on a cable with no modem on the other end, which is every cable.

## Platform parity — the real cost

| Platform | Backend | Cost |
| :--- | :--- | :--- |
| macOS | IOKit (`IOServiceMatching(kIOSerialBSDServiceValue)`) to enumerate and read vendor/product metadata, then termios + POSIX read/write on `/dev/cu.*` | Low. The reference implementation. |
| Linux | Walk `/sys/class/tty` for entries with a real `device/` symlink; termios | Low, and **no new dependency** if we read sysfs rather than link libudev. |
| Windows | `CreateFileW(\\.\COMn)`, `SetCommState` (DCB), `SetCommTimeouts`, overlapped reads; enumerate via `SetupDiGetClassDevs(GUID_DEVINTERFACE_COMPORT)` | Moderate. Plain Win32 in the existing shim — and notably *not* WinRT, so none of the C++-exception-across-the-C-ABI hazard that killed the process during `ble.*`. |
| Android | `UsbManager` host mode, wire protocol implemented by us | **Expensive.** See below. |
| iOS | — | Can't. `E_UNIMPLEMENTED`. |

### Android is the expensive cell

An Android app has no `/dev` access, so there is no port to open. USB host mode
gives you enumeration, a per-device permission dialog, and raw bulk endpoints —
and then you implement the serial protocol yourself:

- **CDC-ACM** is standardized: two control transfers (`SET_LINE_CODING`,
  `SET_CONTROL_LINE_STATE`) plus bulk in/out. Covers modern native-USB boards —
  Leonardo, Uno R4, ESP32-S3, Pi Pico, most 3D printer boards.
- **CH340, CP210x, FTDI** are each vendor-specific control transfers with their
  own baud-divisor arithmetic, and each needs a physical device to verify against.

`usb-serial-for-android` is the standard answer and it is a runtime dependency,
against the standing rule.

The honest read: CDC-ACM alone would ship an Android backend that fails on the
cheapest and most common hardware, because CH340 and CP2102 are what's inside
every £3 dongle and every Nano clone. So a *credible* Android cell is CDC-ACM
plus those two — three protocols, three devices to buy, three to verify.

This does not violate the one-API rule. All four platforms with a stack get the
same API, and an unsupported chip is a *this device* failure, not a *this
platform* one. But it is the largest single slice of the work, and with no adopter
asking, **whether Android is in v1 at all is the decision this proposal most
wants made.** Desktop-first here would be "we haven't", honestly labelled — which
is a different thing from shipping it and hoping nobody notices.

## Permissions

A new `serial` case on
[`DevicePermission`](../../Sources/SwiftPWACore/Permissions/PermissionPolicy.swift),
declared under `permissions.device` alongside `bluetooth` — no page can ask for
it — and added to `PermissionCheck.deviceNames` in
[PermissionCheck.swift](../../Sources/SwiftPWACLISupport/Manifest/PermissionCheck.swift),
which is where the build-time cross-check picks it up for free.

What each platform needs downstream:

- **macOS** — no usage-description string exists for serial. Under the App
  Sandbox it's the `com.apple.security.device.serial` entitlement, which arrives
  through `build --entitlements` (the app's own file), so this is a docs line
  rather than a bundler change. Unsandboxed, nothing.
- **Linux** — no OS concept; it's group membership on the device node, `dialout`
  on Debian/Ubuntu. A refusal is `EACCES`, and the `reason` string should say
  which group to join. That single sentence is most of this backend's support
  burden.
- **Windows** — nothing for a portable `.exe`. An MSIX build needs
  `<DeviceCapability Name="serialcommunication">` with a child `<Device>`
  element, which is more structure than `bluetooth`'s one-liner in
  [AppxManifestGenerator.swift](../../Sources/SwiftPWACLISupport/Bundlers/AppxManifestGenerator.swift).
- **Android** — `<uses-feature android:name="android.hardware.usb.host">`, and
  **no `uses-permission` at all**. The grant is `UsbManager.requestPermission`,
  per device, at attach time.

That last one is a genuine mismatch with the model: every permission the policy
knows is app-level and asked once, and this one is **per-device and re-asked when
you unplug and replug**. It's worth deciding deliberately whether `serial` even
belongs in `DevicePermission` or is better modelled as an app-level *declaration*
with a per-device grant underneath. See [Open questions](#open-questions).

## Scope for v1

In: enumerate, open, close, read, write, baud rate / data bits / stop bits /
parity / flow control, DTR and RTS, break, flush, delimiter framing, coalescing
and the overflow contract.

Out: iOS (can't), MFi / ExternalAccessory, hotplug watching, modem-status change
events (CTS/DSR/RI/DCD transitions), RS-485 transceiver direction control,
non-standard custom baud rates, and Bluetooth SPP as a transport. Each is real;
none is needed to drive a machine, and `serial.*` shouldn't grow them
speculatively.

## Verification

Better than `ble.*` in one way and worse in another.

**Better:** a pty pair (`socat -d -d pty,raw,echo=0 pty,raw,echo=0`) is a real
serial-shaped device on macOS and Linux, so enumeration, open, read, write,
close, delimiter framing, coalescing and the overflow path all verify with **no
hardware at all** — including in CI, which nothing in `ble.*` could do. Baud,
parity and DTR are inert on a pty, so they need the real thing.

**Worse:** where BLE was bounded by radio range, serial is bounded by a physical
cable into each machine. A USB-serial dongle with a TX–RX loopback jumper
verifies the whole driver path with no second device and measures round-trip
throughput honestly, but you need one per box — this Mac, both Linux boxes, a
Windows box, plus an OTG cable and a dongle for Android. An ESP32 or Arduino as a
real talker also exercises the DTR-reset behaviour deliberately, which a loopback
can't.

Nothing is attached to this Mac today: `/dev/cu.*` is `Bluetooth-Incoming-Port`
and `debug-console`.

## Alternatives considered

- **Web Serial.** Absent from four of five webviews, and dependent on a chooser
  UI an embedded webview has no way to present. Worth confirming on WebView2, but
  one Chromium cell wouldn't change the answer.
- **`process.*` plus a CLI tool.** An app could shell out to `stty` and `cat`.
  Desktop-only (so *worse* than this proposal's coverage, since Android has no
  subprocess either), requires a tool on `PATH`, and has no framing, no
  backpressure and no line-signal control. Strictly worse.
- **`ble.*` against the same hardware.** Plenty of these machines expose a
  serial-over-BLE characteristic, and `ble.*` already ships. But throughput is
  roughly a tenth, and a great deal of hardware has a USB port and no radio at
  all.
- **Do nothing.** Defensible while no adopter is asking. The cost is that the
  hardware-shaped apps this project keeps attracting hit a wall at the most
  ordinary connector on the device.

## Open questions

- **Does WebView2 expose Web Serial?** Cheap to check on the Windows box: load a
  page calling `navigator.serial.requestPort()` and see whether the API exists and
  whether a chooser appears. It won't change the recommendation, but it belongs in
  the docs.
- **Where does the per-device grant live?** Android's USB permission is per-device
  and re-asked on replug, which no other entry in `DevicePermission` behaves like.
  Decide before the Android PR, since it shapes both the policy type and what a
  veto means.
- **Is Android in v1?** Three wire protocols and three devices to buy, for the
  platform where this capability is least used. Desktop-first is defensible here
  in a way it explicitly wasn't for `ble.*` — but it must be labelled "we
  haven't", not dressed as a platform limit.
- **Coalescing and buffer defaults.** 8 KB / 16 ms / 1 MB are starting points to
  measure, not conclusions.
- **Is `serial.list` enough to build a picker?** A `/dev/cu.usbserial-1420` means
  nothing to a user. IOKit, sysfs and SetupAPI can all supply vendor, product and
  serial-number strings; confirm all three do before promising the field.
- **Hotplug.** Leave the page to re-`list`, or add a `serial.watch` subscribe?
  Out of scope for v1, but the answer affects whether `list` stays an invoke.
