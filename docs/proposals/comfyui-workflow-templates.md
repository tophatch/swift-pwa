# Proposal: ComfyUI workflow templates — multi-architecture discovery + img2img

> **Status: proposed (follow-up to the remote-AI tier, v0.8.8).** The shipped
> `ComfyUIProvider` is deliberately the turnkey common case: it discovers only
> `CheckpointLoaderSimple` checkpoints and runs a single `txt2imgSDXL` graph. So
> on a real ComfyUI box, only the SD/SDXL-family checkpoints show up in the
> switcher — the Qwen-Image / Flux / other diffusion-model weights (in
> `models/diffusion_models/`, loaded by other nodes) never appear, and img2img /
> instruction-edit can't run at all (there's no input-image path). This proposal
> makes the provider **multi-architecture** and adds **image input**, while
> keeping "a new workflow is data, not a fork" the design center.
>
> Depends on `SwiftPWARemoteAI` (`docs/remote-ai.md`) and the `net.*` /
> `NetworkClient` foundation. **Video (i2v / flf2v) is explicitly out of scope**
> — it needs a new output/verb contract (a separate epic; see the tail).

## The gap (as shipped)

`ComfyUIProvider` today ([Sources/SwiftPWARemoteAI/ComfyUIProvider.swift](../../Sources/SwiftPWARemoteAI/ComfyUIProvider.swift)):

- **Discovery is one loader node.** `discoverModels` → `discoverCheckpoints`
  queries `GET /object_info/CheckpointLoaderSimple` and reads its `ckpt_name`
  enum — i.e. only `models/checkpoints/` all-in-one checkpoints. Qwen-Image,
  Flux, SD3, etc. are diffusion-model/UNet weights loaded by `UNETLoader`
  (`unet_name`) / `UnetLoaderGGUF` and paired with their own CLIP/VAE loaders, so
  they're invisible.
- **One graph.** A single `txt2imgSDXL` template keyed on a checkpoint. Even if a
  Qwen model were listed, that SDXL graph can't run it (different text encoder /
  VAE / sampler nodes).
- **No image input.** No `/upload/image` choreography and no `.image` patch
  field, so `request.image` (img2img / edit) is ignored — even though the request
  contract has carried `image` / `mask` / `strength` since 0.8.3.

## The core constraint (why this can't be pure auto-discovery)

ComfyUI models are **not self-describing enough to auto-map to a graph.** A file
in `diffusion_models/` might be Flux, Qwen, SD3, or a video model — each needing
a *different* node graph, text encoder, and VAE. `/object_info` tells you which
loader nodes exist and which files each can load, but **not** which architecture
a given file is, nor the full graph to run it. So the honest model is:

> **The adopter declares the graphs; discovery enumerates the files that fit
> each graph.** Not "list every model and magically run it."

That keeps the picker populated with what's actually on the box *and* runnable,
without pretending we can synthesize a Flux pipeline from a filename.

## Part 1 — Templates become a keyed set (was: one `workflow:`)

Generalize `ComfyUIProvider` from a single `workflow:` to a set of named
templates. Each `ComfyWorkflowTemplate` gains:

- `key` + `label` — the picker entry name (e.g. `"qwen-image"`, `"SDXL img2img"`).
- `loaderNode` + `loaderInput` — where its models come from (e.g.
  `("CheckpointLoaderSimple", "ckpt_name")`, `("UNETLoader", "unet_name")`).
- `capabilities: Set<AIModelCapability>` — `text-generation` n/a; here
  `image-generation` (txt2img) or `image-edit` (img2img/edit) — surfaced on each
  discovered model's `AIModelInfo.capabilities` so the page filters/routes.
- the graph + `Patch`es (unchanged shape).

```swift
let comfy = RemoteImageBackend(
    provider: ComfyUIProvider(baseURL: url, workflows: [
        .txt2imgSDXL(),          // CheckpointLoaderSimple / ckpt_name
        .txt2imgQwen(),          // UNETLoader / unet_name (+ Qwen CLIP/VAE)
        .txt2imgFlux(),          // UNETLoader / unet_name (+ dual CLIP, flux VAE)
        .img2imgSDXL(),          // adds a LoadImage node (see Part 3)
        .editQwen(),             // Qwen-Image-Edit (image + prompt → image)
    ]),
    client: makeNetworkClient()
)
```

The single-`workflow:` init stays as sugar (`workflows: [workflow]`) so existing
code is source-compatible; the default remains SDXL-txt2img-only.

**Ship a small built-in library**, validated against a real box: `txt2imgSDXL`
(exists), `img2imgSDXL`, `txt2imgQwen`, `editQwen`, `txt2imgFlux`. Adopters add
their own — a template is just a graph literal + patches + metadata.

## Part 2 — Discovery per template

`discoverModels` iterates the registered templates; for each, query
`GET /object_info/<loaderNode>`, read the `<loaderInput>` enum, and mint one
`AIModelInfo` per file with the template's capabilities:

