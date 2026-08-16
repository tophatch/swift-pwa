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

A declaration is a **ceiling, not a grant**. It says the app may ask. On
platforms whose OS prompts the user (iOS, Windows, Android) the prompt still
happens and the user still decides; the runtime never invents consent UI of its
own. On Linux there is no system consent layer for capture, so clearing the
declaration is the whole decision — the same as any native Linux app opening
`/dev/video0`.

Undeclared requests are refused, and the refusal prints a one-off diagnostic
naming the fix:

```
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
| **Linux GTK3 / GTK4** | ✅ fixed in this slice | ✅ fixed in this slice | **Yes** |
| **iOS** | ✅ already prompted and granted | ✅ already prompted and granted | Not yet |
| **Windows** | ✅ already prompted and granted | ✅ already prompted and granted | Not yet |
| **macOS** | ✅ already worked | ❌ denied — WKWebView exposes no public grant path on macOS | Not yet |
| **Android** | ❌ denied — no `WebChromeClient`, and the manifest requests neither permission | ❌ denied | Not yet |

Still to come, in order: Android capture (the other real outage, and the one
that needs two layers — the `WebChromeClient` *and* the manifest entries plus a
runtime request); the `pwa.json` `permissions.web` declaration that drives the
platform artifacts and is cross-checked against the Swift declaration at build
time; and a `geo.*` plugin, since macOS can't be fixed through the web API at
all. See [the proposal](proposals/permissions-bridge.md) for the measurements
behind each of those cells — every one was taken on real hardware.

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
