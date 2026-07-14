# Multi-window apps

**Who this is for:** you want more than one native window — a main window plus an inspector, a detached preview, a separate settings window — and you want them to talk to each other (a selection in one updates the other).

Two things to know up front: **windows are created in Swift** (there's no `window.open` bridge command), and **windows talk to each other over the `events.*` bus**. We'll do both, then cover per-window state and the per-platform reality.

Assumes you've met the bridge — see [Talking to the native side](talking-to-the-native-side.md).

> Uses swift-pwa **0.8+**. Fully supported on macOS / Linux / Windows (see the per-platform notes at the end for mobile).

---

## The big picture

```
  JS ──invoke('app.openInspector')──▶  a custom Swift command
                                         └─ ctx.createWindow(...) ──▶ new native window
  Window A ──emit('selection', …)──▶  events bus  ──▶ Window B's on('selection', …)
```

---

## Step 1 — Let JS open a window

There's no built-in "open a window" command — window creation lives in Swift (`ctx.createWindow`). So you expose your *own* command that does it, and return the new window's id. In `configure`:

```swift
struct WindowIDResult: Codable, Sendable { let id: String }

// Capture the folder your web assets live in (same as your main window uses).
ctx.registry.register("app.openInspector", typed: { (_: EmptyArgs, _) -> WindowIDResult in
    let win = try ctx.createWindow(WindowConfig(
        title: "Inspector",
        size: Size(width: 480, height: 720),
        content: .bundled(directory: webRoot, entry: "inspector.html"),
        rememberState: true,
        stateKey: "inspector"          // its own state key — see Step 4
    ))
    return WindowIDResult(id: win.id.raw)
})
```

Now the page can open it and learn its id:

```js
const { id: inspectorId } = await __SWIFT_PWA__.invoke('app.openInspector');
```

Each window loads its own HTML (`inspector.html` here, alongside your `index.html` in `web/`). `WindowContent` is either `.bundled(directory:entry:)` for your app's pages or `.remote(url)` for a URL.

---

## Step 2 — Know which window you're in, and target others

Every `window.*` command runs against the **calling** window by default (the bridge tags each call with its origin window), so a page can always control itself with no id:

```js
const { id } = await __SWIFT_PWA__.invoke('window.id');       // my own id
const { ids } = await __SWIFT_PWA__.invoke('window.list');    // all open window ids
```

To act on a *different* window, pass its `id` (the one you got back from `app.openInspector`, or from `window.list`):

```js
await __SWIFT_PWA__.invoke('window.focus', { id: inspectorId });
await __SWIFT_PWA__.invoke('window.close', { id: inspectorId });
```

---

## Step 3 — Make the windows talk

Windows share one event bus. Any window can **emit** on a channel, and every window that's **listening** on that channel receives it — that's your cross-window messaging:

```js
// In the main window, when the selection changes:
await __SWIFT_PWA__.emit('selection:changed', { recordId: 'abc' });

// In the inspector window:
const off = __SWIFT_PWA__.on('selection:changed', ({ recordId }) => {
  loadRecord(recordId);
});
```

Pass `{ retain: true }` when emitting a "current state" value you want a window that opens *later* to receive immediately:

```js
await __SWIFT_PWA__.emit('selection:changed', { recordId: 'abc' }, { retain: true });
// a freshly-opened inspector's on(...) fires right away with the last value
```

Swift can join the conversation too — `ctx.emit("selection:changed", ["recordId": "abc"])` fans out to every window's `on(...)` the same way.

---

## Step 4 — Give each window its own remembered size/position

Set `rememberState: true` and a **distinct `stateKey` per window** so their frames are saved separately (to a `window-state.json` in the app's data dir) and restored next launch:

```swift
// main window
ctx.createWindow(WindowConfig(..., rememberState: true, stateKey: "main"))
// inspector
ctx.createWindow(WindowConfig(..., rememberState: true, stateKey: "inspector"))
```

Two live windows sharing a `stateKey` will fight over the same saved geometry — so always give each kind of window its own key. (Desktop only: macOS/GTK3/Windows restore size *and* position; GTK4/Wayland restore size only.)

---

## Per-platform reality

Multi-window behaves differently across platforms — design for it:

| Platform | Behavior |
|---|---|
| macOS / Linux / Windows | Full support — each `createWindow` is an independent native window sharing one app context and event bus. |
| iOS | UIScene-based: a single scene is polished; multi-scene is scaffolded but not the recommended default. |
| Android | **Activity-per-window** — a second `createWindow` launches a new Activity on the back stack (system-back returns to the caller), which is the native "open a detail view" UX. |

> ⚠️ **Android caveat worth designing around:** on Android only the **foreground** Activity's web page receives bridge deliveries, so a Swift `ctx.emit(...)` (or a JS `emit` from one Activity) reaches the visible window, not both at once — unlike desktop's true fan-out to every open window. And `setTitle`/`setFullscreen`/`close` don't reach across Activities. Treat Android's "second window" as a pushed screen, not a peer you drive remotely — do per-window work from inside that window's own JS.

Because of this spread, don't make a second window the *only* way to reach something important — keep an in-window path too, so iOS and Android users aren't stuck.

---

## Where to go next

- [Talking to the native side](talking-to-the-native-side.md) — custom commands (Step 1) and the `events.*` bus (Step 3) in more depth.
- [Making it feel native](making-it-feel-native.md) — window controls and lifecycle events.
- [JavaScript API](../javascript-api.md) / [Swift API](../swift-api.md) — full `window.*`, `events.*`, and `createWindow` references.
