# Proposal: run imported ComfyUI workflows (a generic workflow runner)

> **Status: proposed (follow-up to the remote-AI tier, v0.8.8).** The shipped
> `ComfyUIProvider` runs one hard-coded `txt2imgSDXL` graph and discovers only
> `CheckpointLoaderSimple` checkpoints — so on a real box, Qwen-Image / Flux /
> edit / other pipelines never show up, and there's no image input. The obvious
> fix looked like "ship a template per architecture," but that has us chasing
> ComfyUI's whole node ecosystem forever.
>
> **The better primitive: run *any* API-format workflow the app imported, given
> named inputs.** ComfyUI's real power is user-authored graphs; if we can execute
> an adopter-supplied graph — `runWorkflow(inputs: ["image": …, "prompt": …])` →
> images — then **the app owns saving/selecting workflows and we own executing
> them.** No per-architecture code on our side. This proposal specs that runner.
>
> Depends on `SwiftPWARemoteAI` + the `net.*` / `NetworkClient` foundation.
> **Video (i2v / flf2v) is out of scope** — a separate epic needing a new
> output/verb contract (see the tail).

## Does ComfyUI expose workflows the way it exposes models?

Short answer: **no — not as runnable, model-keyed workflows.** The asymmetry is
the whole reason for this design, so it's worth stating precisely.

- **`GET /object_info`** — nodes + their input enums, including the loader model
  file-lists (`ckpt_name`, `unet_name`, …). This is the *models* surface; it's
  what discovery reads.
- **`POST /prompt`** — submit a graph in **API ("prompt") format**; `/history` +
  `/view` return results. `GET /prompt` is queue state, not workflows.
- **There is no endpoint that returns runnable, model-keyed workflows.** The
  server has no registry of "pipelines you can run and which model each uses."
- **`/userdata`** (a file API) *can* list the workflow JSONs the frontend saved
  under `user/.../workflows/`, and node packs bundle example workflows — **but**
  those are in **UI-graph format** (nodes with positions, link objects), not the
  API format `/prompt` accepts. The UI→API conversion (`graphToPrompt`) lives in
  the **frontend JS, not the server**, and the graphs aren't model-keyed (which
  checkpoint a workflow uses is just a widget value baked in a loader node). So
  even listing them server-side yields graphs we can't POST and can't map to a
  model.

The one thing that *is* directly usable: ComfyUI's **"Save (API Format)"** export
(and the API-format graph you already get from `/prompt` history). That JSON is
exactly what `/prompt` accepts. So the enabler isn't a server workflow API — it's
that **a human can export an API-format graph, and we can run it verbatim.**

## The primitive — a generic workflow runner

Execute an adopter-supplied API-format graph, binding named inputs into it and
extracting the image output(s):

```swift
let images = try await comfy.runWorkflow(
    graph: importedGraphJSON,          // the app's stored "Save (API Format)" JSON
    inputs: [
        "prompt": .text("a red panda astronaut"),
        "image":  .image(sourceImageBytes),   // uploaded automatically (see below)
        "seed":   .int(fresh ? nil : 12345),  // nil ⇒ randomized per run
    ],
    bindings: bindings                 // where each input goes in the graph (see below)
)
```

Under the hood it reuses everything the provider already does — `POST /prompt`
with a `client_id`, poll `/history/{id}`, fetch `/view` — plus three additions:

1. **Input binding.** Set each named input's value at its node-input location in
   the graph before submitting (see *Binding* below).
2. **Image upload.** An `.image` / `.mask` input is `POST`ed to `/upload/image`
   first; the returned filename is what gets bound into the target `LoadImage`
   node. (This is also what unlocks img2img / edit generally.)
