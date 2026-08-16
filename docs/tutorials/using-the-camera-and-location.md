# Using the camera, microphone and location

**Who this is for:** your page calls `getUserMedia` or wants to know where the
user is, and you need that to work the same way on macOS, iOS, Linux, Windows
and Android. This guide builds a **field note** — snap a photo or record a voice
note, stamped with where you made it — because that's the combination these
three actually appear in together.

> Needs swift-pwa **0.10 or newer**. Before 0.10 none of the five backends
> answered the webview's permission request, so camera, microphone and location
> failed on three of them — silently, with an error that said *the user denied
> this* about a question nobody had asked.
>
> The reference behind this guide is [docs/permissions.md](../permissions.md).
> This is the hands-on path.

---

## The big picture

Two different shapes, and the difference is why there are two APIs:

```
Camera / microphone          your page's own getUserMedia
                             ──▶ the webview asks the app
                                 ──▶ ctx.permissions decides
                                     ──▶ the OS asks the user

Location                     geo.current / geo.watch
                             ──▶ ctx.permissions decides
                                 ──▶ CoreLocation / GeoClue / WinRT / LocationManager
```

**Capture stays on the web API.** A `MediaStream` feeds `<video>`, WebRTC,
`MediaRecorder` and WebAudio; routing frames over the bridge would mean
rebuilding the media pipeline, worse than the platform's. All that was ever
missing was someone to answer the permission request.

**Location gets a plugin**, because on macOS WKWebView gives an embedder no way
to grant `navigator.geolocation` at all. That isn't a guess — in one process,
with location authorized by the user, `geo.current` returns a fix while
`navigator.geolocation` still fails `code 1 "User denied Geolocation"`. A
capability that works on four platforms of five teaches you to branch on `os`,
which is the tax this project exists to remove.

---

## Part 1 — Make the camera and microphone work

Two lines in `configure`:

```swift
@MainActor
func configure(_ ctx: any AppContext) throws {
    ctx.permissions.declare(.camera, .microphone)
    …
}
```

That's it for the runtime. Your page's existing code now works:

```js
const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
```

**Declaring is a ceiling, not a grant.** It says your app *may* ask. On iOS,
Windows and Android the OS still prompts and the user still decides; the runtime
never invents consent UI of its own. On Linux there's no system consent layer
for capture, so clearing the declaration is the whole decision — the same as any
native Linux app opening `/dev/video0`.

### When you forget

Undeclared requests are refused, and the page sees `NotAllowedError` — which is
*exactly* what a user denial looks like. So the runtime says the real reason
where you'll see it:

```text
swift-pwa: refused a 'microphone' permission request from pwa://localhost/index.html
because this app has not declared it. Add `ctx.permissions.declare(.microphone)`
to your configure closure. The page sees an ordinary denial, which looks exactly
like the user saying no.
```

> **On Android that line goes to `adb logcat`**, not your terminal. An Android
> app process's stdout and stderr go to `/dev/null`, so `adb logcat -s swift-pwa`
> is where to look.

---

## Part 2 — Add location

Location is a plugin, so it's opt-in like every other sensor — an app that never
asks for a position shouldn't load CoreLocation or open a D-Bus connection to
GeoClue:

```swift
ctx.permissions.declare(.geolocation)
ctx.use(GeoPlugin(SystemGeolocation()))
```

```js
const fix = await __SWIFT_PWA__.invoke('geo.current', { accuracy: 'balanced' });
// { latitude, longitude, accuracy, altitude?, heading?, speed?, timestamp }

const stop = __SWIFT_PWA__.subscribe('geo.watch', { accuracy: 'high' }, (fix) => {
    map.move(fix.latitude, fix.longitude);
});
stop();   // stops the hardware, not just the delivery
```

`GeoFix` deliberately mirrors the web platform's `GeolocationCoordinates` — same
field names, same units — so moving off `navigator.geolocation` isn't a re-learn.
The one difference is `timestamp`, in seconds rather than JS milliseconds,
matching every other time value the bridge carries.

`accuracy` is a two-value hint (`high` / `balanced`) rather than a metre budget,
because a coarse hint is what all four platform APIs actually express. Asking for
`high` costs battery and, on mobile, is the difference between a GPS fix and a
network one.

### Two failures worth telling apart

```js
try {
    const fix = await __SWIFT_PWA__.invoke('geo.current', {});
} catch (e) {
    if (e.code === 'E_GEO_DENIED')      { /* consent — ask, or point at settings */ }
    if (e.code === 'E_GEO_UNAVAILABLE') { /* this machine, right now */ }
    if (e.code === 'E_GEO_TIMEOUT')     { /* retrying is reasonable */ }
}
```

`E_GEO_UNAVAILABLE` never means "this OS". It means no provider, location
switched off, radio off — something the user can usually act on, and something
worth telling them specifically.

---

## Part 3 — Give the user a switch

Most apps that touch a sensor grow their own privacy control — a "location: off"
toggle in settings. That has to hold regardless of what a page asks for, so it
belongs *above* the OS prompt rather than beside it:

```swift
ctx.permissions.setVeto { permission, origin in
    permission == .geolocation && !Settings.shared.locationEnabled
}
```

