# Talking to the native side (the bridge + your first custom command)

**Who this is for:** you've got a swift-pwa app running (if not, do [Hello, World](hello-world.md) first) and now you want your web code to *do* something native — call an OS feature, or run a bit of your own Swift and hand the result back to the page.

This is the concept that unlocks everything else. Once you can call across the bridge, every built-in command makes sense, and — when we don't ship the command you need — you can add your own in a few lines.

You'll write a little JavaScript and a few clearly-marked lines of Swift. That's the whole job.

> Uses swift-pwa **0.8+**.

---

## The big picture

Your web page and the native shell talk over one tiny bridge. From JS it's a single object, `__SWIFT_PWA__`, injected before your page runs (so it's always there — nothing to import or await):

```
  Your web app (JS)                         The native shell (Swift)
    invoke('cmd', {...})   ──── request ───▶  a handler runs
        Promise<result>    ◀──── reply ─────  returns a value

    subscribe('cmd', {...}, cb)  ── request ─▶  a handler streams
        cb(event) … cb(event)    ◀── events ──  yields values over time

    on('channel', cb)      ◀──── push ──────  Swift calls ctx.emit(...)
```

Three verbs cover everything:

| From JS | Native side | Use it for |
|---|---|---|
| `invoke(cmd, payload)` → `Promise` | a handler that **returns a value** | one-shot requests ("save this", "what's the version?") |
| `subscribe(cmd, payload, cb)` → `unsubscribe()` | a handler that **streams values** | progress, live updates, anything ongoing |
| `on(channel, cb)` → `off()` | Swift **pushes** via `ctx.emit(...)` | server-initiated events ("data changed", "job done") |

Let's use each one.

---

## Part 1 — Call a built-in command

swift-pwa ships lots of commands. You already saw two in the Hello World starter page. Here's the shape:

```js
// invoke: run once, await the result
await __SWIFT_PWA__.invoke('window.setTitle', { title: 'Hello from JS' });

// subscribe: a stream of events; call the returned function to stop
const unsubscribe = __SWIFT_PWA__.subscribe('window.subscribe', {}, (event) => {
  console.log('window event:', event);
});
// later… unsubscribe();
```

