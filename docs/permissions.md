# Web permissions (`ctx.permissions`)

When a page calls `getUserMedia`, `navigator.geolocation.getCurrentPosition` or
`Notification.requestPermission`, the webview asks its *embedder* — this runtime
— whether that's allowed. Every backend has a seam for that question, and until
0.10 none of them answered it, so the platform default applied. On three of the
five that default is **deny, silently**.

The result was worse than a missing feature, because the API is present: a page
feature-detects `navigator.geolocation`, gets `true`, calls it, and receives
`PERMISSION_DENIED` — a code that means *the user said no*. Nobody was asked.
Whatever the app shows next ("enable location in Settings") sends the user
somewhere that cannot fix it.

`ctx.permissions` is the one place that decides, with the same semantics on
every backend.

## Declaring

Nothing is permitted until it's declared. Declare in `configure`, before any
window exists — a page can ask for the camera as soon as it loads.

```swift
@MainActor
func configure(_ ctx: any AppContext) throws {
    ctx.permissions.declare(.microphone, .geolocation)
    …
}
```

Declaring is additive, so separate features can each declare what they need
without coordinating.

### And in `pwa.json`

The Swift call is the *runtime* ceiling. The **platform artifact** needs its own
declaration — the Android `uses-permission` entries, the Apple usage-description
strings — and that comes from `pwa.json`:

```json
"permissions": {
  "web": ["microphone", "geolocation"]
}
```

or, when a platform needs more detail:

```json
"permissions": {
  "web": {
    "microphone":  { "reason": "Record a voice note." },
    "geolocation": { "reason": "Show jobs near you." }
  }
}
```

`reason` is Apple's per-permission purpose string, which is mandatory there. The
list form is shorthand for "no detail needed yet", the same way
`window.background_color` takes a hex string *or* a `{light, dark}` pair.

**Why two places.** Building for Android or iOS cross-compiles, so the build
can't run the app to ask what it declared — the same limit `agent.expose` has.
The artifact therefore needs a declaration the build can read without executing
anything. To stop the two drifting, `swift-pwa build` **fails** when they
disagree:

```text
pwa.json and the app disagree about permissions:
  'microphone' declared in pwa.json but never passed to `ctx.permissions.declare`,
so the app refuses it at runtime.
```

Both directions are caught, and they fail differently: a permission in
`pwa.json` only means the artifact asks the user's OS for something the app will
then refuse; a permission in Swift only means the runtime says yes while the
platform says no — and on Apple a missing usage description **terminates the
app**. An unknown name is refused too, before anything is built, since a typo
would otherwise silently omit a manifest entry:

```text
pwa.json's permissions.web names 'microfone', which isn't a permission this
runtime knows. Valid names: camera, geolocation, microphone, notifications.
```

The comparison needs to run the app, so it happens on host builds; a
cross-compiled build says so rather than pretending it checked.

A declaration is a **ceiling, not a grant**. It says the app may ask. On
platforms whose OS prompts the user (iOS, Windows, Android) the prompt still
happens and the user still decides; the runtime never invents consent UI of its
own. On Linux there is no system consent layer for capture, so clearing the
declaration is the whole decision — the same as any native Linux app opening
`/dev/video0`.

Undeclared requests are refused, and the refusal prints a one-off diagnostic
naming the fix:

```text
swift-pwa: refused a 'microphone' permission request from pwa://localhost/index.html
because this app has not declared it. Add `ctx.permissions.declare(.microphone)`
to your configure closure. The page sees an ordinary denial, which looks exactly
like the user saying no.
```

That message exists because the refusal itself is indistinguishable from a user
denial by the time it reaches JS. The console is the only place the real cause
can surface.

## The veto — the app's own privacy switch

An app often has its own "microphone: off" control, and that has to hold
regardless of what a page asks for. `setVeto` is that ceiling:

```swift
ctx.permissions.setVeto { permission, origin in
    permission == .microphone && !Settings.shared.microphoneEnabled
}
```

Return `true` to refuse. It sits **above** the OS prompt, so a vetoed permission
is refused without ever asking — the user isn't prompted for something the app
has already ruled out. Returning `false` means "no objection", not "granted":
the platform still gets to ask.

