# Proposal: generalized remote AI backends (cloud + local-network generators)

> **Status: proposed.** A framework tier that makes a *remote* image generator —
> a cloud API or a local-network appliance — a drop-in `AIBackend`, so it slots
> into the existing model switcher (`MultiModelImageBackend`) next to on-device
> ONNX models with **zero framework changes to add a new API**. Ships with two
> concrete providers — **Google Imagen (v3/v4)** and **local-network ComfyUI** —
> and a small `RemoteImageProvider` protocol; a third API is a conformance, not a
> fork.
>
> Motivated by the same adopter framing that drove the model switcher
> (`docs/proposals/image-gen-adopter-refinements.md`): the real goal is a dropdown
> where the end user chooses among **local and remote** backends *based on need* —
> offline/fast/free on-device vs quality/paid/online in the cloud. The switcher
> contract already treats a routed entry as "just another `AIBackend`, local or
> remote"; this proposal supplies the *remote* half so that promise is real out of
> the box instead of something every adopter hand-rolls.
>
> **Decisions (from review):** (1) **v1 is image-only** — Imagen + ComfyUI; remote
> text/audio are a fast follow on the same transport. (2) Android cleartext for LAN
> endpoints ships as a **scoped `network_security_config`** allow-list, not a blunt
> global flag (least broad; avoids app-store scrutiny). (3) The cross-platform HTTP
> transport is promoted to a **first-class `net.*` plugin** (not Android-only, not a
> single call type): a JS-facing `net.request` / `net.download` surface plus a shared
> `NetworkClient` seam that the remote AI backends consume internally. Networking is
> the foundation; remote AI is its first consumer.

## Goals & non-goals

**Goals**
- A first-class, cross-platform **`net.*` plugin** + shared **`NetworkClient`** seam
  — the networking foundation everything else builds on. JS gets a CORS-free native
  `net.request` / `net.download`; Swift backends get one injectable HTTP client with
  one Android transport, instead of each rolling its own. (Not Android-only, not a
  single call type — the point of the plugin framing.)
- One reusable remote-image backend (`RemoteImageBackend`) that maps a remote API
  onto the `ai.generateImage` / `ai.generateImageStream` surface, owning error
  mapping, seed handling, and `AICapabilities` / `AIModelInfo` plumbing **once**, and
  consuming the shared `NetworkClient` for transport.
- A small `RemoteImageProvider` seam an adopter implements per API. Two shipped
  conformances: `ImagenProvider`, `ComfyUIProvider`. **A new API = implement the
  protocol; no changes to Core or the switcher.** That is the win condition.
