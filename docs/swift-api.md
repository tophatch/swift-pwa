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

### Who is calling

The second parameter a typed handler receives is the `CommandContext`. Its
`caller` says where the call came from — `.page(WindowID)` for the app's own web
content, `.agent` for a tool call through [`AgentPlugin`](agent-tools.md):

```swift
ctx.registry.register("stories.list", typed: { (_: EmptyArgs, ctx) -> [Story] in
    switch ctx.caller {
    case .page:  store.all()
    case .agent: store.all().filter { !$0.isLocked }
    }
})
```

`ctx.originWindow` is derived from `caller` (the window id for a page, `nil`
otherwise), so a `window.*`-style command that targets the originating window
keeps working unchanged. Prefer switching on `caller` over testing
`originWindow` for nil: the nil-ness is a consequence of the agent path having
no window, not a contract, and a guard built on it would fail *open* if that
ever changed.

### Which frame is calling

`ctx.frame` says *which frame of the page* called — `.main` for the window's own
top-level document, `.subframe(origin:)` for content it embedded, `.unknown`
where the backend can't tell.

**Embedded content can't reach your commands.** `bridge.js` is injected into the
top frame only, so an `<iframe>` — an embedded map, a video, a widget — has no
bridge object to call with. That is the defence, and it holds on every backend
including the two that can't report a calling frame at all. Your own
same-origin content still reaches the bridge through
`window.parent.__SWIFT_PWA__`, which is the pattern to use from a frame.

`ctx.frame` is then the *report* rather than the barrier: it tells a handler who
called, for the backends that inject per-origin instead of per-frame (Android
admits a same-origin frame), and it is what `external_urls.allow_any_scheme`
narrows itself with.

```swift
ctx.registry.register("notes.delete", typed: { (args: DeleteArgs, ctx) -> EmptyResult in
    guard ctx.frame == .main else {
        throw BridgeError(code: "E_FORBIDDEN", message: "not available to embedded content")
    }
    try store.delete(args.id)
    return EmptyResult()
})
```

Take it from `ctx.frame` and never from the page: `bridge.js` runs *inside* the
frame in question, so anything it reports about itself — `window.top === window`,
`location.origin` — is written by whoever wrote that frame's content, and content
you don't trust with a capability can't be trusted to describe itself either.

What each backend can tell you differs, and the differences are measured rather
than assumed:

| Backend | `ctx.frame` |
| --- | --- |
| macOS / iOS | `.main` or `.subframe(origin:)`, from `WKScriptMessage.frameInfo` |
| Windows | Always `.main` — **embedded frames don't reach your commands at all** |
| Android | `.main` or `.subframe(origin:)`, from `WebViewCompat.addWebMessageListener` — `.unknown` on a System WebView too old for it |
| Linux (GTK3 / GTK4) | Always `.unknown` — the WebKitGTK UI process isn't told |

**Windows refuses embedded content outright.** WebView2 raises a frame's
`postMessage` on that frame's own event rather than the window's, so a call
from an `<iframe>` never reaches the bridge there — which makes `.main` always
true, and makes Windows the strictest of the five. It is *reported* rather than
dropped in silence: each refused call logs one line naming the frame's document
and the command it tried. If an iframe of yours needs a command, have the
top-level document call on its behalf (`window.postMessage` up, `invoke` from
there) — which is the only pattern that works everywhere anyway, because a
frame's reply is delivered to the top frame on every backend.

**It separates cross-origin content, not untrusted content.** A **same-origin**
frame can reach its parent's realm and call the parent's bridge object —
`window.parent.__SWIFT_PWA__.invoke(...)` — which posts from the parent's frame,
so the runtime correctly sees `.main` and the check is bypassed in one line.
That is inherent to the same-origin policy rather than a gap here: a same-origin
frame is already the same trust domain and can drive the parent's DOM directly.
The consequence is what matters — **do not use `ctx.frame` to sandbox
same-origin content you don't trust**, such as user-authored HTML rendered into
an iframe on your own origin. Give that content its own origin (a different
host, or a `sandbox` attribute without `allow-same-origin`) and then `ctx.frame`
separates it. Verified against a real `WKWebView` in
`WKBridgeIntegrationTests`.