The closure is called on whichever thread the backend's permission callback
fires on, which is not necessarily the main actor. Keep it quick, and don't call
back into `ctx.permissions` from inside it.

## Two refusals worth telling apart

| | Meaning | Fix |
| :--- | :--- | :--- |
| `undeclared` | The app never asked for this capability | Build-time — add the declaration |
| `vetoed` | The app refused it itself | The app's own settings UI |
| The platform's own denial | The **user** said no | System settings; possibly recoverable |

Collapsing these is how the old behaviour became so misleading.

## What's wired today

This is the first slice of a cross-platform surface, and it is **not yet
consulted on every backend**. Where it isn't, behaviour is exactly what it was
before — nothing regresses, but a declaration buys nothing either.

| Platform | Capture (camera / mic) | Geolocation | Consults `ctx.permissions` |
| :--- | :--- | :--- | :--- |
| **Linux GTK3 / GTK4** | ✅ fixed | ✅ fixed | **Yes** |
| **Android** | ✅ fixed | ✅ fixed | **Yes** |
| **iOS** | ✅ already prompted and granted | ✅ already prompted and granted | Not yet |
| **Windows** | ✅ already prompted and granted | ✅ already prompted and granted | Not yet |
| **macOS** | ✅ already worked | ❌ denied — WKWebView exposes no public grant path on macOS | Not yet |

Still to come: **macOS geolocation**, which can't be fixed through the web API
at all and needs the `geo.*` plugin; and wiring iOS / Windows / macOS to the
policy, so the declaration means the same thing on all five rather than being
ignored where the platform already happens to work. See
[the proposal](proposals/permissions-bridge.md) for the measurements behind each
cell — every one was taken on real hardware.

## Linux specifics

WebKitGTK routes *every* permission through one `permission-request` signal, so
answering it fixes capture, location, notifications and device labels together.
Notes from verifying it:

- **`enumerateDevices()` labels are their own permission.** An ungranted device
  presents as `audioinput:(no label)`; declaring either capture permission is
  enough to reveal the real name. (On a box with **no** media devices at all,
  WebKitGTK leaves the `enumerateDevices()` promise pending forever — that
  predates this change and is unrelated to permissions.)
- **Allowing geolocation is not the same as getting a fix.** With location
  declared, a headless box that has GeoClue installed but no usable provider
  answers `POSITION_UNAVAILABLE` or `TIMEOUT` instead of `PERMISSION_DENIED`.
  That change of error code is how you tell the permission gate opened.
- **Capture needs a reachable audio server.** Over SSH, export
  `XDG_RUNTIME_DIR=/run/user/$(id -u)`, or WebKit reports zero devices and
  returns `OverconstrainedError` *before* any permission decision — a result
  that says nothing about permissions at all.
- **Request types this runtime doesn't model** — screen capture, pointer lock,
  encrypted-media key systems — are refused, with a one-off note on stderr. None
  has ever been granted on any backend.

`Scripts/verify-linux-permissions.sh` runs the whole matrix (undeclared /
declared / vetoed) against a freshly scaffolded app on a real box.

## Android specifics

Android needed two layers, not one: a `WebChromeClient` (there was none at all,
and its absence is what denied every request) *and* the manifest entries, since
by the time `onPermissionRequest` fires Android has already established that the
app doesn't hold `CAMERA` / `RECORD_AUDIO`. The app has to ask, and only an
Activity can — so the decision round-trips: Kotlin pushes a host event, the Swift
policy answers, and Kotlin then raises Android's own runtime prompt.

- **A microphone needs `MODIFY_AUDIO_SETTINGS` as well as `RECORD_AUDIO`.**
  Chromium's Android audio manager requires both before it will open a recording
  device. Without it, `getUserMedia` fails **`NotReadableError` ("Could not
  start audio source") with the runtime permission granted** — which reads as
  broken hardware, not a missing declaration. `permissions.web: ["microphone"]`
  emits both; the extra one is install-time, so it adds no prompt.
- **A veto is refused without a prompt**, so an app-level "microphone: off"
  switch never shows the user a dialog whose answer is already decided.
- **The undeclared diagnostic goes to `adb logcat`**, not stderr — an Android
  app process's stdout and stderr go to `/dev/null`, so a message explaining a
  silent refusal would itself have been silent.
