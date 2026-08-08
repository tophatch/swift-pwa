# Proposal: an app-driver channel, and an agent-callable tool surface

> **Status: Track A Cut 1 has shipped** (`swift-pwa drive` — see
> [docs/app-driver.md](../app-driver.md) and `CHANGELOG.md`). The rest —
> Cut 2 (native input), Cut 3 (`swift-pwa mcp`), `SWIFT_PWA_INITIAL_ROUTE`, and
> all of Track B — is still design.
>
> The problem statement and the `PWA_DEV_SERVER` findings come from an adopter
> building a desktop app on swift-pwa 0.7.7, measured on their machine. The
> per-platform API choices, the capability tiering, and Track B were revised
> after checking each claim against this repo.
>
> Two things changed on contact with the code, both recorded here so the plan
> and the shipped thing agree:
>
> - **The build gate is the build *configuration*, not a `pwa.json` key.** The
>   driver compiles into debug builds only, with `SWIFT_PWA_DRIVER=1` as the
>   deliberate release override. That delivers "a release build cannot contain
>   the code at all" without a manifest key that would have to be plumbed
>   through all five bundlers for a rare case — and the common path then needs
>   no configuration at all.
> - **`eval` uncovered a real bug the moment it ran.** The Apple adapter's
>   `evaluateJavaScript` returned Swift's debug description rather than the JSON
>   the protocol promises, so a JS `true` came back as `1`. Fixed in the same
>   change (see `CHANGELOG.md`) — the first thing the driver found was a defect
>   in the seam it depends on.

Two related deliverables, deliberately separated because they have different
audiences, different risk profiles, and different release gates:

- **Track A — a dev/test driver.** An opt-in control channel so a script or an
  agent can drive and screenshot a running app without taking over the machine.
  Off in shipped builds.
- **Track B — an agent-callable tool surface.** An app declares which of *its
  own* bridge commands an agent may call, and swift-pwa serves them as MCP
  tools. This is the shipping, user-facing feature.

Track A first: it unblocks a real verification gap today, and its transport is
what Track B builds on.

---

## Track A — the driver

### The problem

**Android already has this. Nothing else does.**
[android-on-device-testing.md](../android-on-device-testing.md) opens by
promising you can round-trip every `System*` plugin "without touching the
device's screen yourself," because `setWebContentsDebuggingEnabled(true)` puts
the page on a CDP socket that `adb forward` brings to the host. On macOS, Linux
and Windows there is no equivalent: `Cmd+Opt+J` / `Ctrl+Alt+J` opens DevTools
*for a human*, and that is the entire story. The consequence shows up in
swift-pwa's own release notes — "GUI behavior verification is impractical over a
headless session" (0.9.2) — and in
[manual-test-cases.md](../manual-test-cases.md), 449 lines of cases marked
human-only, a meaningful share of which are human-only *because nothing can
drive the window*, not because a human eye is required.

**A browser is not a fallback.** Once an app's data layer moves onto the bridge
(`window.__SWIFT_PWA__`), its frontend stops running anywhere else — the
adopter's app throws `swift-pwa bridge unavailable` on the first `invoke`, so
Chrome + CDP is off the table no matter how convenient it would be.

**And `PWA_DEV_SERVER` only gets you part of the way** — measured, not assumed.
The adopter served `public/` from a plain static server and launched the app
with `PWA_DEV_SERVER=http://127.0.0.1:4499/doc.html?id=42`:

- The **bridge works**. `bridge.js` is a `WKUserScript` on the *configuration*,
  so it is injected into remote content too; every `invoke` resolved and the
  title, page count and progress all came back from Swift.
- The **`serveDirectory` mounts do not**. The page's `/packs/…` requests went to
  the dev server, which 404'd, and pdf.js reported `Invalid PDF structure`.
  Server log and screenshot both confirm it.