Return `true` to refuse. A vetoed permission is refused **without ever asking**,
so the user isn't prompted for something your app has already ruled out.
Returning `false` means "no objection", not "granted" — the platform still gets
to ask.

The refusal is distinguishable, which is the point:

```text
E_GEO_DENIED: this app has turned location off
```

versus the undeclared case, which names the missing declaration instead. Your UI
can send the first to your own settings screen and the second nowhere, because
the second is your bug.

> The closure runs on whichever thread the backend's permission callback fires
> on — a GTK main loop, a WebView2 callback, a JNI thread. Keep it quick, and
> don't call back into `ctx.permissions` from inside it.

**The plugin honours the same gate.** `geo.current` on an undeclared or vetoed
app fails before the provider is touched, so a refusal never spins up the
hardware and there's no documented way around your own switch.

---

## Part 4 — Ship it

The Swift declaration is the *runtime* ceiling. The **platform artifact** needs
its own — Android's `uses-permission` entries, Apple's usage descriptions — and
that comes from `pwa.json`:

```json
"permissions": {
  "web": {
    "camera":      { "reason": "Take a photo to attach to a note." },
    "microphone":  { "reason": "Record a voice note." },
    "geolocation": { "reason": "Stamp a note with where you made it." }
  }
}
```

`reason` is Apple's per-permission purpose string, shown to the user verbatim.
There's a list shorthand — `"web": ["microphone"]` — for when no platform needs
detail, but an Apple build refuses it: the App Store rejects apps without a
purpose string, and on iOS the OS **terminates the process** when a permission
is requested without one.

### Try getting it wrong

Delete the `ctx.permissions.declare(...)` line, keep `pwa.json`, and build:

```text
pwa.json and the app disagree about permissions:
  'microphone' declared in pwa.json but never passed to `ctx.permissions.declare`,
so the app refuses it at runtime.
```

Now the other way — declare in Swift, delete it from `pwa.json`:

```text
  'microphone' declared in Swift but missing from pwa.json's permissions.web,
so the platform artifact never asks for them.
```

Both are real bugs and they fail differently. The first ships an install screen
entry (and a Play Store review question) for a capability your app refuses; the
second has the runtime saying yes while the platform says no. Thirty seconds of
seeing both is why the declaration lives in two places rather than one.

A typo fails before anything is built:

```text
pwa.json's permissions.web names 'microfone', which isn't a permission this
runtime knows. Valid names: camera, geolocation, microphone, notifications.
```

> The comparison needs to run your app, so it happens on host builds. A
> cross-compiled build (`--target android`, `--target ios`) says it couldn't
> check rather than pretending it did — the same limit `agent.expose` has.

---

## What you'll actually see, per platform

The prompts differ, and that's the part that surprises people.

| | Camera / microphone | Location |
| :--- | :--- | :--- |
| **macOS** | works; the OS asks once | **`geo.*` only** — the web API can't be granted |
| **iOS** | the OS asks | either works; `geo.*` is the portable one |
| **Linux** | no system prompt — your declaration is the decision | needs a **GeoClue agent** |
| **Windows** | the OS asks | governed by the *desktop apps* toggle |
| **Android** | the OS asks | the OS asks |

### Traps worth knowing before you hit them

- **Linux — no GeoClue agent, no location.** A desktop session runs one; an SSH
  or headless session doesn't, and you get
  `AccessDenied: Geolocation disabled for UID 1000` or a `GetClient` timeout.
  Start one with `/usr/libexec/geoclue-2.0/demos/agent`. Without this it looks
  like the feature doesn't exist rather than being gated.
- **Android — a microphone needs two permissions.** Declaring `microphone`
  emits `MODIFY_AUDIO_SETTINGS` as well as `RECORD_AUDIO`, because Chromium's
  audio manager wants both. With only the latter, `getUserMedia` fails
  `NotReadableError` ("Could not start audio source") *after* the user grants
  the permission — which reads as broken hardware.
- **Android — "Approximate" is a real yes.** A coarse-only grant satisfies
  `geolocation`; don't treat it as a refusal.
- **Windows — there's no per-app entry** in Settings → Privacy & security →
  Location for an unpackaged app. It rides the *desktop apps* toggle, so a
  refusal usually means location is off for desktop apps generally.
- **Apple — `com.example.*` can't be registered** with a free personal team, and
  every scaffolded app starts there. Change `id` **and** `ios.bundle_identifier`
  / `macos.bundle_identifier` — `swift-pwa init` seeds those explicitly, so
  changing `id` alone does nothing.
- **macOS — don't try to fix `navigator.geolocation`.** There's no public API
  for it. Use `geo.*`.

---

## See it running

The **Device & location** card in
[`Examples/HelloPWA`](../../Examples/HelloPWA) wires up everything above:
`geo.current`, a `geo.watch` toggle, the app-level location switch, and
`getUserMedia` for both devices.

```bash
cd Examples/HelloPWA
swift run swift-pwa build --target macos --configuration debug
open build/macos/HelloPWA.app
```

## Where to go next

- [docs/permissions.md](../permissions.md) — the full reference, including the
  per-platform seams and what each backend does.
- [Talking to the native side](talking-to-the-native-side.md) — if you want a
  sensor this surface doesn't cover yet, that's how you add one.
- [Shipping your app](shipping-your-app.md) — signing, which you'll need before
  a real user ever sees one of these prompts.
