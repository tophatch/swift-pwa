# The app driver — scripting a running app

`swift-pwa drive` evaluates JavaScript in a running app's page, screenshots its
webview, and reads or sets window geometry — over an **opt-in loopback control
socket**, without taking over the machine.

The gap it closes: Android apps have been scriptable since
`setWebContentsDebuggingEnabled(true)` put the page on a CDP socket that
`adb forward` brings to the host (see
[android-on-device-testing.md](android-on-device-testing.md)). On macOS, Linux
and Windows, `Cmd+Opt+J` / `Ctrl+Alt+J` opens DevTools *for a human* and that is
the whole story — which is why a meaningful share of
[manual-test-cases.md](manual-test-cases.md) is marked human-only.

The usual workaround is worse than it looks. Screen capture plus OS-wide
synthetic clicks needs the app frontmost (so you can't use your computer while a
run is in progress), photographs whatever window drifted on top rather than the
app, and on macOS wants both the Screen Recording and Accessibility TCC grants —
which no CI runner can click through. Every verb here goes through the app's own
renderer instead, so a backgrounded, occluded or offscreen window drives and
screenshots correctly, with no grants at all.

> **Dev and test only.** The driver is not a shipping feature, and a release
> build doesn't contain it. See [Three gates](#three-gates).

## Quickstart

Run these from your app's directory (the one with `pwa.json`):

```bash
swift-pwa drive info                          # what this backend supports
swift-pwa drive eval "document.title"         # JS in the page, JSON out
swift-pwa drive shot out.png                  # PNG of the webview contents
swift-pwa drive windows                       # window ids, size, position
```

By default `drive` **owns the app's lifecycle**: it builds the app, launches it
with the driver env var set, reads the port and per-launch token from the app's
stdout, runs your verb, and tears the app down. Nothing to wire up, and no
process left behind.

Waiting for the page is client-side. `drive` polls for
`document.readyState === 'complete'` before every verb; add your own condition
with `--wait`:

```bash
swift-pwa drive shot ready.png --wait "!!document.querySelector('.viewer canvas')"
swift-pwa drive eval "app.state.count" --wait "window.app?.ready" --timeout 60
```

`--timeout` (default 30s) bounds the app launch, the page-ready poll and
`--wait` together. A cold WebKitGTK start under Xvfb on a software renderer can
take longer than that; raise it rather than assuming a hang.

### Starting on a specific screen

`--route` opens the app's first window at a path inside the bundle rather than
its declared entry, so a test can land on the screen it's about without
navigating there by hand — and without the usual hack of patching
`location.replace(…)` into the built bundle, which mutates the artifact under
test:

```bash
swift-pwa drive shot reader.png --route "/doc.html?id=42"
```

It's a thin wrapper over `SWIFT_PWA_INITIAL_ROUTE`, which works on any launch
(`SWIFT_PWA_INITIAL_ROUTE=/doc.html?id=42 ./MyApp`) and is useful well outside
testing. First window only, bundled content only; see the README.

### Driving an app you launched yourself

For a session of several commands against one app — or to drive an app started
by something other than `drive` — launch it with `SWIFT_PWA_DRIVE=<port>` (`0`
asks the OS for a free one) and attach:

```bash
SWIFT_PWA_DRIVE=0 ./.build/debug/MyApp &
# → swift-pwa driver listening port=51234 token=8f0c…

swift-pwa drive eval "document.title" --attach 51234 --token 8f0c…
swift-pwa drive shot after.png --attach 51234 --token 8f0c…
```

### Choosing a window

Verbs act on the app's only open window. With more than one open, name it —
ambiguity is an error rather than a guess, because silently driving the wrong
window is the failure mode that makes a driver worse than useless:

```bash
swift-pwa drive windows                       # ids and geometry
swift-pwa drive eval "location.href" --window <id>
```

## Three gates

A loopback port that evaluates arbitrary JS inside a running app is reachable by
every local user account, so one gate isn't enough:

1. **Compile.** The driver is behind `#if SWIFT_PWA_DRIVER`, defined for **debug
   builds only**. A shipped release binary does not contain the code at all — it
   won't listen even with the env var set. Build with `SWIFT_PWA_DRIVER=1` to
   put it into a release build deliberately (for driving an optimized build).
2. **Environment.** A driver-capable build still doesn't listen until
   `SWIFT_PWA_DRIVE` names a port. Unset — every normal launch — nothing binds.
3. **Token.** A fresh random token per launch, printed on stdout, required on
   every frame. An env-only gate is one `launchctl setenv` away from being a
   hole.

## Per-backend support

