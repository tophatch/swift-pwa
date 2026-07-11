#!/usr/bin/env bash
#
# Vendor a Stable-Diffusion-Turbo ONNX pipeline for `SwiftPWAStableDiffusion`'s
# `StableDiffusionBackend` (ai.generateImage text->image — see
# docs/proposals/stable-diffusion.md). Unlike the LaMa/MobileSAM single-file
# vendors, SD is a multi-file pipeline (text encoder + UNet + VAE decoder +
# CLIP tokenizer), exported from `stabilityai/sd-turbo` with 🤗 optimum.
#
# We publish the **fp16** export (`--dtype fp16`): ~2.5 GB (vs ~4.9 GB fp32),
# faster on GPU/CoreML, and it still runs on the CPU EP. Every fp16 file is
# under GitHub's 2 GB per-asset limit (the fp16 UNet is a single inline file);
# the fp32 UNet's external-data file (~3.5 GB) exceeds that limit, so fp32 is
# hosted elsewhere (Hugging Face) — not by this script.
#
# The graph contract (tensor names, dtypes, scheduler, VAE scaling) was
# confirmed on-hardware against a diffusers reference — see the proposal and
# `StableDiffusionModelSpec.sdTurboFp16`.
#
# Usage:
#   Scripts/vendor-sd.sh export       # export fp16 ONNX into $OUT (needs optimum)
#   Scripts/vendor-sd.sh checksums    # print sha256 + byte size to pin
#   Scripts/vendor-sd.sh publish      # gh release create sd-vendor + upload
#
# Requires: python3 with `optimum[exporters]` + `optimum-onnx` (export),
# shasum (checksums), gh (publish). License: the exported weights are
# `stabilityai/sd-turbo` under the Stability AI Non-Commercial Community
# License — redistributed with attribution, non-commercial use only.
set -euo pipefail

MODEL="${MODEL:-stabilityai/sd-turbo}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/Vendor/sd-turbo-fp16}"   # gitignored
REPO="${REPO:-tophatch/swift-pwa}"
TAG="${TAG:-sd-vendor}"

# asset name (on the release)      <-  local file in the optimum export tree
declare -a ASSETS=(
  "sd-turbo-fp16-text_encoder.onnx text_encoder/model.onnx"
  "sd-turbo-fp16-unet.onnx         unet/model.onnx"
  "sd-turbo-fp16-vae_decoder.onnx  vae_decoder/model.onnx"
  "sd-turbo-vocab.json             tokenizer/vocab.json"
  "sd-turbo-merges.txt             tokenizer/merges.txt"
)

case "${1:-}" in
  export)
    mkdir -p "$OUT"
    optimum-cli export onnx --model "$MODEL" --dtype fp16 --device cpu "$OUT"
    echo "Exported fp16 pipeline to $OUT"
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
    gh release create "$TAG" -R "$REPO" --prerelease \
      --title "SD-Turbo ONNX (vendored weights)" \
      --notes "Vendored fp16 SD-Turbo ONNX weights for the stable-diffusion-onnx backend. optimum --dtype fp16 export of stabilityai/sd-turbo; Stability AI Non-Commercial Community License (redistributed with attribution)." \
      "${args[@]}"
    echo "Published $TAG. Pin the checksums (Scripts/vendor-sd.sh checksums) into StableDiffusionModelSource.sdTurboFp16."
    ;;
  *)
    echo "usage: $0 {export|checksums|publish}" >&2
    exit 1
    ;;
esac