- Works on all five platforms, adapted to each (the hard part is Android — see
  [the networking foundation](#the-networking-foundation-the-net-plugin--networkclient)).
- **No credential/model persistence in the framework.** Keys and user-entered
  endpoints are the adopter's concern — injected via a closure, never stored by
  swift-pwa. (Explicit non-goal per the request: "leave *storage* of user-entered
  models alone and let the devs personalize that.")

**Non-goals (v1)**
- Remote *text* and *audio* backends. The `NetworkClient` and provider pattern
  generalize to them trivially (`RemoteTextProvider` / `RemoteAudioProvider` on the
  same transport), and OpenAI/Anthropic/Gemini-chat are obvious next drop-ins — but
  v1 is scoped to image, matching the two requested APIs and the image-routed
  `MultiModelImageBackend`. See [Phasing → Follow-ups](#phasing).
- A key/endpoint settings UI. Adopters build their own (the request is explicit).
- ComfyUI per-node `/ws` progress. v1 polls `/history`; live websocket progress
  is a follow-up (needs a cross-platform WS client — see [Phasing → Follow-ups](#phasing)).

## Where it plugs in

The switcher already exists and already documents remote as in-scope
(`MultiModelImageBackend`, `Sources/SwiftPWACore/Plugin/MultiModelImageBackend.swift`):
a routed `Entry` is *any* `AIBackend`, and `request.model` names a whole backend
(local or remote), not merely a weights file. A remote backend needs no new
routing — it's one more entry:

```swift
let lcm    = StableDiffusionBackend(/* on-device LCM */)          // local
let imagen = RemoteImageBackend(                                   // cloud
    provider: ImagenProvider(apiKey: { await keychain.googleAIKey() }))
let comfy  = RemoteImageBackend(                                   // LAN appliance
    provider: ComfyUIProvider(baseURL: userEnteredComfyURL,
                              workflow: .txt2imgSDXL))

let switcher = MultiModelImageBackend([
    .init(lcm.modelInfo,    lcm),
    .init(imagen.modelInfo, imagen),
    .init(comfy.modelInfo,  comfy),
], default: "lcm-dreamshaper")

ctx.use(AIPlugin(switcher))
```

`ai.info().models` then advertises all three (each with `capabilities`,
`availability`, `offlineCapable`, `license` from the existing `AIModelInfo`), the
JS dropdown filters to `image-generation`, and `request.model` routes. The
on-device `unload()`-on-switch logic is unaffected — a remote backend inherits the
no-op `unload()`, so it costs nothing in that machinery.

## Architecture — a networking foundation, then the AI tier on top

```
   JS: net.request / net.download          JS: ai.generateImage / …Stream
              │                                          │
   ┌──────────┴───────────┐              ┌───────────────┴───────────────┐
   │  NetPlugin  (Core)    │              │  RemoteImageBackend (ships once)│  AIBackend
   │  net.* command set    │              │  info/error-map/seed/plumb      │  conformance
   └──────────┬───────────┘              └───────────────┬───────────────┘
              │                                          │ owns
              │                          ┌───────────────┴───────────────┐
              │                          │  RemoteImageProvider (per API) │  Imagen · ComfyUI ·
              │                          │  the API choreography          │  <your API next>
              │                          └───────────────┬───────────────┘
              │  both consume the same injected transport │
   ┌──────────┴──────────────────────────────────────────┴──────────────┐
   │  NetworkClient  (protocol, Core)                                     │
   │  URLSessionNetworkClient (Apple/Linux/Windows) · AndroidNetworkClient│
   └──────────────────────────────────────────────────────────────────────┘
```

**Networking is a first-class capability, and remote AI is its first consumer.**
The same `NetworkClient` that answers the JS `net.*` plugin is what the image
providers use for transport — one abstraction, one Android RPC, two consumers.

Targets:
- **`net.*` plugin + `NetworkClient`** live in **`SwiftPWACore`** (Foundation-only;
  `NetPlugin` sits beside `ProcessPlugin` / `AppPlugin`). `URLSessionNetworkClient`
  ships in Core for Apple/Linux/Windows; `AndroidNetworkClient` ships in
  `SwiftPWAAndroid` (it needs the RPC bridge) and is injected by the runtime/adopter
  on Android — the same "platform-default supplied by the backend, not by Core"
  pattern `MainThread`'s dispatch hook uses.
- **`SwiftPWARemoteAI`** (new) — `dependencies: ["SwiftPWACore"]`. Holds
  `RemoteImageBackend` + `RemoteImageProvider` + `ImagenProvider` + `ComfyUIProvider`.
  No package-level platform restriction; gating is in-source, following the
  `SwiftPWAFoundationModels` precedent. The umbrella does **not** depend on it —
  adopters opt in, like the ONNX backends.

### The `net.*` plugin & `NetworkClient`

The one genuinely cross-platform-hard piece — solved once, exposed both to JS and
to Swift backends. `NetworkClient` is the injectable seam (parallel to
`ProcessRunner` / `Dialog`); `NetPlugin(NetworkClient)` registers the JS surface.

```swift
public protocol NetworkClient: Sendable {
    /// Unary request/response (fetch-like).
    func send(_ request: NetRequest) async throws -> NetResponse
    /// Streaming download to a path, with progress + optional checksum
    /// (generalizes today's internal net.downloadFile, now header-capable).
    func download(_ request: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error>
}

public struct NetRequest: Sendable {
    public var method: String            // "GET" | "POST" | …
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
}
public struct NetResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
}
```

**JS surface** (`net.*`, opt-in like `process.*` — arbitrary host requests from the
native side are powerful, and CORS-free, so they're not on by default):
- `net.request({ method, url, headers?, bodyBase64?, timeoutMs? })` →
  `{ status, headers, bodyBase64 }`. A native, CORS-free `fetch` — genuinely useful
  beyond AI (LAN appliances, auth headers a WebView can't set, third-party APIs
  that don't send CORS).
- `net.download({ url, destPath, headers?, sha256? })` → streamed `progress`
  events + terminal `{ path, bytesWritten }`. The JS-facing generalization of the
  internal `net.downloadFile` (now with arbitrary headers; `ai.ensureModel` keeps
  using the same underlying capability).

**Platform implementations:**
- **`URLSessionNetworkClient`** — Apple / Linux / Windows. Foundation `URLSession`,
  bridged through a `dataTask` completion → `CheckedContinuation` (works on
  swift-corelibs too, where the async `data(for:)`/`bytes(for:)` overloads are
  unreliable — the same reason `ModelDownloader` uses a delegate on Linux/Windows,
  `Sources/SwiftPWAModelStore/ModelDownloader.swift`). System CA store on all three,
  so HTTPS to Imagen and plain HTTP to a LAN ComfyUI both work directly.
- **`AndroidNetworkClient`** — routes through the Kotlin RPC bridge (below).
  Required because swift-corelibs `URLSession` on Android (libcurl + BoringSSL) has
  **no injectable CA trust store** — every HTTPS call fails with "unable to get
  local issuer certificate" (documented at `docs/android-setup.md`; it's why every
  model download already routes through the Kotlin `net.downloadFile` RPC). The
  Kotlin side uses the system TLS stack.

> **Do not imitate `AndroidUpdater`.** It calls `URLSession` directly on Android for
> its manifest/APK fetch — per the CA-store limitation that path can't work against
> real HTTPS and looks like a latent gap. The correct model is the RPC bridge.

### Android piece 1 — a general `net.request` RPC (backs both `net.*` and remote AI)

`net.downloadFile` is GET-to-file only (no method, headers, or body; it writes the
response straight to disk and returns a byte count). Both the JS `net.request` verb
and a remote AI POST need a general request. `AndroidRPC.call` is already a fully
generic Swift→Kotlin JSON transport, so this is the well-precedented "one Kotlin
`when`-case + one Swift wrapper" addition (`CHANGELOG.md` describes plugin methods
exactly this way):

- **Kotlin** (`Sources/SwiftPWACLISupport/Bundlers/AndroidTemplates.swift`), new
  case in `dispatch`: `"net.request"` → args `{ method, url, headers: {..},
  bodyBase64? }` → result `{ status, headers: {..}, bodyBase64 }`, implemented with
  `HttpURLConnection` (`doOutput = true` when there's a body, `setRequestProperty`
  per header, read the response stream into base64). Mirrors `netDownloadFile` minus
  the file plumbing. (The existing `net.downloadFile` case also gains an optional
  `headers` arg so `net.download` can carry them.)
- **Swift** (`Sources/SwiftPWAAndroid/`): `AndroidNetworkClient.send` wraps
  `AndroidRPC.call("net.request", …)`, base64-encoding the request body and decoding
  the response; `AndroidNetworkClient.download` reuses `AndroidFileDownload`.

### Android piece 2 — cleartext for LAN endpoints (the ComfyUI blocker)

The generated `AndroidManifest.xml` hardcodes `android:usesCleartextTraffic="false"`
with no `pwa.json`/CLI knob
(`Sources/SwiftPWACLISupport/Bundlers/AndroidTemplates.swift`). This is enforced by
the OS's Network Security Config **independent of the HTTP client**, so a plain
`http://192.168.x.x:8188` ComfyUI call is blocked at the OS level regardless of
transport — the single biggest Android blocker for the local-network case, and
undocumented today.

Fix (bundler / CLI, additive) — **decided: scoped, not a global flag.** A
`pwa.json` opt-in that emits a `res/xml/network_security_config.xml` and references
it from the manifest, permitting cleartext **only** to the named endpoints — the
correct, least-broad Android idiom for exactly this "local appliance / LAN dev
server" case, and the shape least likely to draw app-store scrutiny (a blanket
`usesCleartextTraffic="true"` is a known review flag):

```json
"android": {
  "network": {
    "cleartext_domains": ["*.local", "192.168.0.0/16", "10.0.0.0/8"]
  }
}
```

→ a `network-security-config` whose `base-config` keeps cleartext **off**, with a
`<domain-config cleartextTrafficPermitted="true">` scoped to each entry (individual
hostnames as `<domain>`; IP ranges documented as best-effort — Android's config
takes hostnames/`includeSubdomains`, so a subnet is expressed as the adopter's
concrete host(s) or a `*.local`-style suffix where mDNS is used). Absent the key,
behavior is unchanged (cleartext stays off globally — no regression). No global
`usesCleartextTraffic="true"` escape hatch ships; if an adopter truly needs
all-hosts cleartext they can still supply a full config via a raw passthrough
(future), but that is deliberately not the easy path.

> **Other platforms need no bundler work for LAN http.** Desktop (macOS/Linux/
> Windows) has no cleartext restriction. iOS's ATS is solvable *today* by the
> adopter via the shipped `ios.info_plist` passthrough (add an
> `NSAppTransportSecurity` exception) — no framework change. Android is the only
> platform lacking such an escape hatch, hence this knob.

### The provider seam: `RemoteImageProvider`

The provider owns the *choreography*, given an injected `NetworkClient`. This shape
(rather than "build one request / parse one response") is deliberate: it covers
both **one-shot** APIs (Imagen: a single POST) and **async-job** APIs (ComfyUI:
submit → poll → fetch N images) with the same protocol — the two dominant shapes
of image APIs in the wild.

```swift
public protocol RemoteImageProvider: Sendable {
    /// Catalog entries this provider serves (fed into ai.info().models).
    /// Static metadata — capabilities/license/offlineCapable; availability may
    /// be refined live by `availability()`.
    var models: [AIModelInfo] { get }

    /// The producing backend id for provenance (AIGeneratedImage / result.backend).
    var backendID: String { get }

    /// Run the full generate for `request`, returning the images. Owns the API
    /// choreography and its own request building / response parsing.
    func generateImage(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) async throws -> [AIGeneratedImage]

    /// Live availability probe (reachable? key present?). Default `.ready`.
    func availability(client: any NetworkClient) async -> AIModelAvailability

    /// Optional streaming with progress. Default: run `generateImage`, emit one
    /// terminal `done` (same as AIBackend's default image-stream wrapper).
    func generateImageStream(
        _ request: AIGenerateImageRequest,
        client: any NetworkClient
    ) -> AsyncThrowingStream<AIImageEvent, any Error>
}
```

`RemoteImageBackend` supplies the `AIBackend` conformance around it: `info()` folds
`provider.models` + `availability()` into `AICapabilities(imageGeneration: true,
models:, backend: provider.backendID)`; `generateImage`/`…Stream` delegate;
`unload()` is a no-op (nothing resident); text/audio inherit `.unsupportedPlatform`.
It also centralizes two cross-cutting concerns so providers don't repeat them:

- **Seed handling** — random base seed when `request.seed` is nil, per-image
  increment, echoed in `AIGeneratedImage.seed` (the exact fix applied to
  `StableDiffusionBackend` in the seed-randomization change; providers that can't
  honor a seed report it in `models`).
- **Output plumbing** — `outputDirectory` present ⇒ write files + return `path`s;
  absent ⇒ return inline `dataBase64` (mirrors the on-device backends and `fs`'s
  path-first stance for large binaries). Providers return raw bytes; the backend
  decides inline-vs-file.

## Shipped provider 1 — `ImagenProvider` (Google Imagen v3/v4)

Gemini-API REST surface (simplest auth: an API key, no OAuth):

- **Endpoint** `POST {base}/models/{modelId}:predict`,
  base `https://generativelanguage.googleapis.com/v1beta`.
- **Auth** header `x-goog-api-key: <key>` — key from the injected
  `apiKey: @Sendable () async -> String?` closure. Nil ⇒ availability
  `.needsSetup("Add a Google AI API key")`; the framework never stores it.
- **Body** `{ "instances": [{ "prompt": <prompt> }], "parameters": { "sampleCount":
  <count 1…4>, "aspectRatio": <from width:height>, "imageSize": "1K"|"2K" } }`.
  `count` → `sampleCount` (clamped 1–4); `width`/`height` → nearest supported
  `aspectRatio` (`1:1`/`3:4`/`4:3`/`9:16`/`16:9`); `imageSize` from the larger
  dimension where the model supports 2K. (Imagen 4 dropped `negativePrompt`;
  honored on v3, ignored with a note on v4.)
- **Response** `{ "predictions": [{ "bytesBase64Encoded": <b64>, "mimeType":
  "image/png" }] }` → `AIGeneratedImage`.
- **Models** (`models` catalog, all `capabilities: [.imageGeneration]`,
  `offlineCapable: false`, `license: "Google Gemini API Terms"`):
  `imagen-4.0-generate-001`, `imagen-4.0-ultra-generate-*`,
  `imagen-3.0-generate-002` (ids overridable at init).
- **Errors** non-200 → decode `{error:{message}}` → `AIError.generationFailed`.

Sources: [Imagen · Gemini API](https://ai.google.dev/gemini-api/docs/imagen),
[Vertex `predict` reference](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/model-reference/imagen-api).

## Shipped provider 2 — `ComfyUIProvider` (local-network ComfyUI)

ComfyUI is graph-based and "bring-your-own workflow." The provider takes a
workflow **template** the adopter supplies (any API-format graph) plus a set of
**patches** mapping request fields onto node inputs — so it's fully general across
any workflow, with a turnkey default (`.txt2imgSDXL`) for the common case.

```swift
public struct ComfyWorkflowTemplate: Sendable {
    public var graphJSON: Data                 // an API-format ComfyUI workflow
    public var patches: [Patch]                // where to inject request fields
    public struct Patch: Sendable {
        public var nodeID: String              // e.g. "6"
        public var input: String               // e.g. "text" | "seed" | "steps"
        public var from: Field                  // .prompt/.negativePrompt/.seed/.steps/.width/.height/.count
    }
    public static let txt2imgSDXL: ComfyWorkflowTemplate  // sensible default
}
```

- **init** `baseURL: URL` (e.g. `http://nas.local:8188` — adopter-provided /
  user-entered), `workflow: ComfyWorkflowTemplate`, `models: [AIModelInfo]`
  (adopter-labelled; `offlineCapable: false` — it's a network call, LAN or not),
  optional `clientID`.
- **Choreography** (`generateImage`):
  1. Decode `graphJSON`; apply patches from the request (prompt, negativePrompt,
     seed [random-if-nil, echoed back], steps, width, height, batch = count).
  2. `POST /prompt` `{ "prompt": <graph>, "client_id": <id> }` → `{ prompt_id }`.
  3. Poll `GET /history/{prompt_id}` until populated (bounded delay loop +
     timeout); parse the output node(s) for `{ filename, subfolder, type }`.
  4. `GET /view?filename=&subfolder=&type=` per image → bytes → `AIGeneratedImage`.
- **availability** — `GET /system_stats` reachable ⇒ `.ready`, else
  `.needsSetup("ComfyUI not reachable at \(baseURL)")`.
- **Progress (v1)** — polling emits coarse `progress` events; true per-node
  progress via `/ws` is a follow-up.

Sources: [ComfyUI server routes](https://docs.comfy.org/development/comfyui-server/comms_routes),
[websockets API example](https://github.com/comfyanonymous/ComfyUI/blob/master/script_examples/websockets_api_example.py).

## Testing & verification

- **Unit (no live services), the bar for "work ready":** a `MockNetworkClient`
  returning canned responses drives both providers end-to-end —
  - Imagen: assert request URL/headers/body shape (sampleCount, aspectRatio
    mapping, key header) and that `predictions[].bytesBase64Encoded` decode into
    `AIGeneratedImage`s with echoed seeds.
  - ComfyUI: assert the graph is patched correctly, the `/prompt` → `/history` →
    `/view` sequence fires in order, and multi-image batches parse. Feed a
    malformed/empty history to assert the timeout/error path.
  - `RemoteImageBackend`: seed randomization, output-dir-vs-inline, `info()`
    aggregation, error mapping to `E_AI_*`.
  Target parity with `MultiModelImageBackendTests` (~20 tests).
- **Live ComfyUI:** point `ComfyUIProvider` at `comfyui.local:8188` /
  `comfyui-2.local:8188` (confirmed live on the LAN) from the dev Mac — real
  txt2img, confirm an image returns. If those are only reachable behind their
  orchestration layer, stand up a throwaway ComfyUI or verify against a recorded
  fixture. (The connected comfy MCP is a **custom** orchestration wrapper, *not*
  the raw ComfyUI API — the provider targets raw `/prompt`·`/history`·`/view`, so
  the MCP is only a liveness signal, not a contract to mirror.)
- **Live Imagen:** requires an API key (adopter/user-supplied). Verify the request
  shape against a real key when available; otherwise a recorded-response fixture.
- **Android:** device-verify the new `net.request` RPC (an HTTPS POST round-trip)
  and the cleartext config (a `http://` LAN GET succeeding once the
  network-security-config is emitted), on the Tab S10+ per the usual CDP recipe.

## Example (`CritterFacts`)

Add a remote arm to the existing prompt→image switcher: an `ImagenProvider` entry
(shown as `needsSetup` until a key is entered — demonstrating the availability
badge) and a `ComfyUIProvider` entry pointing at a configurable host. This makes
the "local + remote, one dropdown" story concrete and exercises the whole path.

## Phasing

Two sub-phases; the networking foundation lands first because the AI tier consumes
it. They can ship together (one release) or as 1a → 1b.

- **Phase 1a — networking foundation (Core + Android):** `NetworkClient` protocol +
  `NetRequest`/`NetResponse`/`NetDownload*` + `URLSessionNetworkClient`; the `net.*`
  plugin (`NetPlugin` → `net.request` / `net.download`, opt-in); the Android
  `net.request` RPC + `AndroidNetworkClient` + a `net.downloadFile` header arg; the
  scoped `android.network.cleartext_domains` bundler support. Unit tests (mock +
  URLSession round-trips) + Android device verify. Docs: `docs/net-plugin.md` +
  README/CHANGELOG + a `docs/android-setup.md` cleartext note.
- **Phase 1b — remote image tier (this proposal's headline):** `SwiftPWARemoteAI`
  target — `RemoteImageProvider` + `RemoteImageBackend` (consuming `NetworkClient`);
  `ImagenProvider` + `ComfyUIProvider`; `MockNetworkClient`-driven unit tests + the
  CritterFacts switcher arm; `docs/remote-ai.md` + README/CHANGELOG.
- **Follow-ups:**
  - ComfyUI `/ws` live progress — `URLSessionWebSocketTask` on Apple/Linux/Windows;
    on Android a Kotlin-side WS client forwarding `{channel,…}` frames through the
    existing `AndroidHostEventRouter` (the pattern `GeminiNanoBackend` streaming
    already uses). No Swift WS client exists in the repo yet, hence deferred.
  - Remote **text** (`RemoteTextProvider`: OpenAI/Anthropic/Gemini chat) and
    **audio** on the same `NetworkClient` — the natural extension; needs `model` on
    the text/audio requests so `MultiModelImageBackend` (or a sibling) can route
    them (already flagged as a follow-up in the model-selection proposal).
  - A generic OAuth-bearer variant for Vertex AI / providers that need it (v1 is
    API-key only).
  - Promote the scoped cleartext support with a raw `network_security_config`
    passthrough for adopters with unusual needs (kept off the easy path on purpose).

## Open questions

- **`NetPlugin` default-on or opt-in?** Proposed opt-in (like `process.*`) — a
  native, CORS-free request to any host is powerful. Confirm that's the right
  default, or whether a same-origin/allow-list-only mode is worth a v1 knob.
- **`net.*` verb surface for v1.** `net.request` + `net.download` cover the AI needs
  and the common cases; `net.stream` (SSE/chunked) is deferred with the WS work.
  Flag if a first-class streaming verb is wanted sooner.
