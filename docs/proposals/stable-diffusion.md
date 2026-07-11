# Proposal: on-device text→image (`stable-diffusion-onnx`)

> **Status: skeleton landed; real-weights pass pending.** The second
> `ai.generateImage` backend, after LaMa inpainting (shipped v0.8.3/0.8.4).
> Adds **text→image** generation on the shared ONNX Runtime tier, targeting a
> **small distilled model** (SD-Turbo / LCM — 1–4 denoising steps) so it's
> actually usable on-device.
>
> **Done (this increment):** the `SwiftPWAStableDiffusion` target +
> `StableDiffusionBackend` (`stable-diffusion-onnx`, `imageGeneration: true`);
> the fully-implemented, unit-tested **CLIP byte-level BPE tokenizer**
> (`CLIPTokenizer`, needs no weights); the deterministic seeded latent init +
> timestep schedule (`StableDiffusionSampling`); a configurable
> `StableDiffusionModelSpec`; a multi-file downloadable
> `StableDiffusionModelSource` + `ai.ensureModel` wiring. `generateImage`
> tokenizes the prompt, then throws a clear "pending real-weights integration"
> error at the denoising boundary.
>
> **Done since (real-weights pass):** the full pipeline is implemented and
> **verified against a diffusers SD-Turbo reference**. `OrtModelSession` gained
> integer input tensors (`OrtInput` — the text encoder's `input_ids` is int64,
> not int32; the UNet `timestep` is a float32 scalar); an
> `EulerDiscreteScheduler` port reproduces diffusers' SD-Turbo numbers exactly
> (`setTimesteps(1)` → timesteps `[999]`, sigmas `[14.6146, 0]`,
> `initNoiseSigma 14.6146`); and `runTxt2Img` (tokenize → text-encode → denoise
> → VAE-decode) matches the reference to within float noise (text embedding /
> latent / image correlation > 0.9999999; decoded image pixel-identical). The
> corrections the export forced on the assumed spec: `input_ids` **int64**,
> `timestep` **float32 scalar**, embedding dim **1024** (SD-2.1 OpenCLIP, not
> 768), scheduler **`trailing`** spacing + `epsilon`, and — the one real bug —
> CLIP pads with **`"!"` (id 0)**, not the end-of-text token.
>
> **Also done:** `ai.generateImage` works end-to-end (prompt → PNG). Image
> encode/decode was hoisted out of the LaMa backend into a shared
> `SwiftPWAImageIO` target (`package`-internal `ImageCodec` / `RawImage`, reused
> by LaMa and SD); `generateImage` encodes the VAE output to PNG (written file
> or inline base64), `generateImageStream` reports per-step denoising progress,
> and `count` is honored.
>
> **Next:** the **LCM (OpenRAIL-M)** commercial default (a second scheduler +
> the guidance-embedding UNet input) + `sd-vendor` packaging with pinned
> checksums (see the licensing note under **Scoping calls**).

## Motivation

`ai.generateImage` shipped as a purpose-agnostic op: `prompt` → text→image,
`prompt` + `image` → img2img, `image` + `mask` → inpaint. LaMa filled the
inpaint slot. This fills the **text→image** slot — a `prompt` alone produces
an image — the headline generative-image capability, and the last big piece of
the `ai.*` image surface. It reuses the same ONNX Runtime tier (`SwiftPWAONNX`)
LaMa and MobileSAM run on, including the desktop CUDA/DirectML GPU providers.

**Why a distilled model.** A classic SD 1.5 pipeline is ~20–50 UNet passes per
image and a ~2 GB fp16 download — tens of seconds+ per image on a mobile/CPU
target, which the LaMa perf lessons say is a poor on-device experience.
**SD-Turbo** (adversarial-distilled, 1–4 steps, guidance-free) and **LCM**
(latent consistency, ~4 steps) collapse the denoising loop to a handful of
passes, which is the difference between "usable on a phone" and "not." First
cut targets one of these.

## The pipeline (SD-Turbo / LCM, ONNX)

