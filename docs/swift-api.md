# Swift API

## Hello, world

```swift
import SwiftPWA

@main
struct HelloApp {
    static func main() async throws {
        let runtime = try SwiftPWA.runtime()
        try runtime.run { ctx in
            _ = try ctx.createWindow(.init(
                title: "Hello",
                size: .init(width: 1024, height: 768),
                content: .bundled(
                    Bundle.main.bundleURL.appendingPathComponent("web/index.html")
                )
            ))
        }
    }
}
```

`SwiftPWA.runtime()` returns the platform-appropriate `AppRuntime` —
`MacAppRuntime`, `IOSAppRuntime`, `GTKAppRuntime`, or
`WindowsAppRuntime`. The umbrella module re-exports the platform
backend through `@_exported import`, so the call site doesn't change.

## Registering custom commands

```swift
struct GreetArgs: Codable, Sendable { let name: String }

try runtime.run { ctx in
    await ctx.registry.register("my.greet") { (args: GreetArgs, _) in
        "hello, \(args.name)"
    }

    // Streaming command — every yield becomes an `event` frame on JS;
    // returning ends the stream.
    await ctx.registry.registerStream("my.tick") { (_: EmptyArgs, ctx) in
        AsyncThrowingStream<Int, any Error> { continuation in
            Task {
                for i in 0 ..< 10 {
                    try? await Task.sleep(for: .seconds(1))
                    continuation.yield(i)
                }
                continuation.finish()
            }
        }
    }
}
```

`Args` and the return type must be `Codable + Sendable`. The bridge
runtime serializes them through `JSONEncoder` / `JSONDecoder`, so any
JSON-compatible shape works.

## Built-in plugins

`WindowPlugin`, `AppPlugin` (`app.quit` / `app.name` / `app.version`),
`EventsPlugin` (the server-push bus, see below), and `ClipboardPlugin`
are auto-installed on every backend — apps don't need to opt in.
Everything else is à la carte so apps that don't need a tray / file
dialogs / biometrics don't pay the binary or runtime cost.

```swift
try runtime.run { ctx in
    ctx.use(DialogPlugin(SystemDialog()))
    ctx.use(FsPlugin(SystemFs()))
    ctx.use(BiometricAuthPlugin(SystemBiometricAuth()))
    ctx.use(TrayPlugin(SystemTray()))
    ctx.use(NotificationsPlugin(SystemNotifications()))
    ctx.use(ProcessPlugin(SystemProcess()))   // subprocesses; desktop only
    ctx.use(UpdaterPlugin(AppleUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "BASE64-OF-32-RAW-ED25519-BYTES" // nil on iOS
    )))

    _ = try ctx.createWindow(...)
}
```

The constructor for each plugin takes a `System*` adapter — the
platform-specific implementation provided by the umbrella module.
Tests substitute `_SwiftPWATestSupport.Mock*` instead, which the same
plugin shape accepts without changes.

`AIPlugin` (on-device LLM inference behind `ai.*`) is also à la carte but
takes an `AIBackend` rather than a `System*` adapter: `ctx.use(AIPlugin(MyBackend()))`,
or `ctx.use(AIPlugin())` to wire the JS contract against `NoneBackend`
(reports `available:false`) until a real backend lands. Shipping backends:
`FoundationModelsBackend` (`SwiftPWAFoundationModels`) and `LlamaBackend`
(`SwiftPWALlama`, opt in via `ai.local_llama` in `pwa.json`). See
[docs/ai-plugin.md](ai-plugin.md).

`VisionPlugin` (promptable on-device image segmentation behind
`ai.vision.*`) follows the same shape but takes a `SegmentationBackend` —
a **separate** protocol/plugin from `AIBackend`/`AIPlugin` (segmentation
is discriminative, not generative, and needs an encode-once/decode-many
session primitive `AIBackend` has no room for):
`ctx.use(VisionPlugin(MyBackend()))`, or `ctx.use(VisionPlugin())` to wire
the JS contract against `NoneSegmentationBackend`. Shipping backend:
`MobileSAMBackend` (`SwiftPWASegmentation`, Apple-only, env-gated behind
`SWIFT_PWA_ONNXRUNTIME`) — runs MobileSAM's encoder plus one of two decoder
variants as ONNX Runtime sessions, verified against real weights (see the
`mobilesam-vendor` GitHub Release); takes on-disk
`encoderPath`/`decoderSinglePath`/`decoderMultiPath` directly (no
downloadable-model tier yet). See
[docs/proposals/segmentation-plugin.md](proposals/segmentation-plugin.md)
for the design and current implementation status.

## Multi-window

```swift
let main = try ctx.createWindow(.init(title: "Main", ...))
let inspector = try ctx.createWindow(.init(title: "Inspector",
    size: .init(width: 480, height: 720),
    content: .bundled(...inspector.html)))

ctx.windows         // → [main, inspector]
inspector.focus()
inspector.close()
```

`ctx.createWindow` is supported on macOS / Linux / Windows. iOS is
UIScene-aware: a single scene is polished, multi-scene scaffolded.
The cross-platform `Window` protocol documents per-method support;
unsupported operations log a one-shot warning rather than throwing.

## Serving extra directories (content packs)

`ctx.serveDirectory(_:at:)` mounts a directory on the **bundle origin**
under an app-chosen path prefix, so page JS can reference it with an
origin-relative URL that works unchanged on every backend:

```swift
@MainActor func configure(_ ctx: any AppContext) throws {
    let packs = ctx.dataDirectory().appendingPathComponent("packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    ctx.serveDirectory(packs, at: "/packs")   // served at /packs/... on the bundle origin
    _ = try ctx.createWindow(...)
}
```

