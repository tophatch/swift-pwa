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
    // Registration is synchronous — no `await`.
    ctx.registry.register("my.greet", typed: { (args: GreetArgs, _) -> String in
        "hello, \(args.name)"
    })

    // Streaming command — every yield becomes an `event` frame on JS;
    // finishing the stream ends it.
    ctx.registry.registerStream("my.tick", typed: { (_: EmptyArgs, _) -> AsyncThrowingStream<Int, any Error> in
        AsyncThrowingStream<Int, any Error> { continuation in
            Task {
                for i in 0 ..< 10 {
                    try? await Task.sleep(for: .seconds(1))
                    continuation.yield(i)
                }
                continuation.finish()
            }
        }
    })
}
```

`Args` and the return type must be `Codable + Sendable`. The bridge
runtime serializes them through `JSONEncoder` / `JSONDecoder`, so any
JSON-compatible shape works.

### Duplex sessions

`registerStream` is server → client only. `registerSession` is the two-way
form: the JS side opens it with `__SWIFT_PWA__.session(name, openArgs, handlers)`
and pushes client frames into it (`sess.push(frame)`) while the handler streams
downstream events. The handler receives the decoded open args, a typed
`BridgeInbound<Frame>` of the pushed client frames, and returns its downstream
stream:

```swift
struct EvalConfig: Codable, Sendable { let lang: String }
struct AudioChunk: Codable, Sendable { let pcm: [Float] }
enum EvalEvent: Codable, Sendable { case partial(String), final(String) }