The full catalog (`window.*`, `app.*`, `dialog.*`, `fs.*`, `net.*`, `ai.*`, …) is in the [JavaScript API reference](../javascript-api.md) and summarized in the [feature matrix](../../README.md#feature-matrix). Many are opt-in — you turn a group on by adding its plugin in `App.swift` (`ctx.use(FsPlugin(SystemFs()))`, etc.). But you don't have to wait for us: you can register your own command right now.

---

## Part 2 — Your first custom command

Say you want a command that returns the current time. Open `Sources/MyApp/App.swift` and, inside the `configure` function (the `func configure(_ ctx: any AppContext) throws { … }` block), add:

```swift
// A tiny result type — any Codable struct works.
struct NowResult: Codable, Sendable {
    let iso: String
}

// Register a command named "app.now" that returns the current time.
ctx.registry.register("app.now", typed: { (_: EmptyArgs, _) -> NowResult in
    NowResult(iso: ISO8601DateFormatter().string(from: Date()))
})
```

That's the entire native side. Now call it from your web code:

```js
const { iso } = await __SWIFT_PWA__.invoke('app.now');
console.log('the native side says it is', iso);
```

Rebuild (`swift-pwa dev` picks up Swift changes on restart) and it works.

**What just happened:**

- `ctx.registry.register(name, typed:)` adds a command. The closure is `(Args, _) -> Result`.
- **`Args`** and **`Result`** are plain `Codable & Sendable` Swift structs — swift-pwa decodes the JS `payload` into `Args` and encodes your `Result` back to JS for you. Here we take no input, so we use the built-in `EmptyArgs`.
- The name (`"app.now"`) is what JS passes to `invoke`. Namespacing with a dot (`app.`, `myfeature.`) is convention, not required.

A command *with* input is just as short:

```swift
struct GreetArgs: Codable, Sendable { let name: String }

ctx.registry.register("app.greet", typed: { (args: GreetArgs, _) -> String in
    "hello, \(args.name)"
})
```

```js
const greeting = await __SWIFT_PWA__.invoke('app.greet', { name: 'Ada' });
// → "hello, Ada"
```

> **No `await` on `register`.** `ctx.registry.register(...)` is a plain synchronous call — don't put `await` in front of it. (Registration is deliberately synchronous so it works before the UI event loop starts.)

---

## Part 3 — A streaming command

When the native side has *more than one* thing to send over time — progress, ticks, a live feed — use `registerStream` and subscribe to it from JS. Return an `AsyncThrowingStream`:

```swift
ctx.registry.registerStream("app.countdown", typed: { (_: EmptyArgs, _) -> AsyncThrowingStream<Int, any Error> in
    AsyncThrowingStream { continuation in
        let task = Task {
            for i in stride(from: 5, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                continuation.yield(i)
            }
            continuation.finish()
        }
        // Called when the page unsubscribes or the window closes — stop the work.
        continuation.onTermination = { _ in task.cancel() }
    }
})
```

```js
const stop = __SWIFT_PWA__.subscribe('app.countdown', {}, (n) => {
  console.log(n);            // 5, 4, 3, 2, 1, 0
});
// call stop() to cancel early — that triggers onTermination on the Swift side
```

Each `continuation.yield(...)` becomes one callback in JS; `finish()` ends the stream. The `onTermination` hook is important: it fires when the user unsubscribes *or* closes the window, so any ongoing work (a timer, a file read, a network call) gets cleaned up — no orphans.

---

## Part 4 — Push from Swift (no request needed)

Sometimes the native side needs to tell the page about something the page never asked for — a background job finished, data changed, a file was dropped on the app. That's `ctx.emit` on the Swift side and `on` in JS. (The `events.*` plumbing is always installed — nothing to opt into.)

```swift
// anywhere you have `ctx` — e.g. after some background work finishes
try ctx.emit("library:changed", ["added": 3])
```

```js
const off = __SWIFT_PWA__.on('library:changed', (payload) => {
  console.log('library changed:', payload);   // { added: 3 }
});
// off() to stop listening
```

`emit` fans out to **every** window that's listening on that channel. Pass `retain: true` (`ctx.emit("job:done", result, retain: true)`) to also replay the latest value to any window that subscribes *later* — handy for "current status" that a freshly-opened window should see immediately.

---

## Handling errors

Throw from your handler and the JS `invoke` Promise rejects. For a stable code your web code can branch on, throw a `BridgeError`:

```swift
ctx.registry.register("app.risky", typed: { (_: EmptyArgs, _) -> String in
    guard someCondition else {
        throw BridgeError(code: "E_MY_THING", message: "it didn't work")
    }
    return "ok"
})
```

```js
try {
  await __SWIFT_PWA__.invoke('app.risky');
} catch (e) {
  console.log(e.code, e.message);   // "E_MY_THING" "it didn't work"
}
```

Any other error you throw is wrapped as `E_HANDLER` automatically, so nothing crashes the app — the page just gets a rejected Promise.

---

## One caveat, for when your handler touches the window

The examples above just compute and return a value, which is the common case and needs nothing special. But the moment a handler needs to touch the **window or other UI** (resize it, read its state), remember: **handlers run off the main/UI thread.** Hop onto the UI thread with `MainThread.run { … }` for that work — *not* `await MainActor.run { … }`, which can hang on Linux/Windows event loops:

```swift
ctx.registry.register("app.grow", typed: { (_: EmptyArgs, ctx) -> Bool in
    await MainThread.run {
        // UI-touching work goes here
    }
    return true
})
```

You'll only reach for this once you're driving windows directly; a plain "compute and return" command (like everything in Parts 2–4) doesn't need it. If you're bundling several related commands to reuse across apps, graduate them into a `Plugin` — see the [Swift API reference](../swift-api.md).

---

## Where to go next

- Tired of stringly-typed calls? Generate a **typed TypeScript client** for the bridge with `swift-pwa codegen` — command names, payloads, and results become type-checked, so a rename fails the build instead of the user's session. See [Typed client codegen](../swift-api.md#typed-client-codegen).
- The full command catalog: [JavaScript API](../javascript-api.md) and [Swift API](../swift-api.md).
- A complete worked example that registers a custom command (and more): [`Examples/HelloPWA`](../../Examples/HelloPWA).
- Put the bridge to work: [Saving and loading files](saving-and-loading-files.md), [On-device AI](on-device-ai.md).
- Ready to release? [Shipping your app](shipping-your-app.md).
