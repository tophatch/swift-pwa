# Making it feel native

**Who this is for:** your web app runs in a swift-pwa window and works great — but it still *feels* like a web page in a frame. This guide adds the touches that make it feel like a real desktop app: **window controls** (title, fullscreen, size, react to focus/resize), **animating a change** with a picture of the page, **native notifications**, and a **system tray icon** with a menu.

Each is a plugin with a small JS surface. Window controls are already on; the other two are one line of Swift to enable. We'll note exactly where each works, because this is the area with the most per-platform variation.

If the bridge is new to you, read [Talking to the native side](talking-to-the-native-side.md) first.

> Uses swift-pwa **0.8+**; `window.snapshot` needs **0.11.2+**.

---

## The big picture

| Feature | Plugin | On by default? | Where it works |
|---|---|---|---|
| Window controls | `window.*` (`WindowPlugin`) | **Yes — built in** | everywhere (some no-ops on mobile / GTK4) |
| Notifications | `notifications.*` (`NotificationsPlugin`) | opt-in | **all platforms** (Apple needs a bundled app) |
| Tray icon | `tray.*` (`TrayPlugin`) | opt-in | macOS, Linux (GTK3 + GTK4), Windows (not iOS / Android) |

Turn the two opt-in ones on in `configure` (in `Sources/MyApp/App.swift`):

```swift
ctx.use(NotificationsPlugin(SystemNotifications()))

#if !os(Android)
    ctx.use(TrayPlugin(SystemTray()))   // Android has no tray concept
#endif
```

Every backend ships a `SystemTray` / `SystemNotifications` type — a real one where the OS supports it, a harmless no-op stub where it doesn't — so those lines compile everywhere. The one exception is that **Android has no tray type at all**, hence the `#if !os(Android)`.

---

## Part 1 — Window controls (no setup needed)

`WindowPlugin` is auto-installed, so `window.*` is available with nothing to enable. All of these take an optional `id` (omit it and it targets the current window):

```js
// Title
await __SWIFT_PWA__.invoke('window.setTitle', { title: 'Untitled — MyApp' });

// Fullscreen
await __SWIFT_PWA__.invoke('window.setFullscreen', { on: true });
const { value: isFull } = await __SWIFT_PWA__.invoke('window.isFullscreen');

// Size & position
await __SWIFT_PWA__.invoke('window.setSize', { width: 1200, height: 800 });
const { width, height } = await __SWIFT_PWA__.invoke('window.size');

// Lifecycle
await __SWIFT_PWA__.invoke('window.focus');
await __SWIFT_PWA__.invoke('window.minimize');
await __SWIFT_PWA__.invoke('window.close');
```

### React to what the window does

Subscribe to a live stream of window events — resize, focus, fullscreen, and so on — to keep your UI in sync (save the size, pause a game on blur, …):

```js
const unsub = __SWIFT_PWA__.subscribe('window.subscribe', {}, (e) => {
  switch (e.type) {
    case 'didResize':          console.log('now', e.size.width, e.size.height); break;
    case 'didFocus':           resume(); break;
    case 'didBlur':            pause();  break;
    case 'didEnterFullscreen': hideChrome(); break;
    case 'didExitFullscreen':  showChrome(); break;
  }
});
// unsub() to stop listening
```