ctx.registry.registerSession(
    "speech.evaluate",
    typed: { (open: EvalConfig, inbound: BridgeInbound<AudioChunk>, _)
        -> AsyncThrowingStream<EvalEvent, any Error> in
        AsyncThrowingStream { continuation in
            let task = Task {
                for await chunk in inbound {                 // client → server
                    continuation.yield(.partial(feed(chunk, open.lang)))
                }
                continuation.yield(.final(finish()))         // server → client
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
)
```

The `inbound` loop finishes when the client closes the session, the returned
stream completes, or the window tears down — so `for await` exits cleanly on any
of those. A malformed push (one that doesn't decode to `Frame`) is skipped and
logged rather than ending the session.

Client pushes are buffered with a bounded drop-oldest policy (the JS
`postMessage` can't be back-pressured). Size it per command with
`registerSession(name, maxBufferedFrames: 256, typed:)` (default 256), and read
`inbound.droppedCount` at any time to see how many frames were dropped because
the buffer overflowed — e.g. to surface a "you're sending faster than I can
process" signal, or to ack-gate:

```swift
for await chunk in inbound {
    let dropped = inbound.droppedCount
    if dropped > lastDropped {
        continuation.yield(.warning(droppedSoFar: dropped))
        lastDropped = dropped
    }
    // … process chunk …
}
```

The JS side and its trade-offs are in
[docs/javascript-api.md](javascript-api.md#duplex-sessions-session).

## Typed client codegen

Every command you register through a `typed:` variant is captured in a
**command catalog** — one `CommandDescriptor { name, kind, args, result,
inbound? }` per command, with the arg/result/frame *shapes* derived
automatically from your `Codable` structs (no annotation required). `swift-pwa
codegen` turns that catalog into a typed TypeScript client over `__SWIFT_PWA__`,
so JS call sites autocomplete and fail the build on a renamed command or a
changed payload instead of failing at runtime.

Run it from your app's directory:

```bash
swift-pwa codegen -o web/bridge.ts        # build app, dump catalog, write client
swift-pwa codegen -o web/bridge.ts --check # CI drift guard: fail if stale
```

By default it obtains the catalog **headlessly**: it builds the app (`swift run
-c debug`, override with `--configuration release`) and runs it once with the
`SWIFT_PWA_DESCRIBE` environment variable set to a temp path. The shipped
backends check that variable at the top of `run(configure:)` — when it's set,
the runtime installs the built-in plugins, runs *your* `configure` closure so
every plugin (including dynamically-named ones) registers, writes the catalog to
that path, and **exits before opening a window**. No devtools round-trip, no
hand-maintained catalog file.

> **Your `configure` closure must be pure up to registration.** The headless
> dump runs it for real: `createWindow` returns an inert no-op window and
> `serveDirectory` / `emit` are inert, but any *other* side effect (kicking off
> a model download, spawning a process) still fires during codegen. Guard such
> work with `if HeadlessDescribe.isDumping { return }` after your `ctx.use(…)`
> calls, or move it out of `configure`.

Alternatives: pass `--catalog <json>` to generate from a pre-captured
`__bridge.describe` output instead of building; the headless path is
desktop-only (the codegen step runs on your dev/CI machine, not the device), so
there's no Android hook. Raw (non-`typed:`) registrations have no static shape,
so they're omitted from the generated client — model them with a `typed:`
variant to include them.

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
`MobileSAMBackend` (`SwiftPWASegmentation`, **all platforms** — Apple + Android
since 0.8.0, Linux x86_64 + Windows x64 since; opt in via `ai.local_onnx_runtime`
in `pwa.json`) — runs MobileSAM's encoder plus one of two
decoder variants as ONNX Runtime sessions, verified against real weights
(see the `mobilesam-vendor` GitHub Release). Two initializers, mirroring
`LlamaBackend`: `init(encoderPath:decoderSinglePath:decoderMultiPath:)` for
weights already on disk (bundled / bring-your-own), or
`init(cacheDirectory:source:)` for the **downloadable** tier — `ai.vision.ensureModel`
then fetches the three ONNX files (default `MobileSAMModelSource.mobileSAM`,
resumable + checksum-pinned via `ModelDownloader`) into `cacheDirectory` on
first use. Image decode/resize is per-platform: CoreGraphics/ImageIO on Apple,
a `vision.preprocessImage` RPC to Kotlin's `BitmapFactory` on Android, and a
vendored stb_image + pure-Swift bilinear resize on Linux/Windows desktop (no
CoreGraphics there). Desktop links Microsoft's prebuilt CPU ONNX Runtime,
staged into the AppImage / next to the `.exe` automatically (Linux needs Swift
6.1+ to build the segmentation target). `MobileSAMBackend` also implements
**automatic mask generation** (`ai.vision.segmentAll` / `segmentAllStream`,
`autoMask: true`) — a grid-of-prompts sweep + NMS returning every distinct
object as its own mask, streaming per-cell progress — and
**`ai.vision.benchmark`** (synthetic encode/decode/AMG timing → a coarse
`high`/`mid`/`low` `deviceClass`). See
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
- Content types are derived from the file extension and cover the web-facing
  set — HTML/JS/CSS/JSON/WASM, PNG/JPEG/WebP/GIF/SVG/ICO, HEIC/HEIF/AVIF, the
  common audio and video containers, and the four web font formats. Anything
  else is served as `application/octet-stream`.
- **Whether an image format renders is the engine's decision, not the served
  type's.** Measured by driving a real app on each engine:

  | | HEIC | AVIF |
  |---|---|---|
  | WKWebView (macOS, iOS) | renders | renders |
  | WebKitGTK 4.1 / 6.0 | never | never |
  | WebView2 (Chromium) | never | renders |
  | Android `WebView` (Chromium) | never | renders |

  Apple's WebKit also *sniffs*, so both render there even when the declared type
  is wrong. WebKitGTK decodes neither at any type: the builds distros ship link
  no libheif or libavif (they carry JPEG XL instead), so there is no decoder to
  reach. Chromium has AVIF but no HEIC, on both desktop and Android. A
  picture-heavy app that must run everywhere should transcode HEIC on import
  rather than rely on the webview — note that the *platform* underneath usually
  can decode it even where its webview cannot, which is what
  [image-transcode.md](proposals/image-transcode.md) proposes exposing.

- **On Windows the bundle's content types come from Chromium, not this table.**
  The bundle is served natively by `SetVirtualHostNameToFolderMapping`, so
  WebView2 decides the type from its own extension mapping — measured, `.avif`
  arrives as `image/avif` and `.heic` as `application/octet-stream` regardless
  of what `AssetProvider` would have said. The table above governs the
  interception path — `serveDirectory` mounts, the SPA fallback, and single-file
  embedded assets — and every other backend end to end.

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

## Finding your web bundle

The generated `App.swift` needs one line to locate the app's web directory:

```swift
content = try WindowContent.bundledWeb(entry: "index.html", spaFallback: false)
```

It resolves, in order: a single-file exe's embedded overlay, `SWIFT_PWA_WEB_ROOT`
(driver builds only — what `swift-pwa drive` sets), Android's asset host,
`Bundle.main.resourceURL/web` (where `swift-pwa build` puts it), then any
`fallbacks` you pass. It **throws** listing every path it tried rather than
handing you a blank window.

If you declare `resources: [.copy("web")]` in `Package.swift`, add the module
bundle so a plain `swift run` finds it too — Core can't reach another module's
bundle itself:

```swift
content = try WindowContent.bundledWeb(
    fallbacks: [Bundle.module.bundleURL.appendingPathComponent("web")]
)
```

SwiftPM copies declared resources on every build, so for a large asset tree
prefer leaving it undeclared and letting `swift-pwa build` stage it — `dev` and
`drive` supply it during development.

## Offering commands to an AI agent (desktop only)

`AgentPlugin` declares which of your app's commands are *eligible* to be
offered to an agent. It exposes nothing on its own — a user still has to turn
access on at runtime.

```swift
ctx.use(AgentPlugin(tools: [
    AgentTool(command: "book.open",   description: "Open a book by id.", readOnly: true),
    AgentTool(command: "book.delete", description: "Permanently delete a book.", destructive: true)
]))
```

The same list belongs in `pwa.json` under `agent.expose`, and the two have to
agree: `pwa.json` is the copy a reviewer reads, the compiled list is what the
runtime enforces, and `swift-pwa build` fails on any drift between them —
including a changed description or annotation. It also resolves every entry
against the app's real command catalog, so a rename can't quietly un-expose
something.

The plugin registers `agent.status` / `enable` / `disable` / `state` for your
page to build a consent UI with (see
[javascript-api.md](javascript-api.md#agent--let-a-user-offer-your-commands-to-an-ai-agent-desktop-only)).
swift-pwa owns the consent *state* and a system-tray indicator the app can't
suppress; the app owns the *asking*, since a swift-pwa-drawn dialog would look
foreign across five platforms.

To hold the surface yourself — to mirror it in native UI, or revoke on some app
event — construct it directly and keep the reference:

```swift
let surface = AgentSurface(tools: tools)
ctx.use(AgentPlugin(surface: surface))
// later: surface.disable()
```

Only **unary** commands whose arguments are a struct (or nothing) can be tools;
`secrets.*`, `agent.*` and `__*` are refused outright. Full reference:
[docs/agent-tools.md](agent-tools.md).

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