`capabilities` (`swift-pwa drive info`) reports what the backend in front of you
actually does, rather than a documented ideal — the same posture as `Window`'s
best-effort `setPosition`.

| Backend | `eval` | `screenshot` | Notes |
| --- | --- | --- | --- |
| **macOS** | Yes | Yes | `WKWebView.takeSnapshot` — renders offscreen, so no frontmost / unoccluded requirement and no TCC grant |
| **iOS** | Yes | Yes | Same adapter as macOS; Simulator is the practical target. Not yet exercised on device |
| **Linux GTK3** | Yes | Yes | `webkit_web_view_get_snapshot` → cairo PNG |
| **Linux GTK4** | Yes | Yes | `webkit_web_view_get_snapshot` → `GdkTexture` → PNG. Wayland has no screen-grab fallback, so the renderer snapshot is the only option |
| **Windows** | Yes | Yes | `ICoreWebView2.CapturePreview`. Compiles in CI (shim + adapter); **not yet exercised against a running Windows app** |
| **Android** | — | — | Already scriptable over CDP — see [android-on-device-testing.md](android-on-device-testing.md) |

**Synthetic input (`input.mouse` / `input.key`) is not implemented on any
backend yet.** Drive the DOM through `eval` in the meantime, which covers a
large share of UI assertions. When it lands it will cover macOS, GTK3 and
Android only: WebView2's `SendPointerInput` lives on
`ICoreWebView2CompositionController` and swift-pwa creates a *windowed*
controller, and GTK4 removed public event synthesis entirely (`GdkEvent` is
opaque, `gtk_main_do_event` is gone).

## Screenshots are of the webview, not the screen

This is the property that makes the driver usable while you keep working. The
capture comes from the webview's own compositor, so it is:

- **complete** even when the window is occluded, minimized, on another
  Space/workspace, or (mostly) offscreen;
- **only the app** — no title bar, no window that drifted on top;
- **grant-free** — no Screen Recording prompt on macOS.

Verified by driving a window moved to `(-984, -768)` — almost entirely off the
display — and getting back a full, correctly rendered 1024×768 viewport.

Coordinates in `window.setSize` / `window.setPosition` are read back rather than
echoed, because both are best-effort: macOS clamps a window to keep part of it
on screen, and GTK4 / Wayland refuse to position a window at all.

## Wire protocol

You don't need this to use `swift-pwa drive`; it's here so you can write your
own client (a test harness, an editor plugin) without reverse-engineering the
socket.

Newline-delimited JSON over loopback TCP, one request per line, one response per
line, requests served one connection at a time:

```jsonc
// →
{"id": 1, "token": "8f0c…", "cmd": "eval", "payload": {"js": "document.title"}}
// ←
{"id": 1, "ok": true, "result": "CritterFacts"}
```

| Command | Payload | Result |
| --- | --- | --- |
| `capabilities` | — | `{protocol, backend, verbs, screenshot, input, windows}` |
| `window.list` | — | `[{id, title, size, position, fullscreen}]` |
| `eval` | `{js, window?}` | the JSON value the expression evaluated to |
| `screenshot` | `{window?}` | `{pngBase64, bytes}` |
| `window.setSize` | `{width, height, window?}` | the size the window actually took |
| `window.setPosition` | `{x, y, window?}` | the position the window actually took |

Errors come back as `{"id": 1, "ok": false, "error": {"code", "message"}}`:

| Code | Meaning |
| --- | --- |
| `E_DRIVER_AUTH` | missing or wrong token |
| `E_DRIVER_REQUEST` | malformed frame, or a verb's arguments are wrong |
| `E_DRIVER_COMMAND` | unknown verb |
| `E_DRIVER_WINDOW` | no such window, no windows open, or ambiguous |
| `E_DRIVER_UNSUPPORTED` | the verb isn't implemented on this backend |

`wait` and viewport-fraction clicks are deliberately **not** verbs — they live
in the client, where changing their semantics doesn't mean rebuilding the app.

## `eval` returns JSON

`evaluateJavaScript` resolves to the JSON serialization of the expression's
value on every backend, so `drive eval` prints real JSON you can pipe into `jq`:

```bash
swift-pwa drive eval "({ items: store.items.length, ready: app.ready })" | jq .items
```

A JS string therefore arrives quoted (`"CritterFacts"`), objects and arrays
arrive as objects and arrays, and `undefined` arrives as `null`.

## Related

- [android-on-device-testing.md](android-on-device-testing.md) — driving the
  page over CDP on Android, which the driver doesn't replace.
- [proposals/swift-pwa-app-driver.md](proposals/swift-pwa-app-driver.md) — the
  design, including the agent-callable tool surface (Track B) this transport is
  meant to carry.