**`.unknown` is a real answer on some platforms**, not a "not implemented yet":
both GTK backends can't report it (the WebKitGTK UI process isn't told which
frame sent a script message), so a guard like the one above would refuse *every*
call there. Where you need a check that behaves the same on all five, gate on
something you control — a capability handed to the frame, or a command the
embedded content simply isn't told about — rather than on frame identity. See
[docs/linux-setup.md](linux-setup.md#known-limitations-on-linux).

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
vendored stb_image (plus libheif when present) + pure-Swift bilinear resize on Linux, WIC on Windows (no
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

`AuthPlugin` (`auth.*` — opening a provider's consent page and catching the
OAuth redirect) is the one plugin that takes **no platform adapter at all**:

```swift
ctx.use(AuthPlugin(networkClient: URLSessionNetworkClient()))
```

The browser, and on Apple the OS authorization session
(`ASWebAuthenticationSession`), come from the backend through
`AppContext.urlOpener` and `AppContext.authorizationSession` — so this line
compiles unchanged on all five platforms, rather than needing an `#if os(…)`
ladder naming `AppleURLOpener` / `GTKURLOpener` / `WindowsURLOpener` /
`AndroidURLOpener`. A per-platform branch in a shared `main.swift` is a branch
that breaks on the platform its author can't test. The `NetworkClient` stays
explicit because it already is for `net.*`: Android's `URLSession` has no
injectable CA trust store.

`OAuthAuthorizer` is the same object underneath, usable directly so a flow can
run entirely in Swift and a token never becomes visible to the page:

```swift
let auth = OAuthAuthorizer(
    urlOpener: ctx.urlOpener,
    events: ctx.events,
    networkClient: URLSessionNetworkClient(),
    presenter: ctx.authorizationSession
)
let grant = try await auth.authorize(AuthorizationRequest(
    authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
    clientId: clientID,
    scopes: ["https://www.googleapis.com/auth/drive.readonly"]
))
let tokens = try await auth.exchange(TokenExchangeRequest(
    tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
    clientId: clientID,
    code: grant.code,
    codeVerifier: grant.codeVerifier,
    redirectURI: grant.redirectURI
))
```

PKCE (`S256`) and `state` are generated and verified inside the flow and are not
configurable. See [docs/auth.md](auth.md).

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

## Where an app's files go

Three locations, and the third is the one a *person* sees:

```swift
ctx.dataDirectory()       // private, persistent — goes when the app does
ctx.cacheDirectory()      // private, disposable — the OS may evict it
ctx.documentsDirectory()  // the user's, visible in their file manager
ctx.documentsSurviveUninstall   // false on iOS alone
```

`documentsDirectory()` is `~/Documents/<App>` on macOS, `$XDG_DOCUMENTS_DIR/<App>`
on Linux, `Documents\<App>` on Windows, `/sdcard/Documents/<App>` on Android —
where it needs **no permission**, because an app may always create and read its
own files in shared storage — and the app's own `Documents` container on iOS.
Created on first call, which means asking where it is makes it exist.

Put things there when the user should keep them: books they added, documents
they authored, exports. It is a real path on every platform, so it mounts with
`serveDirectory` and streams with ranges, which is what makes it the natural
default library location.

Check `documentsSurviveUninstall` before promising permanence. It is `false` on
iOS, where the visible Documents folder lives inside the app container — an app
that knows can offer an export instead. See
[ios-setup.md](ios-setup.md#icloud-is-the-upgrade-and-it-needs-a-paid-team).

## Serving extra directories (content packs)

`ctx.serveDirectory(_:at:)` mounts a directory on the **bundle origin**
under an app-chosen path prefix, so page JS can reference it with an
origin-relative URL that works unchanged on every backend. On Android the
directory may be a **SAF tree URI** — what `dialog.openDirectory` returns — so
a folder the user picked streams like any other mount; see
[android-setup.md](android-setup.md#walking-a-folder-the-user-picked):

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
- Range is honored on all backends, so a large `<video>` seeks/streams off disk
  instead of buffering. Four of them answer `206 Partial Content`; **Android
  serves from the requested offset to the end of the file, under a `200`**,
  because its WebView rejects a `206` returned from an intercepted response
  before the page ever sees it (measured — the fetch fails outright, with no
  diagnostic anywhere). Seeking works either way, which is what the header is
  for; a client that branches on `206` takes its whole-file path there.
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

- **This table now governs Windows too.** It used not to: the bundle was served
  natively by `SetVirtualHostNameToFolderMapping` and WebView2 decided the type
  from its own extension mapping (measured then — `.avif` arrived as
  `image/avif`, `.heic` as `application/octet-stream`, regardless of what
  `AssetProvider` said). Since that mapping also made `serveDirectory` mounts
  unreachable, Windows serves its whole bundle origin through the router like
  every other backend, and one table answers for all five.

**Android** builds its asset loader before any Swift runs, so a mount that must
exist *before the first page load* is declared in `pwa.json` as well — the
bundler wires it into the generated Activity:

```json
"build": { "serve": [ { "mount": "/packs", "from": "data/packs" } ] }
```

`from` is rooted at the per-app data dir by default (a `cache/…` prefix roots it
at the cache dir), and it is the only form that can serve a request the page
makes before `configure()` has run.

Everything else `ctx.serveDirectory` does works on Android: a prefix mounted at
runtime, from **any** root the app can read — not only inside app storage, which
is all a `build.serve` mount can reach — and `unserveDirectory` takes it away
again. The WebView asks the same `AssetProvider` the other four backends resolve
against, so one mount table governs all five. Reading a folder the user picked
by path additionally needs All-files access, which the runtime can both read and
ask for:

```swift
ctx.permissions.declare(.allFiles)                       // plus "permissions": { "device": ["allFiles"] }
if await ctx.permissions.status(.allFiles) == .denied {
    _ = await ctx.permissions.request(.allFiles)         // a Settings screen on Android; resolves on the way back
}
```

`granted` is usable now, `denied` is worth offering a button for, and
`unavailable` never becomes granted on this build — iOS, an undeclared or
vetoed permission, or a store that refused the declaration — so the app needs
its other route rather than a prompt. See
[permissions.md](permissions.md#asking-for-the-capability-no-web-api-asks-for)
and [android-setup.md](android-setup.md#all-files-access).
See [docs/design/runtime-content-packs.md](design/runtime-content-packs.md).

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

**`.didFocus` / `.didBlur` mean "this window became, or stopped being, the one
the user is working in" on all five backends** — including the two where that
isn't a window manager's idea of focus at all. On **Android** they come from
`Activity.onResume` / `onPause`, and on **iOS** from the scene becoming active /
resigning active, which is where a mobile app re-reads state it couldn't watch
while suspended and re-engages a lock. So the same Swift is correct everywhere:

```swift
Task {
    for await event in main.eventStream() {
        switch event {
        case .didFocus: await library.rescan()
        case .didBlur: lock.engage()
        default: break
        }
    }
}
```

Verified on real hardware on all five, one script per platform family
(`Scripts/verify-window-focus.sh`, `verify-windows-window-focus.ps1`,
`verify-ios-window-focus.sh`, `verify-android-served-mounts.sh`).

Two notes. `.didFocus` is also emitted by an explicit `focus()` call, and the
backends de-duplicate that against the real signal that follows, so presenting a
window doesn't report focus twice. And minimize / fullscreen are still
programmatic-only on the GTK backends — a user-driven alt-tab now reports focus,
but iconifying from the window manager doesn't report `.didMinimize`. See
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

Three non-obvious points worth pinning:

1. **`CommandRegistry` is a class with `NSLock`-guarded state, not an
   actor.** Registration is *synchronous* on purpose so user
   `configure` closures can run on a thread that isn't pumping Swift's
   MainActor executor — typically the main thread before `gtk_main()`
   enters its loop on Linux.
2. **`BridgeRuntime` is *not* `@MainActor`.** Backends are responsible
   for hopping to the platform UI thread internally via
   `MainThread.run`, which routes through a per-backend dispatch hook
   installed at startup (`DispatchQueue.main` on Apple, `g_idle_add`
   on GTK, a hidden `HWND_MESSAGE` window on Windows, a `Handler` post
   on Android).
3. **Your own `@MainActor` code works on every platform.** Off Apple,
   `MainActor` is backed by libdispatch's main queue, and `gtk_main()`,
   `GetMessageW` and Android's `Looper` each own the main thread and
   drain nothing — so through v0.10.7 a command handler that touched a
   `@MainActor` class never returned, with no error and nothing on
   stderr (#216). Every backend now waits on libdispatch's main-queue
   handle alongside its own events and drains it when it signals
   (`PlatformMainQueue`), which also fixes `DispatchQueue.main.async`.

Prefer `MainThread.run` for work that touches a *window*: it is one hop
rather than two, and it still delivers in the contexts where nothing is
draining the main queue — a headless `agent.expose` catalog dump, a unit
test. These are the same tripwires `Examples/HelloPWA` is built against.