The mechanism is worth stating precisely, because it rules out the obvious fix.
[`WKWebViewAdapter.load(_:)`](../../Sources/SwiftPWAWebKit/Shared/WKWebViewAdapter.swift#L87-L102)
only calls `attachAssetProvider` in its `.bundled` branch — but attaching it on
the remote branch too would not help. With a remote origin the page's *own*
origin is `http://127.0.0.1:4499`, so a relative `/packs/…` never reaches the
`pwa://` scheme handler regardless of what provider is attached. Only an app
that fetched absolute `pwa://localhost/…` URLs would benefit, and then CORS
bites. This is structural, not a bug.

So an app that serves its real payload through `ctx.serveDirectory` — the
documented way to ship large media with range support — is exactly the app that
can't be driven from outside. The more thoroughly an app adopts swift-pwa's own
seams, the less testable it becomes. That's the wrong gradient, and it's the
argument for building a driver rather than trying to rescue the dev-server path.

**DevTools is already there, just not scriptable.** The Apple adapter sets
[`isInspectable = true`](../../Sources/SwiftPWAWebKit/Shared/WKWebViewAdapter.swift#L56-L58)
(macOS 13.3+ / iOS 16.4+), so a human can attach Safari's Web Inspector to a
running app and get a console. That's the proof the capability gap is narrow and
specific: the page is reachable, there is simply no programmatic client for it.

**What the adopter ended up with.** To verify two document-viewer interactions
(click zones on a rendered page, and section-to-section handoff) they wrote a
shell driver: `screencapture -R` over the window rect, CGEvent mouse clicks
posted to the HID tap, and System Events key codes. It works, and every part of
it is a symptom:

1. **It takes over the machine.** Real clicks move the real cursor and require
   the app frontmost. You cannot use the computer while a run is in progress —
   the complaint that prompted this document.
2. **It captures the screen, not the app.** Screenshots include the title bar
   and whatever is stacked above the window. One early click landed in a Finder
   Quick Look window that had drifted over the app; the driver reported success
   and the screenshot showed the wrong thing.
3. **It needs TCC grants** (Screen Recording *and* Accessibility) for whatever
   shell runs it, so it can't run in CI or on a fresh machine without a human
   clicking through System Settings.
4. **Coordinates are re-derived every call.** Window bounds come back from
   System Events, the title bar height is hardcoded at 28, and the window moves
   between runs (restored bounds), so a hardcoded point silently misses. Retina
   scaling is a second conversion on the screenshot side.
5. **Opening a specific route means patching the build.** To land on
   `/doc.html?id=42` without navigating the gallery by hand, the script
   injects a `location.replace(...)` into the *built bundle's* `index.html`.
6. **Every backend needs its own version of all of the above**, and the Linux
   and Windows ones don't exist yet.

### This is smaller than it looks

Most of the runtime pieces are already in place:

| Need | Already there |
| --- | --- |
| Run JS in the page | `PWAWebView.evaluateJavaScript` — on **every** backend ([WebViewProtocol.swift](../../Sources/SwiftPWACore/WebView/WebViewProtocol.swift)) |
| Window geometry / focus / title / events | `Window` ([WindowProtocol.swift](../../Sources/SwiftPWACore/Window/WindowProtocol.swift)) |
| An env-gated out-of-band mode the CLI drives | `HeadlessDescribe` / `SWIFT_PWA_DESCRIBE` — exactly the precedent, in all four desktop runtimes |
| A cross-platform socket layer | `DevNet` ([DevServerSocket.swift](../../Sources/SwiftPWACLISupport/Commands/DevServerSocket.swift)) — 186 lines, BSD + Winsock, already shipping |
| A CLI that builds the app and then talks to it | `swift-pwa codegen`, `swift-pwa deploy` |
| In-process fakes | `_SwiftPWATestSupport` (`MockWebView`, `MockWindow`) |

What's missing is three things: an **out-of-process channel** to reach
`evaluateJavaScript`, **pixel capture of the webview** (as opposed to the
screen), and **synthetic input** that doesn't go through the OS-wide HID tap.

### Shape

#### 1. Runtime: an opt-in control socket

`SWIFT_PWA_DRIVE=<port>`, mirroring `SWIFT_PWA_DESCRIBE`. When set, the runtime
listens on **loopback TCP** and serves newline-delimited JSON. Unset — the
normal case — nothing listens.

**Loopback TCP, not a Unix socket.** `DevNet` is already the cross-platform
BSD/Winsock abstraction, written for `swift-pwa dev`; hoisting it into Core and
reusing it is free, and it dodges the AF_UNIX-on-Windows plumbing entirely. The
direction is inverted from the dev server (here the app is the server and the
CLI is the client), but the socket layer is the same.

**Three gates, not one.** A loopback port that evals arbitrary JS in a running
app is reachable by every local user account, so:

- a **build flag** (`"build": { "driver": true }` in `pwa.json`) — a release
  build cannot contain the code at all;
- the **env var**, so a driver-capable debug build still doesn't listen by
  default;
- a **per-launch token**, printed on stdout, required on every frame.

An env-only gate is one `launchctl setenv` away from being a hole.

A deliberately small verb set — everything else belongs in the client:

| Command | Result |
| --- | --- |
| `capabilities` | what this backend actually supports (see below) |
| `window.list` | `[{ id, title, size, position, scale }]` |
| `eval { window, js }` | JSON result — thin wrapper over what already exists |
| `screenshot { window }` | PNG of the **webview contents** |
| `input.mouse { window, type, x, y, button, clickCount }` | — |
| `input.key { window, type, key, code, modifiers, text }` | — |
| `input.wheel { window, deltaX, deltaY }` | — |
| `window.setSize` / `window.setPosition` | already on `Window` |

**`wait` and viewport-fraction clicks are client-side**, implemented in the CLI
as a poll over `eval` and a bit of arithmetic over `window.list`. Putting them
in the runtime buys nothing but round-trips, and makes every tweak to their
semantics an app-binary change.

**Coordinates are window-local CSS pixels.** Screen coordinates plus a moving
window plus a title-bar offset plus a device-pixel ratio is four chances to be
wrong, and the adopter's harness was wrong on three of them.

#### 2. Per-platform implementation — the honest spread

The `PWA_DEV_SERVER` findings above are verified. The API choices below were
checked against this repo's actual backends, and two of the adopter's original
picks don't survive that check.

| Backend | Pixels | Synthetic input |
| --- | --- | --- |
| **Apple (macOS)** | `WKWebView.takeSnapshot(with:)` — renders offscreen, no frontmost/unoccluded requirement, which kills problems 1–3 at once | `NSEvent.mouseEvent(...)` + `window.sendEvent(_:)` — the app's own event queue, no TCC grant, no cursor movement. **Unverified**: whether WKWebView's hit testing is satisfied on a non-key window. If it insists on key status, `makeKey()` without `NSApp.activate` is still far less intrusive than the status quo |
| **iOS** | `takeSnapshot` (Simulator) | ❌ — report unsupported; drivers fall back to DOM events via `eval` |
| **GTK3** | `webkit_web_view_get_snapshot()` | `gdk_event_new` + `gtk_main_do_event` |
| **GTK4** | `webkit_web_view_get_snapshot()` (returns a `GdkTexture` on WebKitGTK 6.0) | ❌ — **GTK4 removed the public event-synthesis API.** `GdkEvent` is opaque with no public constructors and `gtk_main_do_event` is gone. The adopter's `gdk_display_put_event` / `gtk_main_do_event` pair is GTK3-only. *(From the GTK4 migration guide, not a compile test.)* |
| **Windows** | `ICoreWebView2.CapturePreview` | ❌ as architected — `SendPointerInput`/`SendMouseInput` live on `ICoreWebView2CompositionController`, and we create a **windowed** controller ([swiftpwa_webview2.cpp:276](../../Sources/CWebView2Shim/swiftpwa_webview2.cpp#L276) `CreateCoreWebView2Controller(hwnd, …)`). Getting them means either rewriting the Windows backend to host its own DComp/WinComp visual tree — large and risky on a shipping backend — or `SendInput`, which is the system-wide HID tap we're escaping. `PostMessage` to the top-level HWND won't do it: WebView2's input goes to child HWNDs in the browser process |
| **Android** | CDP `Page.captureScreenshot` | already solved via CDP — the socket proxies to it so one client protocol covers all five backends |

So native synthetic input realistically covers **macOS + GTK3 + Android**. That
makes `capabilities` load-bearing rather than a nicety — the same posture as
`Window`'s "best-effort `setPosition`, read back with `position()`".

It also means **Cut 1 carries nearly all the value**, and Cut 2 should be scoped
to those three backends up front rather than discovering the Windows and GTK4
walls mid-implementation.

#### 3. CLI surface

```bash
swift-pwa drive shot out.png            # webview pixels, app can stay in the background
swift-pwa drive click 0.9 0.5           # viewport fractions or CSS px (client-side math)
swift-pwa drive eval "return document.title"
swift-pwa drive wait "!!document.querySelector('.viewer canvas')"
swift-pwa drive open /doc.html?id=42
```

`swift-pwa drive` **owns the process** — build, launch with the env set, print
the port and token, tear down — the same shape `codegen` already uses for
`SWIFT_PWA_DESCRIBE`. Otherwise every adopter writes the same lifecycle script.

`swift-pwa mcp` (stdio) exposes the same verbs as MCP tools, so an agent can
change CSS, screenshot the webview, and look at the result without a human
present and without the machine being commandeered. Today that loop costs a
screen takeover and two TCC grants, which is why it doesn't happen and UI
regressions land unverified.

`SWIFT_PWA_INITIAL_ROUTE` (or a `--route` flag setting the initial
`WindowContent` path) is worth landing **on its own**, independent of the
driver: it's a small change in the generated `App.swift`, and it kills the
"patch `index.html` inside the built bundle" hack immediately. It's useful
outside testing too — file associations already deliver a *path* to a launched
app; this is the same idea for a *route*.

### Non-goals

- **Not WebDriver or a full CDP implementation.** No element handles, no
  selector engine, no navigation semantics — `eval` reaches the app's own JS,
  which is a better tool than a generic DOM query language.
- **Not enabled in shipped builds.** Build flag + env var + token.
- **Not screenshot diffing.** Deterministic capture is the primitive;
  comparison policy belongs to the consumer.
- **Not a replacement for the Android CDP path**, which already works — this
  wraps it.

### Cuts

**Cut 1 — no synthetic input at all.** `capabilities` + `eval` + `screenshot` +
`window.*`, on macOS / Linux / Windows, with `wait` in the client. Drivers
synthesize DOM events through `eval` in the meantime, which is enough for a
large share of UI assertions. This alone removes the screen takeover, both TCC
grants, the coordinate math and the occlusion hazard — i.e. every complaint
above except native hit-testing fidelity. It's one socket server (hoisted from
`DevNet`) plus four snapshot implementations.

**Cut 2** — native synthetic input on **macOS, GTK3 and Android only**, with
`capabilities` reporting honestly everywhere else.

**Cut 3** — `swift-pwa mcp` (stdio) and `drive open <route>`.

---

## Track B — an agent-callable tool surface

The driver is a QA tool that happens to be MCP-shaped. The shipping feature is
different: **an app exposes its own semantic verbs to an agent.**

### Why this is cheap

The catalog already exists. `CommandDescriptor`
([BridgeSchema.swift](../../Sources/SwiftPWACore/Bridge/BridgeSchema.swift)) is
`name` + `kind` + `args` + `result`, and `BridgeSchema` maps essentially 1:1
onto JSON Schema — `object` → object with `properties`, `array` → array,
`optional(T)` → omit from `required`, `stringEnum` → `enum`, primitives direct.
An MCP tool definition is name + description + input schema. `__bridge.describe`
serves it at runtime and `HeadlessDescribe` dumps it at build time.

So the work is roughly:

1. A `BridgeSchema` → JSON Schema function. Mechanical, unit-testable, ~80 lines.
2. An **opt-in marker at registration** — `registry.register("book.open",
   agentExposed: true, description: "…", typed: …)`. Opt-in is not optional:
   `.unknown` schemas and internal commands must never leak, and an allowlist
   the author chose is the whole safety story.
3. An MCP server that maps `tools/call` onto `BridgeRuntime.handle`.

### Why it's the better product

An agent driving `openBook({ id })` beats an agent poking at pixels on every
axis: it's typed, it's a finite list the author chose, it doesn't break when the
layout changes, and it can't do anything the author didn't expose. "Expose your
app's capabilities to an agent in three lines" is a much stronger pitch than "we
can click your buttons."

The two tracks compose: when a driver-enabled build is running, the driver verbs
appear as an additional (dev-only, token-gated) tool group in the same server.

### Consent, not a build flag

**The tempting shortcut is to ship a subset of the *driver* under a build flag —
"basic window driving is marketable by itself, just don't expose `eval`."** That
draws the line in the wrong place. `eval` isn't dangerous because it's `eval`;
it's dangerous because it can observe content and act. So can the other verbs:

| Tier | Verbs | Risk |
| --- | --- | --- |
| Geometry | `capabilities`, `window.setSize` / `setPosition`, `window.list` *without titles* | benign |
| Observe content | `screenshot`, `eval` (read), `window.list` titles | exfiltration — a screenshot is whatever content, credential or PII is on screen |
| Act | `input.*`, `eval` (write) | arbitrary action — an agent that can click can click "Delete account" |

Shipping "screenshot + input, no `eval`" hands over substantially all of `eval`'s
power with worse ergonomics. Only the geometry tier is safe to expose without
asking, and it isn't worth shipping on its own.

Track B ships in release binaries, so the gate has to be a **runtime** one:

- off by default;
- a visible affordance for the user to turn it on;
- a visible indicator while a client is attached;
- a per-session token the app displays.

A build flag is the developer's decision about the developer's risk. The person
exposed here is the end user, and only they can grant it.

### Transport

`swift-pwa mcp` over stdio works for Track A because the CLI owns the app's
lifecycle. It does **not** work for a shipped app: an MCP host connects to a
stdio server by *spawning* it, and a running GUI app can't be spawned. Track B
wants either an HTTP-based MCP transport on loopback, or a small stdio shim
binary in the bundle that the host spawns and that relays to the app's loopback
socket. Either way `DevNet` covers the socket layer, so the choice doesn't
change the plan — but the exact transport shape needs checking against the
current MCP spec before implementation.

---

## Sequencing

| # | Deliverable | Gate |
| --- | --- | --- |
| 1 | `SWIFT_PWA_INITIAL_ROUTE` | none — small, useful on its own |
| 2 | Track A Cut 1 (`eval` + `screenshot` + `window.*`) | build flag + env + token, dev-only |
| 3 | Track A Cut 3 (`swift-pwa mcp` stdio) | same |
| 4 | Track A Cut 2 (native input, macOS/GTK3/Android) | same |
| 5 | Track B (app-declared tools, runtime consent, loopback HTTP) | runtime consent |

## Verification

The adopter can validate the Apple path against a real app on macOS 15 (Apple
silicon), including the "does a posted `NSEvent` reach an occluded WKWebView"
question, and swap their shell driver for the real thing as a first adopter.
Between their fleet and this repo's, Cut 1 can be verified on every desktop
backend — GTK3, GTK4, both Windows architectures, macOS — before it ships.
