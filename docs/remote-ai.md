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

let imagen = RemoteImageBackend(
    provider: ImagenProvider(apiKey: { await myKeyStore.googleAIKey() }),
    client: URLSessionNetworkClient()
)
```

- Gemini-API REST (`POST {base}/models/{model}:predict`, `x-goog-api-key`).
- **The key is injected via a closure and never stored by swift-pwa** — you own
  storage, rotation, and the settings UI. A `nil` key fails at generate time
  with `E_AI_GENERATION`.
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
- **The one field that must match your instance is the checkpoint filename**
  (as it appears in ComfyUI's checkpoint list). For any non-default workflow,
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
