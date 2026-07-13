# Sample ComfyUI workflows

Real ComfyUI **API-format** graphs (what "Save (API Format)" exports), used as
examples for the `ComfyUIProvider` workflow runner and as regression fixtures
(`Tests/SwiftPWARemoteAITests/RealWorkflowFixtureTests.swift`).

They are **sanitized**: every model / LoRA / image filename is a generic
placeholder (`diffusion-model.safetensors`, `checkpoint.safetensors`,
`input.png`, …) and prompts are generic. The graph *structure* — node classes,
wiring, `_meta.title`s — is intact, which is what the runner and introspection
operate on.

To actually run one against a ComfyUI instance, repoint the loader nodes'
filenames to models that box has installed (or use `inspectWorkflow` to
enumerate the instance's real options for each loader). These are illustrative,
not runnable as-is.

| file | shape |
|------|-------|
| `qwen_image_2512.json` | Qwen-Image text→image |
| `image_qwen_image_edit_2509.json` | Qwen-Image-Edit (image + prompt → edited image) |
| `image_lotus_depth_v1.json` | depth estimation (`SamplerCustomAdvanced`) |
| `imageupscalebymodel-esrgan-x4.json` | upscale-by-model (image → image) |
| `comfy-workflow-faceinput.json` | SDXL + IP-Adapter face reference (rgthree Power Lora Loader) |
