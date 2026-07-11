#!/usr/bin/env bash
#
# Vendor a Stable-Diffusion-family ONNX pipeline for `SwiftPWAStableDiffusion`'s
# `StableDiffusionBackend` (ai.generateImage text->image — see
# docs/proposals/stable-diffusion.md). Unlike the LaMa/MobileSAM single-file
# vendors, SD is a multi-file pipeline (text encoder + UNet + VAE decoder +
# CLIP tokenizer), exported with 🤗 optimum.
#
# Two models, selected by KIND:
#   KIND=sdturbo (default) — stabilityai/sd-turbo (SD-2.1 base, 1-step, Euler).
#                            Stability AI Non-Commercial Community License.
#   KIND=lcm               — SimianLuo/LCM_Dreamshaper_v7 (SD-1.5 base, 4-step,
#                            LCM scheduler + timestep_cond). OpenRAIL-M —
#                            **commercially usable**, the default we point apps at.
#
# We publish the **fp16** export (`--dtype fp16`): ~half the size, faster on
# GPU/CoreML, still runs on the CPU EP; every file is under GitHub's 2 GB limit.
#
# Usage:
#   KIND=lcm Scripts/vendor-sd.sh export     # export fp16 ONNX into $OUT (needs optimum)
#   KIND=lcm Scripts/vendor-sd.sh checksums  # print sha256 + byte size to pin
#   KIND=lcm Scripts/vendor-sd.sh publish    # gh release upload to sd-vendor
#
# Requires: python3 with `optimum[exporters]` + `optimum-onnx` + `onnx` (export),
# shasum (checksums), gh (publish).
#
# NB (LCM): optimum's LatentConsistencyModelPipeline fp16+CPU export can die
# after the UNet during its post-processing. If that happens, the text_encoder +
# unet still export fine; export the VAE decoder alone with a small
# torch.onnx.export script and inline its weights:
#   python3 -c 'import torch; from diffusers import AutoencoderKL; \
#     v=AutoencoderKL.from_pretrained("SimianLuo/LCM_Dreamshaper_v7",subfolder="vae").eval().half(); \
#     class D(torch.nn.Module):\n  def __init__(s,m):super().__init__();s.m=m\n  def forward(s,latent_sample):return s.m.decode(latent_sample).sample; \
#     torch.onnx.export(D(v),(torch.randn(1,4,64,64).half(),),"vae_decoder/model.onnx", \
#       input_names=["latent_sample"],output_names=["sample"],opset_version=18)'
#   python3 -c 'import onnx; onnx.save_model(onnx.load("vae_decoder/model.onnx"), \
#       "vae_decoder/model.onnx", save_as_external_data=False)'  # inline -> single file
# Also: run heavy box work in a FOREGROUND shell (detached/backgrounded exports
# were getting killed mid-run).
set -euo pipefail

KIND="${KIND:-sdturbo}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-tophatch/swift-pwa}"
TAG="${TAG:-sd-vendor}"

case "$KIND" in
  sdturbo)
    MODEL="${MODEL:-stabilityai/sd-turbo}"
    OUT="${OUT:-$ROOT/Vendor/sd-turbo-fp16}"
    PREFIX="sd-turbo-fp16"
    NOTES="Vendored fp16 SD-Turbo ONNX weights. optimum --dtype fp16 export of stabilityai/sd-turbo; Stability AI Non-Commercial Community License (redistributed with attribution, non-commercial use only)."
    # SD-Turbo publishes its own tokenizer files (sd-turbo-vocab.json/merges.txt).
    declare -a ASSETS=(
      "sd-turbo-fp16-text_encoder.onnx text_encoder/model.onnx"
      "sd-turbo-fp16-unet.onnx         unet/model.onnx"
      "sd-turbo-fp16-vae_decoder.onnx  vae_decoder/model.onnx"
      "sd-turbo-vocab.json             tokenizer/vocab.json"
      "sd-turbo-merges.txt             tokenizer/merges.txt"
    )
    ;;
  lcm)
    MODEL="${MODEL:-SimianLuo/LCM_Dreamshaper_v7}"
    OUT="${OUT:-$ROOT/Vendor/lcm-dreamshaper-fp16}"
    PREFIX="lcm-dreamshaper-fp16"
    NOTES="Vendored fp16 LCM_Dreamshaper_v7 ONNX weights for the stable-diffusion-onnx backend (SD-1.5 base, 4-step LCM). openrail++ / OpenRAIL-M — commercially usable. Verified against a diffusers reference."
    # LCM's CLIP tokenizer is byte-identical to SD-Turbo's, so we reuse the
    # published sd-turbo-vocab.json / sd-turbo-merges.txt assets — only the
    # three model graphs are LCM-specific.
    declare -a ASSETS=(
      "lcm-dreamshaper-fp16-text_encoder.onnx text_encoder/model.onnx"
      "lcm-dreamshaper-fp16-unet.onnx         unet/model.onnx"
      "lcm-dreamshaper-fp16-vae_decoder.onnx  vae_decoder/model.onnx"
    )
    ;;
  *)
    echo "unknown KIND '$KIND' (want sdturbo|lcm)" >&2; exit 1 ;;
esac

case "${1:-}" in
  export)
    mkdir -p "$OUT"
    optimum-cli export onnx --model "$MODEL" --dtype fp16 --device cpu "$OUT"
    echo "Exported fp16 pipeline to $OUT (KIND=$KIND)"
    ;;
  checksums)
    for entry in "${ASSETS[@]}"; do
      read -r asset local <<<"$entry"
      path="$OUT/$local"
      printf "%s  %s  %s\n" "$(shasum -a 256 "$path" | cut -d' ' -f1)" "$(wc -c <"$path")" "$asset"
    done
    ;;
  publish)
    args=()
    for entry in "${ASSETS[@]}"; do
      read -r asset local <<<"$entry"
      staged="$OUT/$asset"
      cp "$OUT/$local" "$staged"
      args+=("$staged")
    done
    # The sd-vendor release already exists; upload (or --clobber) the assets.
    gh release upload "$TAG" -R "$REPO" --clobber "${args[@]}"
    echo "Uploaded $KIND assets to $TAG. Pin checksums (KIND=$KIND $0 checksums) into StableDiffusionModelSource.${KIND/sdturbo/sdTurbo}${KIND/lcm/lcmDreamshaper}Fp16."
    ;;
  *)
    echo "usage: KIND={sdturbo|lcm} $0 {export|checksums|publish}" >&2
    exit 1
    ;;
esac