```js
// Same code on macOS, Linux, Windows, iOS, Android:
videoEl.src = `/packs/${packId}/clip.webm`;   // streamed with HTTP range requests
```

- **Read-only** (GET). Writes still go through `fs.*`. Mounting is the
  app author's decision — page JS can't mount arbitrary paths.
- Mounts can be added/removed at runtime (`ctx.unserveDirectory(at:)`)
  and take effect for in-flight requests, so a pack extracted *after* a
  window exists is immediately fetchable — no per-pack call needed; the
  app mounts the **container** once.
- Range / `206 Partial Content` is honored on all backends, so a large
  `<video>` seeks/streams off disk instead of buffering.
- The prefix is fully app-chosen (anything but the bundle root `/`).

**Android** builds its asset loader before any Swift runs, so a mount
that must exist at startup is declared in `pwa.json` instead — the
bundler wires it into the generated Activity:

```json
"build": { "serve": [ { "mount": "/packs", "from": "data/packs" } ] }
```

`from` is rooted at the per-app data dir by default (a `cache/…` prefix
roots it at the cache dir). On desktop the imperative
`ctx.serveDirectory` is the equivalent and is read at `configure()` time;
a runtime `serveDirectory` for an *undeclared* prefix is a desktop-only
capability. See [docs/design/runtime-content-packs.md](design/runtime-content-packs.md).

## Window events

```swift
let main = try ctx.createWindow(...)

await main.subscribe { event in
    switch event {
    case .didFocus:        /* ... */
    case .didBlur:         /* ... */
    case .didResize(let s):/* s is in DIPs */
    case .didMove(let p):
    case .didMinimize, .didDeminiaturize:
    case .didEnterFullscreen, .didExitFullscreen:
    case .willClose:       /* ... */
    }
}
```

WM-driven focus / minimize / fullscreen events on Linux are currently
only emitted when the corresponding programmatic method is called —
user-driven changes (alt-tab, click another window) don't yet reach
subscribers on either GTK backend. See
[docs/linux-setup.md](linux-setup.md#known-limitations-on-linux).

## Server-push events

`WindowPlugin`'s `window.subscribe` lets JS *pull* window events. When Swift
needs to push something the client never asked for — a file appeared, an import
finished, a background job progressed — use the app-wide event bus. It's owned
by the `AppContext` (`ctx.events`), auto-installed as `EventsPlugin`, and fans
one `emit` out to subscribers in **every** window.

```swift
// From anywhere that has the context (a command handler, a plugin):
try ctx.emit("library:changed", ["added": 3])          // typed, Encodable
ctx.emit("app:ready")                                    // payload-less signal

// Retain the latest value so a window that subscribes later still sees it:
try ctx.emit("job:progress", Progress(pct: 40), retain: true)
```

`ctx.events` is `Sendable`, so to push from a background thread (a file watcher,
an import `Task`) capture it once and skip the main-actor hop:

```swift
let bus = ctx.events
watcher.onChange = { path in try? bus.emit("fs:changed", ["path": path]) }
```

JS receives these via `__SWIFT_PWA__.on(channel, cb)` — see
[javascript-api.md](javascript-api.md#events--server-initiated-push). The bus
is best-effort in-memory pub/sub: no persistence, and (apart from a retained
channel's latest value) no buffering for windows that aren't subscribed yet.

## Subprocesses (desktop only)

`ProcessPlugin` lets an app host a "thick" local backend — a converter, an
indexer, a local model server, or an out-of-process synthesizer — instead of
being a purely thin PWA wrapper. Register it with a runner:

```swift
ctx.use(ProcessPlugin(SystemProcess()))
```

`SystemProcess` wraps Foundation's `Process` on macOS / Linux / Windows; on
iOS / Android the sandbox forbids spawning, so `spawn` throws `E_UNIMPLEMENTED`
(the plugin still compiles everywhere). JS drives it through `process.stream` /
`process.write` / `process.kill` — see
[javascript-api.md](javascript-api.md#process--subprocesses-desktop-only).

The key correctness property is **guaranteed teardown**: a child's lifetime is
tied to its `process.stream` subscription. When JS unsubscribes or the owning
window closes, `BridgeRuntime` cancels the subscription, which reaches the
stream's `onTermination` and terminates the child — so a child can't outlive
the page that spawned it. To inject a fake in tests, conform to `ProcessRunner`
/ `ProcessChild`. Full reference: [docs/process-plugin.md](process-plugin.md).

## Concurrency model

Two non-obvious points worth pinning:

1. **`CommandRegistry` is a class with `NSLock`-guarded state, not an
   actor.** Registration is *synchronous* on purpose so user
   `configure` closures can run on a thread that isn't pumping Swift's
   MainActor executor — typically the main thread before `gtk_main()`
   enters its loop on Linux.
2. **`BridgeRuntime` is *not* `@MainActor`.** Backends are responsible
   for hopping to the platform UI thread internally via
   `MainThread.run`, which routes through a per-backend dispatch hook
   installed at startup (`DispatchQueue.main` on Apple, `g_idle_add`
   on GTK, a hidden `HWND_MESSAGE` window on Windows). Use this rather
   than `await MainActor.run` in any code path that may execute under
   `gtk_main()` or a Win32 message pump — the libdispatch main queue
   isn't drained by either, and a `Task { @MainActor in ... }` will
   never fire.

These are the same tripwires `Examples/HelloPWA` is built against; if
you find yourself fighting a "the call hangs" symptom, the answer is
almost always to route through `MainThread.run`.