- **Model id scheme:** `comfy:<templateKey>:<file>` (e.g.
  `comfy:qwen-image:qwen_image_fp8.safetensors`). Routing splits on the first two
  segments → (template, file). **Back-compat:** a legacy `comfy:<file>` (no
  template segment) resolves to the default SDXL txt2img template.
- A file that fits two templates (e.g. a Qwen weight usable for both txt2img and
  edit) yields **two** entries — `comfy:qwen-image:…` and `comfy:qwen-edit:…` —
  which is what the user wants (distinct picker rows, distinct capabilities).
- Same bounded + cached discovery the composite already does, now × N templates
  (a handful of `/object_info` calls); log what each template found.

`resolveCheckpoint` generalizes to `resolve(model:)` → `(template, file)`, and
`build(...)` uses that template's graph, patching the file into its loader node.

## Part 3 — Image input (img2img / edit) through the shipped provider

Make `request.image` actually reach a ComfyUI graph:

1. **Upload step.** When the resolved template is image-input and
   `request.image` is present, `POST multipart /upload/image` (the bytes +
   `overwrite=true` + a stable name), get back the stored filename. `request.mask`
   uploads the same way when the template declares a mask input.
2. **New `Field` cases** `.image` / `.mask`, patched into the template's
   `LoadImage` node(s) `image` input by the uploaded filename. `.strength` is
   already mappable (denoise). So the edit graph gets: uploaded image → VAEEncode
   → KSampler(denoise=strength) → decode, or the model's native edit nodes.
3. `RemoteImageBackend`/the composite already route a request *with* an `image`
   to the edit path; an `image-edit`-capable `comfy:` model now participates
   there instead of only LaMa.

This closes the one item that was "arguably ours to offer" — the request
contract already supported edits; only the ComfyUI provider couldn't act on them.

## What stays the adopter's job (explicitly)

Anything that fits **params (+ image[s]) → image** but isn't in the shipped
library is still a drop-in: write a `ComfyWorkflowTemplate` (graph + patches +
loader + capabilities) and add it to `workflows:`. We ship a representative set +
the machinery; we don't chase every ComfyUI node pack. The proposal's value is
the *machinery* (multi-loader discovery + image upload + the keyed-template
model), not an exhaustive catalog.

## Open questions

1. **Which templates ship built-in?** Lean: SDXL txt2img + SDXL img2img + Qwen
   txt2img + Qwen edit + Flux txt2img — enough to prove each machinery axis
   (checkpoint vs unet loader; txt2img vs edit; a dual-CLIP arch). More via PRs.
2. **Node-name fragility.** ComfyUI graphs reference exact `class_type`s that
   drift across ComfyUI / custom-node versions. Built-in templates target current
   core nodes; document that a template is version-coupled and adopters may need
   to tweak. (Same reality as any ComfyUI API-format workflow.)
3. **Mask handling parity.** Do we support ComfyUI inpaint (image+mask) too, or
   only img2img (image+strength) in v1? Lean: both fields upload; ship img2img
   first, inpaint template as a fast-follow.
4. **Model-id migration.** `comfy:<file>` → `comfy:<template>:<file>` changes
   discovered ids. They're runtime-discovered (never persisted by the framework),
   so low-risk; keep the legacy form resolving to SDXL-txt2img.

## Phasing

- **Phase A — keyed templates + multi-loader discovery** (Part 1 + 2): the
  `workflows:` set, per-template `/object_info` discovery, the `comfy:<tpl>:<file>`
  id scheme + back-compat, and the built-in txt2img library (SDXL/Qwen/Flux).
  Verify on the real box: the Qwen / Flux weights now appear and generate.
- **Phase B — image input** (Part 3): `/upload/image` choreography + `.image` /
  `.mask` fields + the img2img/edit templates (SDXL img2img, Qwen edit). Verify a
  real edit end-to-end (source image + prompt → edited image) through the
  provider, and that the composite routes an image-bearing request to the
  `image-edit` comfy model.
- **Phase C — docs + example:** `docs/remote-ai.md` template-library section +
  "writing a template"; `Examples/CritterFacts` shows a Qwen txt2img arm and an
  edit arm alongside SDXL; CHANGELOG.

## Verification plan

- Against a real ComfyUI instance with mixed weights (SDXL checkpoints + Qwen +
  Flux in `diffusion_models/`): `discoverModels` lists each under the right
  template with the right capability; generating each `comfy:<tpl>:<file>` returns
  an image; an unknown id is rejected.
- The upload path: a real img2img/edit round-trip (source image uploaded,
  referenced by a `LoadImage` node, edited output returned), plus the
  composite routing an `image`-bearing request to the comfy edit model.
- Device (Tab S10+) re-check that the switcher still lists + routes the expanded
  catalog through the `net.request` RPC.

## Not in scope — video (i2v / flf2v)

Video is a separate epic, deferred by request. It's blocked at the *contract*
level, not the workflow level: the output is video (not `AIGeneratedImage`), and
flf2v needs two input frames where the request has a single `image`. It needs a
new `ai.generateVideo` verb (or a generalized media op) with a video output type
and multi-frame inputs — no template authoring reaches it. Tracked for later.