3. **Seed policy.** A bound `seed` with no value is replaced with a fresh random
   seed per run (matching `ai.generateImage`'s documented behavior), so a graph
   with a baked seed doesn't return the identical image every call.

Output is the images from the graph's terminal `SaveImage` / output nodes
(non-image outputs — video, latents — are ignored in v1).

### Binding — how a named input reaches the right node

An API-format graph is `{ "<nodeId>": { "class_type": …, "inputs": { … }, "_meta": { "title": … } } }`.
Two ways to say where `"prompt"` / `"image"` / `"seed"` go, from turnkey to precise:

- **By node title (turnkey).** In ComfyUI the adopter titles the nodes they want
  to parameterize — e.g. a `CLIPTextEncode` titled **`prompt`**, a `LoadImage`
  titled **`image`**, a seed primitive titled **`seed`**. The runner matches
  `_meta.title` to the input name and sets that node's relevant input. Zero
  binding config — the parameterization lives in the workflow the adopter already
  authored. (This is the established "title your input nodes" ComfyUI-automation
  pattern.)
- **By explicit binding (precise).** A map from input name → node/input path:
  `["prompt": .at(node: "6", input: "text"), "image": .imageAt(node: "10", input: "image"), "seed": .at(node: "3", input: "seed")]`. For graphs the adopter
  can't retitle, or to disambiguate. `.imageAt` marks an input as an image
  (⇒ upload); `.at` is a scalar/string set directly.

Ship title-convention as the default with explicit bindings as the override.
Unbound/unknown inputs are ignored (a workflow can expose only the inputs it
wants driven).

## How it's exposed (and where the app's responsibility starts)

**The app owns import, storage, and selection of workflows** — the framework does
not persist graphs. Two consumption levels:

1. **As an `ai.*` image model (turnkey).** For a workflow whose inputs map to the
   standard request fields (`prompt` [+ `image`] [+ `seed`/`size`]), an adapter
   turns an imported workflow into an `AIModelInfo` (`comfy:workflow:<appId>`)
   that plugs into the same `MultiModelImageBackend` switcher; `ai.generateImage({ model, prompt, image })`
   routes to `runWorkflow` with the standard fields pre-bound. This keeps imported
   workflows in the unified `ai.*` surface with everything else.
2. **As a direct Swift call (fully general).** `comfy.runWorkflow(graph:inputs:bindings:)`
   accepts *arbitrary* named inputs — two images, a control image, numeric params
   — beyond what `AIGenerateImageRequest` models. An adopter exposes this to their
   web app however they like (a small custom command, since only they know their
   workflows' input shapes). We deliberately don't invent a ComfyUI-specific JS
   contract; the Swift primitive + the `ai.*` adapter cover the spectrum.

The existing `ComfyWorkflowTemplate` + `Patch` becomes a thin special case of the
runner: a "template we ship" is just *our* graph + default bindings. So the
built-in `txt2imgSDXL` (and any others we bundle as examples) ride the same code
path — no separate machinery.

## Discovery, reframed

With imported workflows as the primary catalog, model discovery is **secondary**:
a workflow that lets the user choose a checkpoint/unet can call the existing
`/object_info/<loaderNode>` enumeration to populate that choice. We keep
`discoverModels` (checkpoints) and optionally extend it to other loader nodes, but
it's no longer how pipelines get into the app — importing a workflow is.

## Open questions

1. **Binding ergonomics.** Is title-convention enough for the common case, or do
   most real workflows need explicit bindings? Lean: ship both; make the sample
   use titles to show the turnkey path.
2. **Input value types.** v1 set: `text`, `int`, `float`, `bool`, `image`,
   `mask`. Enough for prompt/seed/steps/cfg/size/denoise + image inputs. More as
   needed.
3. **Output beyond one image.** Return all images from output nodes (batch). A
   workflow with multiple distinct `SaveImage` nodes → concatenate in node order;
   document it.
4. **Validation / errors.** Surface ComfyUI's `/prompt` validation errors (bad
   node, missing model) as a clear `E_AI_GENERATION` with the server message,
   since imported graphs are user-authored and *will* sometimes be wrong for the
   box.
5. **Node-name / model-presence coupling.** An imported workflow references exact
   `class_type`s + a model filename that must exist on *that* box. That's
   inherent to ComfyUI portability; document it (the workflow and the box travel
   together).
6. **JS surface for arbitrary inputs.** Leave to the adopter (custom command) in
   v1, or add a generic `ai.runWorkflow`? Lean: adopter-owned first; revisit if a
   generic media-run contract is wanted (ties into the video epic).

## Phasing

- **Phase A — the runner core:** `runWorkflow(graph:inputs:bindings:)` — submit
  an API-format graph, bind scalar/string inputs (title-convention + explicit),
  seed policy, poll + extract images. Refactor the shipped `txt2imgSDXL` template
  to run through it. Verify a real imported txt2img workflow (Qwen / Flux) runs
  end-to-end against the box.
- **Phase B — image input:** `/upload/image` choreography + `.image` / `.mask`
  input types; verify a real img2img / edit workflow (source image → edited
  image) through the runner, including the composite routing an image-bearing
  `ai.generateImage` to a workflow-backed model.
- **Phase C — `ai.*` adapter + docs + example:** the "imported workflow →
  `AIModelInfo`" adapter for the standard-fields case; `docs/remote-ai.md`
  "Running your own ComfyUI workflows" (export API format → import → bind → run,
  with the title convention); `Examples/CritterFacts` imports a couple of
  API-format workflows (a txt2img and an edit) the user picks between; CHANGELOG.

## Verification plan

- Against a real ComfyUI instance: export an API-format txt2img workflow, run it
  via `runWorkflow` with a bound prompt/seed → image; an unknown/mistyped graph
  yields a clear error carrying ComfyUI's validation message.
- Image input: export an img2img/edit workflow, run with a source image (uploaded,
  then referenced by its `LoadImage`) and a prompt → edited image; confirm the
  composite routes an `image`-bearing request to it.
- Device (Tab S10+): a workflow-backed model runs through the `net.request` RPC
  in the switcher alongside on-device models.

## Not in scope — video (i2v / flf2v)

Deferred by request, and blocked at the *contract* level regardless of the runner:
the output is video (not `AIGeneratedImage`), and flf2v takes two input frames
where the request has a single `image`. The runner could *drive* such a graph, but
there's nowhere to return a video through `ai.generateImage`. Needs a new
`ai.generateVideo` verb (or a generalized media op) + a video output type +
multi-frame inputs — a separate epic. (Note: once the runner exists, the video
epic is mostly a *contract/output* problem, not an execution one — the runner
already knows how to submit an arbitrary graph and poll for outputs.)
