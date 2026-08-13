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

swift-pwa drive click --selector "#save"      # a real, trusted click
swift-pwa drive type "hello" --selector "input#q"
swift-pwa drive scroll 400                    # positive scrolls down
```

Prefer `--selector` over coordinates: it survives a layout change, and it's
measured and clicked in one round trip so a mid-flight animation can't leave you
clicking where the button *was*. `drive click 0.9 0.5 --fraction` takes viewport
fractions when you genuinely mean a position rather than an element.

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

`--timeout` (default 60s) bounds the app launch, the page-ready poll and
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

### Driving on the iOS Simulator

```bash
swift-pwa drive eval --simulator "getComputedStyle(document.body).paddingTop"
swift-pwa drive shot --simulator --route "/reader.html?id=42" reader.png
swift-pwa drive info --simulator
```

`--simulator` (equivalently `--target ios --simulator`) moves the whole loop onto
a simulator: a **debug** `.app` via the same `build --target ios --simulator` an
adopter runs, `simctl install`, `simctl launch --console-pty` with the driver env
var passed through as `SIMCTL_CHILD_SWIFT_PWA_DRIVE`, the handshake read off the
app's console, then the verb, then `simctl terminate`. Pick a device with
`--device "iPad Pro 13-inch (M4)"`; otherwise a booted simulator wins, else the
first available one.

None of that is new machinery in the app — the iOS runtime has started the
control socket since the driver shipped. What was missing was a way to get a
debug build onto a simulator: `deploy` built release only, where the socket isn't
compiled in at all. Checking a safe-area or full-bleed change therefore meant
deploy → `simctl launch` → `simctl io screenshot` → crop → look, once per
iteration, with anything time-dependent caught by burst-screenshotting.

One caveat about CI: this path is verified by hand and by an opt-in
`simulator-drive` job (`workflow_dispatch` or weekly), not on every PR. On a
GitHub runner the `xcodebuild` underneath it twice ran past 28 minutes and had to
be killed, while the same app bundles for macOS there in 45 seconds and the same
simulator run takes ~16s on a local Mac. If you wire `drive --simulator` into
your own CI, give the step a generous timeout and let its stderr reach the log —
the phase lines (build → boot → install → launch) are what tell you where a
stall is.

Two honest limits. **Synthetic input is refused** — `drive info` reports
`input.pointer: false`, because iOS exposes no public way to inject an event into
a `WKWebView`; dispatch from the page instead (`drive eval
"document.querySelector('#save').click()"`). And a **physical device** is out of
reach: the control socket listens on the device's loopback, which is not this
machine's, so there is nothing for `--attach` to connect to.

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
| **iOS Simulator** | Yes | Yes | Same adapter as macOS. `drive --simulator` runs the whole loop; **no synthetic input** (iOS has no public event-synthesis API). A *device* can't be driven at all — its loopback isn't the host's |
| **Linux GTK3** | Yes | Yes | `webkit_web_view_get_snapshot` → cairo PNG |
| **Linux GTK4** | Yes | Yes | `webkit_web_view_get_snapshot` → `GdkTexture` → PNG. Wayland has no screen-grab fallback, so the renderer snapshot is the only option |
| **Windows** | Yes | Yes | `ICoreWebView2.CapturePreview`. Verified against a running app on Windows 11 x64 — but the app has to be on an interactive desktop, see below |
| **Android** | — | — | Already scriptable over CDP — see [android-on-device-testing.md](android-on-device-testing.md) |

> **Windows: the app needs an interactive desktop.** Driving over SSH is the
> case that bites, because Windows OpenSSH puts your shell in **session 0**, the
> non-interactive services session. WebView2 refuses to create a controller
> there — the app starts, the driver attaches, `info` answers, and then every
> page-dependent verb times out behind one line on stderr:
>
> ```text
> swift-pwa: CreateCoreWebView2Controller failed: 0x80070578
> ```
>
> `0x80070578` is `ERROR_INVALID_WINDOW_HANDLE`. Nothing is wrong with the app
> or the driver; there is simply no desktop to put a window on. Run the app in
> the logged-on user's session instead and attach to it, which is what
> [Driving an app you launched yourself](#driving-an-app-you-launched-yourself)
> is for. From an SSH shell, a scheduled task with `/it` gets you there:
>
> ```bat
> schtasks /create /tn DriveMyApp /tr "C:\path\to\launch.bat" /sc once /st 23:59 /f /it /ru <user>
> schtasks /run /tn DriveMyApp
> ```
>
> where `launch.bat` sets `SWIFT_PWA_DRIVE` and redirects the app's stdout to a
> file you can read the port and token back from. The control socket is loopback
> TCP, which crosses the session boundary fine — so the CLI can keep running in
> the SSH shell. A local RDP or console session needs none of this.

### Synthetic input

`input.pointer` / `input.key` / `input.wheel` deliver events into the app's
**own** event queue. The page receives *trusted* events — `isTrusted: true`,
full hit testing, focus and default actions — which is the thing a DOM event
dispatched from `eval` can't give you, since those arrive untrusted and skip
default behaviour. And because nothing goes near the OS-wide HID tap, the real
cursor never moves and the window needn't be frontmost.

**Named keys carry the character macOS sends for them.** `--key ArrowRight` is
delivered with AppKit's private-use code point (U+F703) and the `function` /
`numericPad` flags a real arrow-key event has, not with an empty `characters`
string — an empty one is not "no character" to WebKit, it's a *dead key*, and
until 0.9.11 every named key (arrows, `Enter`, `Tab`, `Escape`, `Backspace`)
arrived in the page as `key: "Dead"` while `code` and `keyCode` looked right.
`Backspace` and `Delete` are also distinct keys now, as they are on a keyboard.

**No alert beep.** A `keyDown` nothing in the page handles ends at AppKit's
`noResponder`, which beeps — audibly, on your machine, once per keystroke, which
rather undercuts driving an app in the background. A driver build recognises the
events it injected and suppresses that feedback for those only; a key *you* press
that nothing handles still beeps.

> **macOS: driver builds accept first mouse.** Making that last part true takes
> one deliberate difference from a shipped build. AppKit's click-through rule is
> that a `mouseDown` landing in a window which isn't key gets consumed as "click
> to activate" rather than delivered, unless the view under it accepts first
> mouse — and `WKWebView` doesn't. So a driver build substitutes a `WKWebView`
> subclass that does, and a release build keeps the platform default, since
> whether a click into an unfocused window should reach the page is the
> adopter's design decision rather than swift-pwa's.
>
> The cost is that debug and release differ in that one behaviour. If you're
> testing click-through by hand, test a release build.

| Backend | pointer / key / wheel | pointer types | pressure | tilt |
| --- | --- | --- | --- | --- |
| **macOS** | Yes | `mouse` | — | — |
| **Linux GTK3** | Yes | `mouse` | — | — |
| **Windows / GTK4 / iOS** | — | — | — | — |

GTK3 pushes events through `gtk_main_do_event`, GTK's own dispatch entry point,
so they work **under Xvfb** — on a display server with no input device at all,
which is what makes them usable in CI.

**Windows and GTK4 can't do this, and not for want of trying.** WebView2's
`SendPointerInput` lives on `ICoreWebView2CompositionController` while swift-pwa
creates a *windowed* controller; GTK4 removed public event synthesis entirely
(`GdkEvent` is opaque, `gtk_main_do_event` is gone). On those backends,
dispatch DOM events through `eval` — untrusted, but enough for a large share of
UI assertions.

**A request a backend can't honour is refused, not downgraded.** Ask macOS for
a `pen` pointer and you get `E_DRIVER_UNSUPPORTED`, because AppKit exposes no
synthesizable tablet-pointer event and the page would see `pointerType:
"mouse"` — a stylus test that silently ran as a mouse click would pass while
proving nothing. Check `drive info` and branch on it rather than assuming.

Stylus and touch are modelled in the contract (`pointerType`, `pressure`,
`tiltX` / `tiltY`) even though no shipped backend produces them yet — the wire
format shouldn't have to break later to admit an input path that was always
going to matter.

## Screenshots are of the webview, not the screen

This is the property that makes the driver usable while you keep working. The
capture comes from the webview's own compositor, so it is:

- **complete** even when the window is occluded, minimized, on another
  Space/workspace, or (mostly) offscreen;
- **only the app** — no title bar, no window that drifted on top;
- **grant-free** — no Screen Recording prompt on macOS.

Verified by driving a window moved to `(-984, -768)` — almost entirely off the
display — and getting back a full, correctly rendered 1024×768 viewport.

> **A clean screenshot of an occluded window can still be a stale one.** The
> capture is complete, but WebKit **throttles `requestAnimationFrame` for a window
> the compositor isn't showing** — measured at 1 frame in 3 seconds while
> minimized, against 183 when visible. So a page that draws, or restores its
> state, inside a rAF callback does nothing while it's covered, and the
> screenshot shows that stale content perfectly sharply. It reads as an app bug;
> it isn't one. An adopter lost an hour to it twice ("EPUB renders nothing",
> "reading position isn't restored" — both fine when the window was visible).
>
> `drive windows` reports each window's `visibility` (`visible` / `hidden` /
> `unknown`), and **every verb warns on stderr** when its target window isn't on
> screen. If a run depends on rendering, bring the window to the front — or move
> the work off rAF, which is the more robust design anyway.
>
> Who can answer: **macOS** properly (`NSWindow.occlusionState`, which also
> covers another Space and a sleeping display); **Windows** detects minimized
> only; **Linux** and **Android** report `unknown`, because X11/Wayland expose no
> occlusion query and a backend answering `visible` there would be guessing.

Coordinates in `window.setSize` / `window.setPosition` are read back rather than
echoed, because both are best-effort: macOS clamps a window to keep part of it
on screen, and GTK4 / Wayland refuse to position a window at all.

## Handing the app to an agent — `swift-pwa mcp`

`swift-pwa mcp` serves the same verbs to an agent as **MCP tools** over stdio,
so it can change a stylesheet, screenshot the webview, and *look at the result*
without a human present. Today that loop costs a screen takeover and two TCC
grants, which is why nobody runs it and why UI regressions land unverified.

Register it with an MCP host as a stdio server, with your app's directory as the
working directory:

```jsonc
{
  "mcpServers": {
    "my-app": { "command": "swift-pwa", "args": ["mcp"], "cwd": "/path/to/my-app" }
  }
}
```

| Tool | |
| --- | --- |
| `app_screenshot` | PNG of the webview — `maxWidth` downscales it, which matters because a full-resolution Retina capture is megabytes of base64 in the agent's context |
| `app_eval` | run JS in the page, get JSON back |
| `app_click` / `app_type` / `app_press_key` / `app_scroll` | trusted input, where the backend supports it |
| `app_windows` / `app_capabilities` | geometry, and what this backend can actually do |

The app is built and launched on the **first tool call** — not when the host
connects, since an MCP host spawns its servers eagerly and a window appearing
before the agent asked for anything would be a surprise — and torn down when the
session ends.

Everything the server logs, including build output, goes to **stderr**: stdout
carries the protocol stream and the spec requires it contain nothing else.

> **This is the dev-only door, not the shipping one.** It inherits the driver's
> three gates, so it only reaches a debug build you launched yourself. Exposing a
> *shipped* app's own commands to an agent is a different feature with a
> different gate — runtime consent from the end user, who is the party actually
> exposed — and lives in [agent-tools.md](agent-tools.md), where the developer's
> half (a `pwa.json` allowlist, checked against the app's real command catalog)
> has landed and the runtime consent gate is next.

## Where the web bundle comes from

`drive` runs the **bare SwiftPM product**, not the bundle `swift-pwa build`
produces — that's what makes a driven run fast. But a plain `swift build` stages
no `web/` anywhere, so the app has nothing to serve unless something supplies it.

`drive` does two things about that before launching:

1. Sets **`SWIFT_PWA_WEB_ROOT`** to your `pwa.json` `web.directory`. An app whose
   `App.swift` calls `WindowContent.bundledWeb(...)` picks it up. This is the one
   that handles a web directory **outside** the SwiftPM target (`../public`), and
   a tree too large to declare as a SwiftPM resource.
2. **Symlinks** that directory next to the built binary, where an app scaffolded
   before `bundledWeb` looks (`Bundle.main.resourceURL/web`). A link rather than
   a copy — a real app's web directory is not small.

If your app was scaffolded earlier and resolves the web root itself, either
leave it (the symlink covers you) or move to the one-liner:

```swift
content = try WindowContent.bundledWeb(entry: "index.html", spaFallback: false)
```

Declaring `resources: [.copy("web")]` also works, and then you pass
`Bundle.module.bundleURL.appendingPathComponent("web")` as a `fallbacks` entry —
but SwiftPM copies the tree on every build, so it's the wrong tool for anything
large.

> **Don't reach for `#filePath`** to find your source tree at runtime. It bakes
> an absolute path from the build machine into the binary, which is wrong the
> moment the app runs anywhere else — and it ships in release builds.
> `SWIFT_PWA_WEB_ROOT` is read **only** in driver-compiled (debug) builds, on
> purpose: an installed app that honoured it would let anyone point it at web
> content of their choice, running behind the app's full `invoke` surface.

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
| `input.pointer` | `{type, x, y, pointerType?, button?, clickCount?, pressure?, tiltX?, tiltY?, modifiers?, window?}` | `null` |
| `input.key` | `{type, key, code?, text?, modifiers?, window?}` | `null` |
| `input.wheel` | `{x, y, deltaX?, deltaY?, modifiers?, window?}` | `null` |

`type` is `down` / `up` / `move` for a pointer and `down` / `up` for a key.
`modifiers` is an array — `["shift", "meta"]`. Coordinates are window-local CSS
pixels; `capabilities.input` says what the backend will actually accept.

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
- [agent-tools.md](agent-tools.md) — the shipping counterpart: exposing an app's
  *own* commands to an agent, which this transport is meant to carry.
- [proposals/swift-pwa-app-driver.md](proposals/swift-pwa-app-driver.md) — the
  design behind both.