A Stable-Diffusion pipeline is **four models + a tokenizer + a scheduler**, not
one graph (unlike LaMa's single graph). The standard 🤗 `optimum`/`diffusers`
ONNX export lays them out as:

```
text_encoder/model.onnx     CLIP text encoder:  input_ids [1,77] int32 → last_hidden_state [1,77,E]
unet/model.onnx             denoiser:  sample [1,4,h,w] + timestep [1] + encoder_hidden_states [1,77,E] → out [1,4,h,w]
vae_decoder/model.onnx      latents [1,4,h,w] → image [1,3,H,W]  (H=8h, W=8w), pixels in [-1,1]
tokenizer/{vocab.json, merges.txt}   CLIP BPE, 49406=<|startoftext|>, 49407=<|endoftext|>, pad to 77
```

**Generation (txt2img), few-step / guidance-free (SD-Turbo):**

1. **Tokenize** the prompt (CLIP BPE → `input_ids`, bos + tokens + eos, padded/truncated to 77).
2. **Text-encode** → `encoder_hidden_states`.
3. **Init latents** `[1,4,64,64]` (for 512²; latent is 1/8 scale) from a seeded
   Gaussian, scaled by the scheduler's `init_noise_sigma`.
4. **Denoise loop** (`steps`, default the model's — 1–4): `unet(latent,
   timestep_t, text_emb) → noise_pred`; `scheduler.step(noise_pred, t, latent)
   → latent`. Guidance-free models skip classifier-free guidance (no negative
   branch, one UNet pass per step); a CFG model doubles the batch with the
   negative-prompt embedding and combines — a spec flag.
5. **VAE-decode** `latent / vae_scaling_factor` → image `[-1,1]` → `[0,255]` RGB.
6. Emit (written to `outputDirectory` or inline base64), echoing the seed.

**Streaming** (`ai.generateImageStream`): emit an `AIImageEvent.progress(step,
totalSteps)` per denoising step; an optional intermediate `preview` (a cheap
VAE-decode of the in-progress latent) is a later refinement. Terminal `done`.

## Contract fit — already there

No contract change. `ai.generateImage` / `ai.generateImageStream` and their
request/result/streaming types (shipped v0.7.0, generalized v0.8.3) cover it:

- `AIGenerateImageRequest`: `prompt`, `negativePrompt`, `width`, `height`,
  `steps`, `seed`, `count`, `guidanceScale`, `outputDirectory` — exactly the SD
  knobs. (`image`/`mask`/`strength` enable SD img2img / SD-inpaint later.)
- `AICapabilities.imageGeneration` = true (vs LaMa's `imageEditing`).
- `AIBackendID.stableDiffusionONNX` (`"stable-diffusion-onnx"`) is reserved.
- `AIImageEvent` already has `progress(step, totalSteps, preview?)` + `done`.

## Swift surface

New target **`SwiftPWAStableDiffusion`** (parallels `SwiftPWAImageEdit`), a
`StableDiffusionBackend: AIBackend` reusing `SwiftPWAONNX`'s `OrtModelSession`
for the three graphs. Model + geometry + scheduler in a configurable
**`StableDiffusionModelSpec`** (like `LaMaModelSpec`) so the assumed tensor
names / scaling / scheduler constants can be corrected on the real-weights pass
without touching the orchestration. A downloadable **`StableDiffusionModelSource`**
(multi-file, like `MobileSAMModelSource`) hosted on a `sd-vendor`-style release.

Pieces, by how much they need real weights:

- **CLIP BPE tokenizer** — pure, deterministic, needs only `vocab.json` +
  `merges.txt` (small, committable/bundleable). **Implemented + unit-tested in
  this increment** (no model download).
- **Orchestration** (encode → loop → decode, session management, seeded latent
  init, output encode) — structured now against `OrtModelSession`.
- **Scheduler** (timesteps, sigmas, `step()`), **tensor names/shapes**,
  **`vae_scaling_factor`**, **guidance handling** — assumed from the SD-Turbo /
  diffusers defaults in `StableDiffusionModelSpec`, **confirmed on real weights**
  (the SAM/LaMa pattern: a real-weights pass corrected assumptions there too).

## Model hosting

The distilled pipeline (text encoder + UNet + VAE decoder + tokenizer files) is
re-hosted on a stable `sd-vendor` GitHub release via a `Scripts/vendor-sd.sh` +
`.github/workflows/sd-vendor.yml` (the pattern from `lama-vendor` /
`mobilesam-vendor`), fetched at runtime by `ai.ensureModel` through the same
`ModelDownloader` (resumable, checksum-pinned; on Android via the Kotlin
`net.downloadFile` RPC — the CA-store reason LaMa/MobileSAM already route that
way). Even distilled, this is the largest model tier yet (hundreds of MB), so
`ai.ensureModel` progress matters; int8/quantized exports are a size lever.

## Perf / memory notes

- UNet dominates (run `steps` times); text-encode + VAE-decode are once each.
- Latent is 1/8 the image; 512² ⇒ 64² latent. Keep the default output modest
  (512²) — bigger is quadratically more UNet compute.
- Reuse the loaded sessions across calls (load-once), like `LaMaBackend`.
- On-device this is heavier than LaMa; the distilled-model + step-count choice
  is the main perf lever. Desktop gets the CUDA/DirectML EPs for free via
  `SwiftPWAONNX`.

## Open questions

1. **SD-Turbo vs LCM** for the first model — both are few-step; SD-Turbo is
   guidance-free (simplest loop), LCM needs the LCM scheduler. Lean SD-Turbo
   for the simplest correct first cut.
2. **Scheduler scope** — implement just the one the chosen model needs, behind
   the spec, not a general scheduler zoo.
3. **`count > 1`** — loop the pipeline vs batch the UNet; loop first (simpler,
   bounded memory).
4. **img2img / SD-inpaint** (`image`/`mask` on the request) — natural follow-on
   once txt2img works (encode the input image to a latent, start the loop
   partway per `strength`); out of scope for the first cut.

## Scoping calls (2026-07-11)

Decided with the maintainer before drafting:

1. **Runtime: `stable-diffusion-onnx`** on the shared `SwiftPWAONNX` tier —
   one cross-platform implementation (+ desktop GPU EPs), consistent with
   LaMa/MobileSAM. (An Apple `stable-diffusion-mlx` fast-path is a possible
   later follow, not now.)
2. **Model: a small distilled export (SD-Turbo / LCM), ONNX** — few-step,
   on-device-viable, smaller download.
3. **This increment = proposal + backend skeleton + CLIP tokenizer** (design
   and the weight-free pieces); real-weights verification of the
   scheduler/UNet/VAE plumbing is the next increment, after review.