> **Per-platform reality:** on mobile, windows are full-screen and OS-managed, so `setSize`/`setPosition` are no-ops (Android) or moot (iOS). On the GTK4/Wayland backend, *position* specifically is a no-op — Wayland won't let apps place their own windows. And on both GTK backends, window changes the *user* makes (dragging, alt-tab) don't yet fire `window.subscribe` events — only your programmatic calls do. Everything else works across the board. (Full matrix in the [README](../../README.md#feature-matrix).)

> **Tip:** you usually don't need `window.setSize` to *remember* a size across launches — set `window.remember_state` in `App.swift` and swift-pwa persists it for you (see [pwa.json config](../../README.md#configuring-pwajson)).

### Animate a change with a picture of the page

Native apps cross-fade, slide and peel between states. On the web you can't, because a transition needs the *old* content to still be on screen after you've replaced it — and there's no API that turns a DOM subtree into pixels. (The libraries that try re-implement the renderer in JavaScript: slow, and blind to shadow-root CSS and `@font-face`.)

`window.snapshot` gives you the pixels the engine already has:

```js
// Freeze what's on screen right now into an <img> layered over the page.
async function freezeScreen() {
  const { pngBase64 } = await __SWIFT_PWA__.invoke('window.snapshot');
  const frozen = new Image();
  frozen.src = 'data:image/png;base64,' + pngBase64;
  await frozen.decode();                       // don't animate a half-decoded image
  Object.assign(frozen.style, {
    position: 'fixed', inset: '0', width: '100%', height: '100%',
    zIndex: '9999', pointerEvents: 'none'
  });
  document.body.appendChild(frozen);
  return frozen;
}

// Change the page underneath the frozen copy, then fade the copy away.
async function crossfade(change) {
  const frozen = await freezeScreen();
  change();                                    // the real DOM, now hidden behind it
  await frozen.animate([{ opacity: 1 }, { opacity: 0 }],
                       { duration: 250, easing: 'ease-out' }).finished;
  frozen.remove();
}
```

```js
crossfade(() => showChapter(next));            // and that's the whole transition
```

The order is the thing to get right: **snapshot first, change second.** Every backend flushes pending layout before it captures, so a snapshot taken *after* your change pictures the new state — which is the opposite of what a transition needs.

Ask once whether you can do this at all, rather than catching an error per call:

```js
const { value: canSnapshot } = await __SWIFT_PWA__.invoke('window.canSnapshot');
```

It's the *webview's* pixels, not the screen's, so it works while your window is behind something else and needs no screen-recording permission anywhere.

> **Give your page the whole window.** Put `<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">` in your HTML. Without it, iOS lays the page out inside the safe area while the webview covers the whole screen — so the picture is taller than the page thinks it is and `inset: 0` lines it up wrong.

> **Per-platform reality:** the snapshot comes back as `{ pngBase64, width, height, bytes }`, where `width`/`height` are **device** pixels — `devicePixelRatio` times the CSS size, which is what you want when drawing to a `<canvas>`. A full-window PNG of a page of text costs about **60 ms** on macOS, iOS and Linux, but **239 ms on Windows and 406 ms on Android** (a bigger surface and a slower encode). If you're animating on those two, take the picture when the *gesture starts* rather than when the change lands — a quarter of a second of slack is much easier to find before a finger moves than during. On Android the window also has to be on screen for `<canvas>`, WebGL and video to be captured. Numbers and the per-platform detail: [README footnote 35](../../README.md#feature-matrix).

---

## Part 2 — Native notifications

Two commands: ask permission once, then send. Always request authorization before your first notification — on macOS/iOS and Android 13+ the OS shows a real prompt (elsewhere it just returns `true`):

```js
async function notify(title, body) {
  const { granted } = await __SWIFT_PWA__.invoke('notifications.requestAuthorization');
  if (!granted) return;                          // user said no — respect it
  await __SWIFT_PWA__.invoke('notifications.send', { title, body, sound: true });
}

await notify('Export complete', 'Saved 42 records to disk.');
```

`notifications.send` returns `{ id }` (a string handle) and takes `{ title, body?, sound? }`. That's the whole surface today — one-shot delivery; click-handling, scheduling, and replace-by-id aren't wired yet, so don't build a flow that depends on reacting to a notification tap.

> **macOS/iOS gotcha:** Apple's notification center refuses notifications from a process that isn't a real app bundle — so `notifications.send` will fail when you're running via `swift run` or `swift-pwa dev`. Build a bundle to test them: `swift-pwa build --target macos`, then run the `.app`. If banners still don't show, sign it (`--sign "<identity>"`) — an unsigned bundle can be silently suppressed depending on your system settings. Linux, Windows, and Android have no such requirement.

---

## Part 3 — A system tray icon

The tray lives outside your window — a menu-bar item on macOS, a system-tray icon on Windows/Linux. Set an icon, a tooltip, and a menu, then listen for clicks:

```js
// A PNG on disk (ship it in web/ or a known path). On macOS, pass
// template:true for a monochrome menu-bar-style icon that adapts to light/dark.
await __SWIFT_PWA__.invoke('tray.setIcon',    { path: '/path/to/icon.png' });
await __SWIFT_PWA__.invoke('tray.setTooltip', { text: 'MyApp — 3 tasks running' });

await __SWIFT_PWA__.invoke('tray.setMenu', { items: [
  { id: 'show', label: 'Show window' },
  { id: '',     label: '', separator: true },
  { id: 'quit', label: 'Quit', enabled: true },
]});

// Menu clicks (and, on macOS, bare icon clicks) arrive on this stream:
const unsub = __SWIFT_PWA__.subscribe('tray.subscribe', {}, (e) => {
  if (e.type === 'menuItemClicked') {
    if (e.id === 'show') __SWIFT_PWA__.invoke('window.focus');
    if (e.id === 'quit') __SWIFT_PWA__.invoke('app.quit');
  } else if (e.type === 'click') {
    __SWIFT_PWA__.invoke('window.focus');   // macOS only, and only with no menu set
  }
});
```

The menu is a flat list of `{ id, label, enabled?, separator? }`; a click sends `{ type: 'menuItemClicked', id }` on `tray.subscribe`. (Bare-icon `click` events only fire on macOS, and only when no menu is attached — with a menu, the OS shows the menu instead.)

### Degrade gracefully where there's no tray

The tray exists on macOS, Linux (both GTK3 and GTK4), and Windows — **not** iOS or Android. Even where it's supported, the icon only *shows* if the desktop runs a tray host: on Linux GTK4 the tray is a StatusNotifierItem, which Plasma / Sway / XFCE display but bare GNOME Shell needs the AppIndicator extension for. Because the opt-in stub still registers the commands on the unsupported platforms (they just do nothing), don't rely on "does the command exist." Check the OS instead, and hide any tray-dependent UI where it won't show:

```js
const info = await __SWIFT_PWA__.invoke('__platform.info');   // { os, commands, ... }
const trayLikelyWorks = ['macos', 'windows', 'linux'].includes(info.os);
if (!trayLikelyWorks) {
  // e.g. keep a "Quit" button in-window instead of relying on the tray menu
}
```

> Don't make the tray the *only* way to reach an important action — always leave an in-window path too, so mobile users (and desktop users whose panel has no tray host) aren't stuck.

---

## Putting it together

A common desktop pattern, now in reach: minimize-to-tray. Listen for the window closing, cancel it, hide instead, and let the tray bring it back — with notifications for background events:

- Window: `window.subscribe` → on `willClose`, hide the window and keep running.
- Tray: a "Show window" menu item calls `window.focus`; "Quit" calls `app.quit`.
- Notifications: `notifications.send` when a background job finishes so the user knows to reopen.

Each piece is a few lines from the sections above.

---

## Where to go next

- The full command list and payloads: [JavaScript API](../javascript-api.md); the per-platform truth table: the [feature matrix](../../README.md#feature-matrix).
- [Talking to the native side](talking-to-the-native-side.md) — the bridge these commands ride on.
- A worked example wiring the tray (with capability-gated buttons): [`Examples/HelloPWA`](../../Examples/HelloPWA).
- [Shipping your app](shipping-your-app.md) — bundle it (also what makes macOS notifications work).
