# Remote AI image generators (cloud + local-network)

`SwiftPWARemoteAI` makes a **remote** image generator — a cloud API or a
local-network appliance — a drop-in `AIBackend`, so it sits in the same
`ai.generateImage` surface (and the same `MultiModelImageBackend` switcher) as
your on-device models. It ships two providers — **Google Imagen** and
**local-network ComfyUI** — and a small `RemoteImageProvider` protocol, so a
third API is *just another conformance*: no changes to the framework.

Built on the [`net.*` plugin](net-plugin.md)'s `NetworkClient`, so it works on
all five platforms and shares one HTTP transport (and, on Android, one RPC
bridge) with the JS `net.*` surface.

> Add the product dependency `SwiftPWARemoteAI` to your app's `Package.swift`
> (the umbrella doesn't pull it in, same as the ONNX backends).

## The shape

```
RemoteImageBackend  (AIBackend — ships once: info / output plumbing / errors)
        └── owns a RemoteImageProvider   (per-API choreography)
                    └── uses an injected NetworkClient   (transport)
```

`RemoteImageBackend` supplies the whole `AIBackend` conformance; a provider
writes *only* the image logic. You inject the platform `NetworkClient` (the same
one you give `NetPlugin`): `URLSessionNetworkClient()` on desktop/Apple,
`AndroidNetworkClient()` on Android.

## Google Imagen

```swift
import SwiftPWARemoteAI

let store = KeychainSecretStore()            // the secrets.* plugin's store
let imagen = RemoteImageBackend(
    provider: ImagenProvider(apiKey: { try? await store.get("google-ai") }),
    client: URLSessionNetworkClient()
)
```

- Gemini-API REST (`POST {base}/models/{model}:predict`, `x-goog-api-key`).
- **The key is injected via a closure and never stored by swift-pwa** — you own
  storage, rotation, and the settings UI. A `nil` key fails at generate time
  with `E_AI_GENERATION`. See [Secure key storage](#secure-key-storage) for the
  keychain-backed `secrets.*` path (and the `needsSetup → enter → ready` flow).
- Default catalog: `imagen-4.0-generate-001` (Imagen 4) and
  `imagen-3.0-generate-002` (Imagen 3); pass your own `models:` to change it.
  `request.model` routes among them.
- `width`/`height` map to the nearest supported `aspectRatio`
  (`1:1`/`3:4`/`4:3`/`9:16`/`16:9`); `count` → `sampleCount` (1–4).
- **Seed / watermark:** Imagen's `seed` is mutually exclusive with its default
  SynthID watermark, so an *explicit* `seed` sends `addWatermark: false` and
  forces a single image; with no seed, output is non-deterministic and
  watermarked (its echoed `seed` is `nil`).

## Local-network ComfyUI

ComfyUI is graph-based and bring-your-own-workflow, so `ComfyUIProvider` takes a
**workflow template** (an API-format graph) plus **patches** mapping request
fields onto node inputs — general across any workflow, with a turnkey SDXL
default:

```swift
let comfy = RemoteImageBackend(
    provider: ComfyUIProvider(
        baseURL: URL(string: "http://nas.local:8188")!,
        workflow: .txt2imgSDXL(checkpoint: "sd_xl_base_1.0.safetensors")
    ),
    client: URLSessionNetworkClient()
)
```

- Choreography: `POST /prompt` (the patched graph + a `client_id`) → poll
  `GET /history/{prompt_id}` until the outputs appear → `GET /view` per image.
  (v1 polls for completion; live per-step `/ws` progress is a follow-up.)
- **A ComfyUI is a *source of many models*, not one.** Rather than hard-code a
  checkpoint, discover the instance's catalog and list each as its own picker
  entry: `RemoteImageBackend.discoverModels()` (→ `discoverModels(client:)` on the
  provider) returns one `AIModelInfo` per installed checkpoint with id
  `comfy:<checkpoint>`. Pass such an id as `request.model` and the provider runs
  that exact checkpoint. `Examples/CritterFacts` does this in its
  `CompositeAIBackend` — discovered lazily at `info()` time (bounded + cached) so
  local and remote models share one dropdown. (For a turnkey single entry,
  `autoSelectCheckpoint: true` just runs the first installed checkpoint.)
  Otherwise, the checkpoint baked into the workflow must match the instance.
- For any non-default workflow,
  build your own `ComfyWorkflowTemplate(graphJSON:patches:)` from a "Save (API
  Format)" export and map the fields you want driven:

  ```swift
  let tpl = ComfyWorkflowTemplate(
      graphJSON: Data(myExportedGraphJSON.utf8),
      patches: [
          .init(nodeID: "6", input: "text", field: .prompt),
          .init(nodeID: "3", input: "seed", field: .seed),
          // … steps / width / height / count / negativePrompt / guidanceScale
      ])
  ```
  A field that's `nil` on the request is skipped, leaving the graph's own default.
- **Android:** a plain-`http://` LAN endpoint needs the host allow-listed via
  [`android.network.cleartext_domains`](net-plugin.md#androidnetworkcleartext_domains).
  HTTPS endpoints (and all desktop/iOS) need nothing extra (iOS uses the
  `ios.info_plist` ATS passthrough for http).

## Running your own imported ComfyUI workflows

The template above patches a *known* graph. ComfyUI's real power is that any
workflow a user authored — Qwen-Image, Flux, edit, upscale, IP-Adapter — can be
exported as an **API-format graph** ("Save (API Format)" in the ComfyUI UI, or
the graph you get from `/prompt` history) and run **verbatim**. So the app owns
importing / storing / selecting workflows; the framework just executes them.
`ComfyUIProvider` has two entry points for this, plus a turnkey `ai.*` adapter.

**1. Discover a workflow's overridable inputs — `inspectWorkflow`.** Real
exports don't title their nodes `prompt` / `seed` — a positive prompt node is
titled `"CLIP Text Encode (Positive Prompt)"`, a `LoadImage` is `"Load Image"`.
So the reliable path is to *introspect* the graph and bind by node id, not by a
title convention. `inspectWorkflow` crosses the graph's literal (widget) inputs —
`[nodeId, slot]` connection inputs are excluded — with the instance's
`/object_info` to return each overridable input's real type, range, combo
options (sampler names, per-box model file lists), and image flag:

```swift
let comfy = ComfyUIProvider(baseURL: URL(string: "http://nas.local:8188")!)
let inputs = try await comfy.inspectWorkflow(graph: importedGraphJSON, client: net)
// each WorkflowInput: { nodeID, nodeClass, title, inputName, type,
//                       currentValue, min?, max?, step?, options?, isImage }
// … carries its own (nodeID, inputName), i.e. a ready-made binding location.
```

Build UI controls from these (a slider for an `INT`/`FLOAT` with its range, a
picker for a `COMBO`, a file picker where `isImage`). `titledOnly: true` narrows
to nodes the author deliberately titled. These are *candidates* — a graph has
literals a UI shouldn't surface (internal constants), so the app curates.

**2. Run it with named inputs — `runWorkflow`.** Bind values into the graph and
get the output image(s) back, reusing the same submit → poll → fetch flow:

```swift
let images = try await comfy.runWorkflow(
    graph: importedGraphJSON,
    inputs: [
        "prompt": .text("a red panda astronaut"),
        "image":  .image(sourceBytes),   // uploaded to /upload/image, filename bound
        "seed":   .seed(nil),            // fresh random per run (echoed on results)
        "steps":  .int(8),
    ],
    bindings: [
        "prompt": .at(node: "108", input: "text"),
        "image":  .imageAt(node: "78", input: "image"),
        "seed":   .at(node: "106", input: "seed"),
        "steps":  .at(node: "106", input: "steps"),
    ],
    client: net)
```

- Inputs are **arbitrary** — not a fixed prompt/image/seed set. Any named input
  works (`cfg`, `denoise`, `width`, a model filename for a picker node); value
  types are `.text` / `.int` / `.float` / `.bool` / `.seed(Int?)` / `.image` /
  `.mask` / `.raw(JSONValue)`.
- A binding is a **list** of locations, so one logical input **fans out** to
  every node that uses it: `["size": .at([("5","width"), ("12","width")])]`.
- Omit a binding for an input and the **title convention** applies (a node whose
  `_meta.title` equals the input name → its like-named input, else its sole
  literal). Handy for workflows *you* authored and titled; introspection +
  explicit bindings is the path for arbitrary imported graphs.
- `.image` / `.mask` bytes are `POST`ed to `/upload/image` and the returned
  filename bound into the target `LoadImage` — this is what makes img2img / edit
  / upscale work.
- The workflow references exact node classes **and model filenames that must
  exist on that box** (inherent to ComfyUI portability). A bad graph surfaces
  ComfyUI's `/prompt` validation message as `E_AI_GENERATION`.

**3. Expose it as an `ai.*` model — `ComfyWorkflowProvider`.** For a workflow
whose inputs line up with the standard request fields, wrap it so it plugs into
the `MultiModelImageBackend` switcher and `ai.generateImage` routes to it — no
ComfyUI-specific JS:

```swift
let workflowModel = RemoteImageBackend(
    provider: ComfyWorkflowProvider(
        baseURL: URL(string: "http://nas.local:8188")!,
        graph: importedGraphJSON,
        fields: .init(prompt: .at(node: "108", input: "text"),
                      seed:   .at(node: "106", input: "seed"),
                      image:  .imageAt(node: "78", input: "image")),   // omit for txt2img
        model: AIModelInfo(id: "comfy:workflow:qwen-edit", label: "Qwen-Image-Edit (ComfyUI)",
                           capabilities: [.imageEdit], availability: .ready, offlineCapable: false)),
    client: net)
```

`ai.generateImage({ model: "comfy:workflow:qwen-edit", prompt, image })` then
maps `prompt`/`image`/`seed`/… onto the bound nodes and runs `runWorkflow`. For
inputs a request can't model (two images, a control image, exotic params), call
`runWorkflow` directly and surface it to your web app however you like.

See [`docs/sample-workflows/`](sample-workflows/) for sanitized example exports.

## Running an imported workflow from JS (runtime)

Everything above is a *Swift* API wired at build time — one graph per
`ComfyWorkflowProvider`, one endpoint per `ComfyUIProvider(baseURL:)`. To let the
**running web app** import a graph, point at a box, and run it — no rebuild —
install `AIWorkflowPlugin`, which exposes `ai.run` / `ai.describeInputs` on the
`ai.*` namespace. Both the **graph and the connection travel in each call**, so
one registered provider serves any number of user-entered workflows and boxes:

```swift
ctx.use(AIWorkflowPlugin(
    providers: [ComfyUIWorkflowProvider()],   // stateless w.r.t. the endpoint
    client: net,                              // your platform NetworkClient
    secrets: KeychainSecretStore()))          // optional — for secretRef headers
```

The web app then does: `ai.describeInputs` (graph × the box's `/object_info` →
a typed input schema, each field keyed `"<nodeID>/<inputName>"`) → render
controls → `ai.run` with the values (a reference/control image rides in as
`{ dataBase64 }` / `{ path }`, uploaded by the provider) → stream `progress`
(coarse `queued`→`running`, plus per-step `value`/`max` over ComfyUI's `/ws`) →
`image`(s) → `done`; `unsubscribe()` cancels via `POST /interrupt`. A
`connection.secretRef` is resolved against [`secrets.*`](secrets.md) **on the
Swift side**, so a key-protected endpoint's key never enters the page.

**Recovery.** Every `ai.run` event carries a `jobId` once submitted. If the
stream drops mid-run — the app was backgrounded, say, and a poll's `.local`
lookup failed — re-issue `ai.run` with `{ jobId }` (no graph/inputs) to
re-attach: the provider checks the box's `/history` + `/queue` and resumes
streaming, returns the finished outputs, or errors fast if the id is gone. (The
poll loop also tolerates a bounded run of transient failures on its own, so a
brief blip recovers without any app action.)

- **JS reference:** [`docs/javascript-api.md`](javascript-api.md#airun--aidescribeinputs--run-an-imported-workflow-at-runtime).
- **Worked example:** `Examples/CritterFacts/…/web/workflow.html` — paste a
  graph, introspect, set inputs (including a reference image), run with a live
  progress bar, cancel.

Additive: `ai.generateImage` and the Swift `runWorkflow`/`inspectWorkflow`
primitives are unchanged — this is a *runtime* door alongside the *build-time*
one.

### More than one provider (Imagen, on-device)

`ai.run` / `ai.describeInputs` route on a `provider` id, and `AIWorkflowPlugin`
takes a **list** — so the same JS page can drive a cloud API or an on-device
model through the exact same `describeInputs` → controls → `run` loop, no graph:

```swift
ctx.use(AIWorkflowPlugin(
    providers: [
        ComfyUIWorkflowProvider(),                          // graph, endpoint-per-call
        imagenProvider,                                     // fixed schema, cloud
        AIBackendWorkflowProvider(providerID: "on-device",  // wraps ANY AIBackend
                                  backend: stableDiffusion),
    ],
    client: net,
    secrets: KeychainSecretStore()))
```

- **`ImagenProvider`** conforms to `AIWorkflowProvider` directly — a **fixed
  schema** (`prompt`, a `model` enum when several are configured, an
  `aspectRatio` enum, `count`, `seed`), no graph, one-shot (`running` → `image`
  → `done`, no per-step progress). Its key comes from the connection (a
  `secretRef`-resolved header — fully runtime) or falls back to the key you
  injected at construction; **no connection is required** in the call.
- **`AIBackendWorkflowProvider`** (in Core) adapts *any* `AIBackend` — Stable
  Diffusion, LaMa, a future one — into a fixed-schema provider. The schema is
  derived from the backend's `AICapabilities`: a text→image backend advertises
  `prompt`/`steps`/`guidanceScale`/`seed`/`count`, a pure inpainter (`imageEditing`
  only) advertises `image`/`mask`. It bridges the backend's `generateImageStream`,
  so per-step progress flows through unchanged. No `jobId`/recovery (on-device
  runs aren't re-attachable).

A fixed-schema provider ignores the `connection`, so the JS omits it entirely —
`ai.describeInputs({ provider: "imagen" })`, `ai.run({ provider: "on-device",
inputs })`. The schema→controls renderer is identical for every provider; only a
graph provider (ComfyUI) needs the endpoint + graph in the call.

## One provider for many APIs — `RESTImageProvider` (config-driven)

Writing a Swift conformance per cloud API adds up. `RESTImageProvider` adapts to
an arbitrary JSON image API from a **descriptor** (`RESTImageAPISpec`) instead —
and the descriptor **travels in the call**, so a running web app can point it at a
new API with no rebuild. A descriptor parameterizes the five things these APIs
actually differ on:

- **endpoint** — a template appended to the connection's `baseURL`
  (`/models/${model}:predict`).
- **request** — a JSON body template with `${key}` placeholders (an exact
  `"${key}"` node adopts the value's type; an unresolved optional drops its key),
  **or** a multipart form (image/mask file parts + text) for edit endpoints.
- **flow** — one-shot, **or** async submit → poll a task until it succeeds (job
  APIs like Qwen/DashScope).
- **output** — a tiny JSONPath (`a[*].b.c`) to the image nodes + a relative
  `dataField` (base64 or a URL to fetch) + optional `mimeField`. Nodes missing the
  field are skipped (so Gemini's interleaved text parts are ignored for free).
- **auth** — from the `AIConnection` (`headers` + a `secretRef` resolved into
  `${secret}` server-side). No key material in the descriptor.

Presets ship as data — `.imagen`, `.openAICompatible`, `.geminiImage`
("nano banana"), `.openAIEdit` (multipart), `.qwen` (async). Register one on the
runtime surface (pinned preset, endpoint/key from the call):

```swift
ctx.use(AIWorkflowPlugin(providers: [
    RESTImageProvider(providerID: "gemini-image", spec: .geminiImage()),
], client: net, secrets: KeychainSecretStore()))
```

```js
// The key never enters JS — secretRef is resolved server-side into ${secret}.
__SWIFT_PWA__.subscribe('ai.run', {
    provider: 'gemini-image',
    connection: { baseURL: 'https://generativelanguage.googleapis.com/v1beta',
                  headers: { 'x-goog-api-key': '${secret}' }, secretRef: 'google-ai' },
    inputs: { prompt: 'a red panda astronaut' },
}, onChunk, onError, onEnd);
```

Or construct `RESTImageProvider()` (no pinned spec) and let the web app send the
descriptor in the call's `graph` — the fully bring-your-own-API path. It also
conforms to `RemoteImageProvider`, so a preset + injected `baseURL`/`auth`/`models`
drops it into the `ai.generateImage` switcher below.

**Limits (kept on the hand-written seam):** *conditional* parameter coupling a
flat template can't express — e.g. Imagen's "a seed forces `sampleCount:1` +
`addWatermark:false`". The `.imagen` preset omits `seed` for that reason. See
[docs/proposals/flexible-rest-image-provider.md](proposals/flexible-rest-image-provider.md).

## Composing into the switcher

A remote backend is *just another `AIBackend`*, so it drops into the shipped
`MultiModelImageBackend` next to your on-device models — one dropdown, local and
remote, routed by `request.model`:

```swift
let switcher = MultiModelImageBackend([
    .init(lcm.modelInfo.first!,    lcm),      // on-device (StableDiffusionBackend)
    .init(imagen.models.first!,    imagen),   // cloud
    .init(comfy.models.first!,     comfy),    // LAN appliance
], default: "lcm-dreamshaper")
ctx.use(AIPlugin(switcher))
```

`ai.info().models` then advertises all of them (each with `capabilities`,
`availability`, `offlineCapable`, `license`), the JS picker filters to
`image-generation`, and the switcher frees the previous model on switch (remote
backends inherit the no-op `unload()`, so they cost nothing there).

## Secure key storage

A cloud provider needs a secret the app doesn't have at build time. swift-pwa
deliberately **never persists your key** — `ImagenProvider(apiKey:)` is a closure
seam, and the key lives wherever *you* put it. Two rules follow:

1. **Never bake a key into `pwa.json`, source, or a commit** — environment
   secrets don't belong in the repo (use `.gitignore`'d local config for dev).
2. **Use the OS secure store, not `localStorage` or a file.** The [`secrets.*`
   plugin](secrets.md) gives you Keychain / Keystore / DPAPI / Secret Service
   behind one API; the `apiKey` closure reads straight through it:

   ```swift
   let store = KeychainSecretStore()            // Apple; AndroidSecretStore on Android
   ctx.use(SecretsPlugin(store))
   let imagen = RemoteImageBackend(
       provider: ImagenProvider(apiKey: { try? await store.get("google-ai") }),
       client: URLSessionNetworkClient()
   )
   ```

### The `needsSetup → enter → ready` flow

Don't fail only at generate time when there's no key — advertise the model as
**`needsSetup`** until one exists, so the picker can prompt for it. The key check
is app-owned (only the app knows the store / key name), so compute the
availability where you assemble `ai.info().models`:

```swift
let hasKey = (try? await store.get("google-ai")) != nil
let availability: AIModelAvailability =
    hasKey ? .ready : .needsSetup(reason: "Add a Google AI API key")
```

The page renders it: a `needsSetup` model reveals a password field instead of the
generate button; **Save** calls `secrets.set`, re-fetches `ai.info()` (now
`ready`), and generates. `Examples/CritterFacts` is the worked example —
`CompositeAIBackend` computes Imagen's availability from the store, and
`web/generate.html` swaps in the key field. A "clear key" affordance calls
`secrets.delete` to return to `needsSetup` (rotation / revocation). Keys are
per-device — not synced.

## Writing your own provider (the drop-in)

Conform `RemoteImageProvider` — `models`, `backendID`, and
`generateImage(_:client:)` — and wrap it in `RemoteImageBackend`. That's the
whole exercise; no framework change. Own your API's request building, its
request/poll/fetch flow, and seed semantics; use `RemoteImageOutput`-style
inline-vs-file handling by honoring `request.outputDirectory`. Throw
`AIError.generationFailed(_)` on API errors.

## Verification

Both shipped providers are verified end-to-end against real services (a
1024×1024 image round-trips through `URLSessionNetworkClient` → provider →
decode). The live tests are opt-in — set `SWIFT_PWA_LIVE_COMFY` (and optionally
`SWIFT_PWA_LIVE_COMFY_CKPT`) and/or `GEMINI_API_KEY`, then
`swift test --filter LiveRemoteAITests`; without those env vars they're skipped,
so CI and offline runs never touch the network.
