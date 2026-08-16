# Proposal: a unified device surface — `permissions.*` and `geo.*`

> **Status: proposed.** Written from measurements on real hardware on all five
> platforms rather than from reading the backends — the reading came second, and
> confirmed it. Measuring changed the conclusion twice; see
> [What the deliverable actually is](#what-the-deliverable-actually-is), which is
> the part to read if you read only one section.

## The problem

**No backend installs a permission handler.** Not one of the five. On three of
them the platform's default answer is then *deny*, silently; on the other two the
webview supplies its own prompt and everything works.

The result is that the same page behaves differently on every platform for
reasons the adopter cannot see, and the failures are worse than a missing
capability because the API is present. A page feature-detects
`navigator.geolocation`, gets `true`, calls it, and receives `PERMISSION_DENIED`
— a code that means *the user said no*. The user was never asked. Whatever the
app shows next ("enable location in Settings") sends them somewhere that cannot
fix it.

**The gaps are narrower and more specific than "nothing works"**, which is where
this proposal started before everything was measured:

- **Capture (camera / microphone) is broken on Android and Linux.**
- **Geolocation is broken on macOS, Linux and Android.**
- **Linux is the worst platform — nothing works there.** macOS is the best of the
  broken ones: only location.
- **Web notifications are unusable everywhere** — denied where the API exists,
  absent on iOS and Android. The shipped `notifications.*` plugin already covers
  that surface, so there is nothing to do.

### Measured

A scaffolded app (`swift-pwa init`) — not an Example, which carry fallbacks the
scaffold never emits — bundled per platform with the usage descriptions present,
and run on real hardware in every column. Read via `swift-pwa drive` on macOS,
Linux and Windows, CDP on Android, and an HTTP report from the page on iOS:

| | iOS 27 / WKWebView | macOS 15 / WKWebView | Linux GTK3 + GTK4 | Android 16 / WebView | Windows 11 / WebView2 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `geolocation.getCurrentPosition` | ✅ **prompts** → real fix, 7.9 m | ❌ `code 1 "User denied"` in **1.0 ms** | ❌ identical, **1 ms** (GTK3) / **2 ms** (GTK4) | ❌ identical | ✅ **prompts** → real fix, 140 m |
| `getUserMedia({audio:true})` | ✅ **prompts** → live track | ✅ works — a live track | ❌ `NotAllowedError` in **83 ms** (GTK4, real mic attached) | ❌ `NotAllowedError` in **18 ms** | ✅ **prompts** → live track |
| `getUserMedia({video:true})` | — | — | — | ❌ `NotAllowedError` in **51 ms** | — |
| `Notification.requestPermission()` | API absent entirely | `"denied"`, no prompt | `"denied"`, no prompt | API absent entirely | `"denied"`, immediately |
| Web Bluetooth / USB / Serial / HID / NFC | absent | absent (WebKit never shipped them) | absent | absent (Chrome has them; the embedded WebView doesn't) | absent |

The two ✅ columns are the same mechanism: **the webview supplies its own prompt**
when the embedder registers no handler. iOS asked for location and microphone on a
freshly installed app and granted both once tapped; Windows did the same. Neither
needed a line of code from us.

### Ruling out "the machine just has location switched off"

The obvious alternative explanation for three denied columns is that location is
disabled at the OS level on those machines. It isn't, and the checks are worth
recording because they're the ones to repeat if this is ever re-measured.

- **macOS — settled by a positive control.** **Safari** on the same Mac, same
  system settings, same WebKit engine, requesting location from a `localhost`
  page: **prompted, and returned a 35 m fix in 6.1 s.** Our WKWebView app on that
  same machine is denied in 1.0 ms with no prompt. Location Services is on and
  working; the difference is the embedder, not the system.
- **Linux — settled by a permission with nothing behind it.** No WebKitGTK browser
  is installed on either box, so there's no Safari-equivalent control. But
  `Notification.requestPermission()` is denied there instantly too, and
  notifications need no hardware, no daemon and no privacy toggle — there is
  nothing to have switched off. Supporting evidence: **GeoClue 2.7.2 is installed
  and D-Bus-activatable** on both boxes, so a provider exists; and the error is
  `code 1 PERMISSION_DENIED`, not the `code 2 POSITION_UNAVAILABLE` a missing or
  failing provider produces.
- **Android** — the manifest doesn't request location or capture at all, so the
  app could not have been granted them regardless of device settings.

### How "no prompt" was established

Claiming a prompt *didn't* appear is the easy thing to get wrong — nobody was
sitting in front of three of these machines, and an unanswered prompt and a
silent denial look similar from a distance. Three independent checks, because the
first one alone is only suggestive:

1. **Settled vs pending.** A prompt that is waiting leaves the promise *pending*.
   Every refusal above is a **rejection**, which means nothing was waiting for
   anyone. The working platforms are the contrast, and they behave exactly as you'd
   expect: Windows stayed pending for 25+ seconds until a human clicked *Allow*,
   and iOS resolved at 6–7 s, the time it takes to read a dialog and tap it.
2. **Latency.** The rejections land in **1–83 ms** — 1–2 ms for geolocation on
   macOS and Linux, 18–83 ms for capture on Android and Linux — against
   **6,100–7,500 ms** for the platforms that ask a human. No prompt is presented
   and answered in a millisecond; two to three orders of magnitude separate the
   two behaviours.
3. **The window tree.** On Linux, `xwininfo -root -tree` against the app's X
   display is **byte-identical before and after** the request — no dialog window
   is ever created. On Android a `screencap` taken while the request was in flight
   shows the page and no dialog. (Neither an in-app `drive shot` nor a WebView2
   window enumeration can settle this, because both platforms draw permission UI
   inside their own layers; that's why Windows needed a human instead.)

Notes on reading that table honestly:

- **Android is the decisive row.** `enumerateDevices()` on the test device
  returns `audioinput`, `videoinput`, `audiooutput` — the hardware is there and
  visible to the page — and both capture requests are refused in tens of
  milliseconds with nothing drawn on screen. **Camera and microphone do not work
  in a swift-pwa app on Android.**
- **Android needs two fixes, not one.** Beyond the missing `WebChromeClient`, the
  scaffold's manifest requests only `INTERNET`, `POST_NOTIFICATIONS`,
  `USE_BIOMETRIC` / `USE_FINGERPRINT` and `REQUEST_INSTALL_PACKAGES` — no
  `CAMERA`, no `RECORD_AUDIO`, no location. Wiring the handler alone would just
  move the denial one layer down.
- **The macOS geolocation result is not a TCC artifact.** The first run used an
  unbundled `swift run` binary, where TCC can deny before WebKit is consulted.
  Rebuilt as a bundle carrying `NSLocationWhenInUseUsageDescription` — same
  denial, no prompt. WKWebView exposes no public API to grant geolocation **on
  macOS**; on iOS the same framework prompts and grants, which is the asymmetry
  this document exists to record.
- **Linux capture needed real hardware to measure, and then it failed like
  Android.** The first attempt ran on a box with no microphone: WebKit logged
  *"Audio capture was requested but no device was found amongst 0 devices"* and
  returned `OverconstrainedError` — absent hardware, reached *before* any
  permission decision, so it proved nothing. With a headset attached to the GTK4
  box (and `XDG_RUNTIME_DIR=/run/user/1000` exported so the app can reach the
  PulseAudio socket from an SSH session), the same call returns
  **`NotAllowedError` in 83 ms** with the window count unchanged at 4. The error
  *changed class* once hardware existed — from "there is no device" to "you may
  not" — which is what distinguishes the two explanations. `enumerateDevices()`
  confirms the page can see it: `audioinput:(no label)`, the empty label being
  exactly how an ungranted device presents.
- **Notifications are the clean cross-check on the WebKit backends.** They need no
  hardware, and on WebKitGTK they travel the same `permission-request` signal as
  capture and geolocation. Denied without a prompt on both, which is what makes
  this a general gap rather than a geolocation quirk. On Android the `Notification`
  constructor doesn't exist at all — the WebView has never implemented it — so the
  native `notifications.*` plugin is the only path there, as shipped.
- **iOS and macOS disagree, which kills the tidiest version of this story.** An
  earlier draft of this proposal asserted that "WKWebView exposes no public API to
  grant geolocation" and built the `geo.*` design on it. That is true on **macOS**
  and false on **iOS**: the same framework family, on a freshly installed app,
  prompted for location and returned a 7.9 m fix. So the boundary is not
  Apple-vs-the-rest; it is **macOS + Linux** on one side and iOS + Windows on the
  other. Worth stating plainly because it was wrong in writing before it was
  measured, and it would have justified building a plugin for a platform that
  didn't need one.
- **Windows and iOS are already correct, and they are the model for the rest.**
  With no handler registered, both show their own prompt and leave the request
  pending on the user. On Windows that was proven the hard way — the first run was
  on a locked box, where geolocation returned `code 3 TIMEOUT` (not `code 1
  DENIED`) and the capture promise was unsettled 25 seconds later; unlocking and
  clicking *Allow* resolved **both** already-pending promises to
  `{ok: true, tracks: 1}`. A request a click can complete minutes later was never
  stuck; it was waiting, which is what should happen.
- **So neither of those platforms needs an implementation — only a regression
  test.** What the broken backends have to build is what these two supply for free.
- **Geolocation works on exactly the platforms that ask the user**, and is denied
  on exactly those that don't. That contrast is the clearest signal in the table:
  nothing about macOS or Linux prevents the capability — only the missing question.
- **iOS appears to re-ask on every launch.** Both runs of a freshly installed app
  took 6–7.5 s to resolve, consistent with a prompt each time rather than a
  persisted grant (WKWebView's media-capture permission is per-session unless the
  embedder persists it). Not load-bearing for this proposal, but it is a real UX
  question for any app that captures — worth confirming before designing around it.

### Confirmed in the source

- **Apple** — no `WKUIDelegate` media-capture method anywhere in
  [`SwiftPWAWebKit`](../../Sources/SwiftPWAWebKit/).
- **Android** — [`AndroidTemplates.swift`](../../Sources/SwiftPWACLISupport/Bundlers/AndroidTemplates.swift)
  sets **no `WebChromeClient` at all** (only `mediaPlaybackRequiresUserGesture`).
  Without one, `onPermissionRequest` and `onGeolocationPermissionsShowPrompt`
  take their default, which is to deny — which is exactly what the device
  measured.
- **Linux** — neither GTK backend connects WebKitGTK's `permission-request`.
- **Windows** — no `PermissionRequested` handler on the WebView2 controller, and
  it needs none: WebView2's default is to show its own prompt, measured working
  for both capture and geolocation.

## Why this outranks a new capability plugin

`ble.*` adds something that isn't there. This *repairs* things adopters already
believe they have, and the belief is reasonable — these are ordinary web APIs that
work in every browser. It is the same class as the last several releases' best
finds (a bundled app that only ran on the build machine, a driver keyboard that
sent dead keys): the surface says yes, the behaviour says no, and the error points
somewhere unhelpful.

It also corrects a stale premise in the README roadmap, which defers platform
audio on the grounds that "the WebView's `getUserMedia` / `MediaRecorder` already
cover the in-page cases". They cover them only where something answers the
permission request — which today is Windows and nowhere else.

And it makes the *same source* behave differently on different platforms for no
reason the adopter can see: the identical page gets a live microphone track on
Windows and `NotAllowedError` on Android. That is the failure this project exists
to prevent.

## What the deliverable actually is

The measurements above read as a list of per-platform defects, and fixing them
one by one would leave the adopter exactly where they started: a page that
behaves differently on each OS, for reasons visible only to whoever read this
document. The deliverable is **one device surface that behaves the same
everywhere** — the same argument [ble-plugin.md](ble-plugin.md) makes for
Bluetooth. The per-backend work below is how that gets built, not what it is.

But "unify everything behind a plugin" is the wrong conclusion too, and the
distinction is what makes this tractable:

| Shape | Answer | Why | Examples |
| :--- | :--- | :--- | :--- |
| **Data-shaped** — small, serializable payloads | **A plugin.** Unify completely; document it as *the* path. | It crosses a JSON bridge with no loss, so one API can behave identically on five backends. | `geo.*`, `ble.*`, NFC, sensors, `notifications.*` (already shipped) |
| **Stream-shaped** — live, high-bandwidth | **Keep the web API.** Unify only the *permission* in front of it. | A `MediaStream` feeds `<video>`, WebRTC, `MediaRecorder`, WebAudio. Routing frames over the bridge would mean rebuilding the media pipeline, and worse than the platform's. | `getUserMedia`, media playback |

So the unified surface is two pieces:

1. **`permissions.*`** — one declaration in `pwa.json` and one runtime API, with
   identical semantics on all five platforms. The page's *own* `getUserMedia` then
   works consistently, because the thing that differed was never the capture API;
   it was whether anyone answered the request.
2. **Native plugins for the data-shaped capabilities**, which is the pattern this
   project already uses: **`notifications.*` exists precisely because the web
   Notification API is denied on three platforms and absent on two.** `geo.*` is
   the same story with the same justification, and `ble.*` is the case where no
   web API exists at all.

That reframing also demotes most of what this document measured. Android capture
is a real outage and should be fixed first. The rest is the price of not having a
single surface — which is the thing worth building.

## Design

### Per-backend seam

| Platform | Status | Work |
| :--- | :--- | :--- |
| **iOS** | ✅ already prompts and grants | **None.** Add a regression test. |
| **Windows** | ✅ already prompts and grants | **None.** A handler on `ICoreWebView2::add_PermissionRequested` would only *remove* working behaviour. Add a regression test. |
| **Android** | ❌ capture and location both denied | The whole slice: a `WebChromeClient` (`onPermissionRequest` + `onGeolocationPermissionsShowPrompt`), the manifest entries, and an OS **runtime** permission request behind them. |
| **macOS** | ❌ location denied; capture already works | Geolocation only. WKWebView offers no public grant path on macOS, so this is `geo.*` rather than a bridged web API. |
| **Linux** | ❌ **everything denied** — location *and* capture | `permission-request` on both GTK backends — one signal, subtype-switched (`WebKitUserMediaPermissionRequest`, `WebKitGeolocationPermissionRequest`, …). Cheapest fix of the three broken platforms: one signal covers every permission type. |

The Android runtime-request helper is shared ground with
[ble-plugin.md](ble-plugin.md), which needs the same thing for `BLUETOOTH_SCAN` /
`BLUETOOTH_CONNECT`. Whichever lands first builds it. `POST_NOTIFICATIONS` in
`AndroidTemplates.swift` is the existing single-permission precedent, including
its in-flight-request guard.

### Policy: who decides

Three options were considered — always allow; a declaration in `pwa.json`; a
runtime callback into the app. The recommendation is the **two-gate** shape the
agent surface already establishes:

1. **A declaration in `pwa.json` is the build-time ceiling.** Undeclared stays
   denied, so no existing app silently gains a capability when this ships.
2. **An app-level veto is the runtime ceiling.** An app can refuse a permission
   itself — for its own in-app privacy switches — and a vetoed permission is
   refused *without prompting*, so the user isn't asked for something the app has
   already ruled out.
3. **Otherwise the OS prompt does the asking.** The runtime never invents consent
   UI; it forwards to the platform's own prompt and relays the answer.

```json
"permissions": {
  "web": ["camera", "microphone", "geolocation", "notifications"]
}
```

One declaration should drive **every** platform artifact: the Android
`uses-permission` entries, the Apple usage-description strings, the MSIX
capabilities. That's the ease-of-use payoff — today an adopter hand-writes
`ios.info_plist` *and* Android manifest entries and is still denied at runtime,
with nothing in the build output suggesting why.

A build-time check should refuse a declaration the app can't honour, the way
`agent.expose` is resolved against the live command catalog rather than trusted.

### Two distinguishable refusals

- `E_PERMISSION_UNDECLARED` — the app never asked for this; a build-time fix.
- The platform's own denial — the user said no; a runtime state, possibly
  recoverable in system settings.

Collapsing those into one is how the current behaviour became so misleading.

### The `geo.*` plugin

**macOS** WKWebView has no public path to grant geolocation, so wiring the bridge
everywhere else would leave exactly one platform dark — the split
[ble-plugin.md](ble-plugin.md) argues against. So **location gets a plugin on all
five**, and the docs point at it rather than at the web API.

Note this is a *weaker* case than the first draft made, since iOS and Windows
already work: the plugin buys consistency and a single documented path, not a
capability that's otherwise unreachable. It is still worth it — an app that has to
branch on `os` to get a coordinate is precisely the tax this project exists to
remove — but it should be argued honestly, and it could reasonably be deferred
behind the Android capture fix, which is a genuine outage.

```js
const { latitude, longitude, accuracy } = await __SWIFT_PWA__.invoke('geo.current', { accuracy: 'high' });
const stop = __SWIFT_PWA__.subscribe('geo.watch', { accuracy: 'balanced' }, (fix) => { /* … */ });
```

| Platform | Backend |
| :--- | :--- |
| Apple | CoreLocation (`CLLocationManager`) |
| Android | `FusedLocationProviderClient`, falling back to `LocationManager` |
| Linux | GeoClue 2 over D-Bus |
| Windows | WinRT `Windows.Devices.Geolocation.Geolocator` |

`E_GEO_UNAVAILABLE` means *this machine, right now* — no GeoClue agent, location
services off, permission refused — never "this OS". Same rule as
`E_BLE_UNAVAILABLE`.

Leaving the web API newly functional on the other four is fine; it just isn't the
documented cross-platform path.

## Scope

**In:** camera and microphone on **Android and Linux** (the two real outages);
geolocation on macOS, Linux and Android; the `pwa.json` declaration and the
manifest/plist emission it drives; `geo.*` on five platforms; regression tests on
iOS and Windows so the two platforms that already work don't quietly stop.

**Sequence:** **Linux first** — one `permission-request` handler fixes capture and
location together on both GTK backends, so it's the largest gap closed by the
smallest change. Then Android capture, which is the other outage and needs two
layers. Then the declaration plumbing, then `geo.*` for macOS.

**Out:** Web Push (a server story, not a permission one), background location,
screen capture, MIDI, clipboard *read* (the shipped `clipboard.*` plugin covers
it), and any attempt to polyfill Web Bluetooth/USB/Serial/HID — those are
[ble-plugin.md](ble-plugin.md)'s problem and a webview can't be talked into them.

## Verification

The probe is two `drive eval` calls: a `--wait` expression that kicks off the
request and resolves when an answer lands, then a read of the stashed result.
Per platform:

- **macOS** ✅ bundled `.app` with usage descriptions present, driven via `drive`.
- **Linux GTK3 and GTK4** ✅ under Xvfb, with an `xwininfo` window-tree diff across
  the request. Nothing here needs a physical display. On GTK4, setting
  `GDK_BACKEND=x11` was needed: without it the app found a Wayland compositor and
  died with *"Lost connection to Wayland compositor"* right after printing its
  driver port. **Observed once, on a box that was mid-way through a driver update
  — treat it as an environment note, not a finding**, and re-check on a settled
  machine before writing it down as backend behaviour.
- **Android** ✅ on a real device (Android 16) over CDP rather than `drive`, per
  [android-on-device-testing.md](../android-on-device-testing.md) — a scaffolded
  app deployed with `swift-pwa deploy --target android`.
- **Windows** ✅ on Windows 11 x64 / WebView2 151. An app launched over SSH lands
  in Session 0 and dies with `CreateCoreWebView2Controller failed: 0x80070578`, so
  it needs the `schtasks /it` launch documented in
  [app-driver.md](../app-driver.md) plus `drive --attach`; and a **locked** session
  makes every permission request look hung, which reads exactly like a bug.
- **iOS** ✅ on a real iPad (iOS 27), installed with `deploy --target ios --team
  … --allow-provisioning-registration`. A device can't be driven over loopback, so
  the probe page **POSTs its results to a listener on the host** instead — a useful
  pattern for any on-device measurement. Two notes: the device must be attached by
  **USB** (over `localNetwork` the developer disk image won't mount and the profile
  minter times out), and `devicectl install` failed once with a transient
  `CoreDeviceError 3002` that succeeded on an immediate retry.

**All cells are now measured.** Two traps for whoever repeats this: capture needs
real hardware *and* a reachable audio server (from SSH, export
`XDG_RUNTIME_DIR=/run/user/1000`, or WebKit reports absent devices and you learn
nothing); and `swift-pwa drive eval` did **not** await promises — it failed with an
unsupported-result-type error, so every async probe had to stash its result on a
global and be read back in a second call. **Fixed**: promises are now awaited
automatically.

## Resolved

- **Should `permissions.web` gate anything on Windows, where it already works
  without a declaration?** **Yes — gate it.** No adopter ships a Windows app yet,
  so there is no working behaviour to take away, and a declaration that means the
  same thing on all five is worth more than one platform's head start. Revisit
  only if a real app is caught out by it.
- **An app-level veto.** **Yes, ship it** — not for kiosk builds, but because an
  app wants its own in-app privacy controls ("microphone: off") that hold
  regardless of what a page asks for. The `pwa.json` declaration is a build-time
  ceiling; the veto is a runtime one the app owns and can put in its own settings
  UI. It must sit *above* the OS prompt: a vetoed permission is refused without
  ever asking, so the user isn't prompted for something the app has already
  decided against.

## Open questions

- **Flat list or per-platform?** Neither, quite — see below. Ben is undecided and
  wants the shape settled before implementation.

### The declaration's shape

A flat list of capability names is the nicer promise:

```json
"permissions": { "web": ["microphone", "geolocation"] }
```

but it cannot carry two things that are **mandatory on the platforms it targets**:

- **Apple requires a human-readable purpose string per permission**
  (`NSMicrophoneUsageDescription`, …). It's shown to the user in the system
  prompt, and an app missing one is rejected. A bare name can't express it, and
  the strings differ per app, so we cannot invent them.
- **Android has qualifiers with no Apple counterpart** — `usesPermissionFlags="neverForLocation"`
  on `BLUETOOTH_SCAN` (which [ble-plugin.md](ble-plugin.md) needs), `maxSdkVersion`
  on legacy permissions, and the `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION`
  split.

The proposed answer is **scalar-or-object**, which is already the house pattern:
`window.background_color` takes a plain hex string *or* a `{light, dark}` pair via
a custom `Codable` (`PWAManifest.BackgroundColor`). Same idea here — a name for
the simple case, an object when a platform needs more:

```json
"permissions": {
  "web": {
    "microphone":  { "reason": "Record a voice note." },
    "geolocation": { "reason": "Show jobs near you.", "accuracy": "coarse" }
  }
}
```

with the flat-array form accepted as shorthand where no detail is needed. `reason`
emits the Apple usage description and the build **fails loud** without one when an
Apple target is built — the same stance `agent.expose` takes, resolving against the
live catalog rather than trusting the manifest, and better than shipping an app the
App Store rejects. Genuinely platform-specific knobs stay namespaced
(`android: { neverForLocation: true }`) rather than becoming a parallel top-level
list, so there is one place to look.

**What's still open:** whether `accuracy` is worth generalising (iOS has reduced
accuracy, Android has coarse/fine, desktop has neither), or whether coarse/fine
should wait for a second consumer rather than being designed in now.
