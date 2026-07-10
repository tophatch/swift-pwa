#!/usr/bin/env bash
#
# Vendor a LaMa-family inpainting ONNX model for `SwiftPWAImageEdit`'s
# `LaMaBackend` (ai.generateImage editing — see
# docs/proposals/image-generation-editing.md). Unlike the ONNX Runtime /
# llama.cpp vendor scripts, there is nothing to *build*: a LaMa ONNX export
# already exists, so this just downloads a known one, verifies it, and prints
# its sha256 + byte size to pin into `LaMaModelSource.bigLama`. `.github/
# workflows/lama-vendor.yml` runs this and re-hosts the file as the stable
# `lama-vendor` release asset `LaMaBackend`'s downloader fetches at runtime.
#
# Default source: the widely-used **big-lama fp32** ONNX export (Carve's
# LaMa-ONNX re-export of the Apache-2.0 big-lama checkpoint). Its graph is
# `image` [1,3,H,W] f32 + `mask` [1,1,H,W] f32 -> `output` [1,3,H,W] f32,
# which is what `LaMaModelSpec.bigLama` assumes; the on-hardware real-weights
# pass confirms the normalization / output range (see the proposal).
#
# Usage:
#   Scripts/vendor-lama.sh [source_url]
# Requires: curl, shasum. Runs on any host.
set -euo pipefail

SOURCE_URL="${1:-https://huggingface.co/Carve/LaMa-ONNX/resolve/main/lama_fp32.onnx}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/Vendor/lama}"            # gitignored
ASSET="$OUT/big-lama.onnx"                 # the published asset name

mkdir -p "$OUT"

echo "=== downloading LaMa ONNX from $SOURCE_URL ===" >&2
curl -L --fail -o "$ASSET" "$SOURCE_URL"

# A LaMa ONNX is tens of MB; a few-KB file means an HTML error page slipped
# past --fail (some CDNs 200 an error body). Fail loudly rather than publish it.
size="$(wc -c < "$ASSET" | tr -d '[:space:]')"
if [ "$size" -lt 1000000 ]; then
    echo "FATAL: $ASSET is only $size bytes — expected tens of MB. Bad URL or an error page?" >&2
    exit 1
fi

echo
echo "=== vendored ==="
echo "$ASSET ($(du -h "$ASSET" | cut -f1))"
echo
echo "=== pin these into LaMaModelSource.bigLama (SwiftPWAImageEdit/LaMaModelSpec.swift) ==="
echo "sha256:    $(shasum -a 256 "$ASSET" | awk '{print $1}')"
echo "sizeBytes: $size"
