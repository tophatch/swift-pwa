#!/usr/bin/env bash
#
# Vendor the ONNX Runtime **Linux x86_64 GPU (CUDA 12)** build for the desktop
# `MobileSAMBackend` when `ai.onnx_gpu` is set (see
# docs/proposals/onnx-gpu-execution-providers.md). The GPU analogue of
# Scripts/vendor-onnxruntime-linux.sh.
#
# Unlike the CPU build (a single 8 MB `libonnxruntime.so`), the CUDA build is a
# ~230 MB tarball that ships the runtime plus the out-of-tree CUDA provider as
# separate shared libs, loaded on demand:
#   libonnxruntime.so.<ver>              — the runtime (SONAME libonnxruntime.so.1)
#   libonnxruntime_providers_shared.so   — the shared-provider bridge
#   libonnxruntime_providers_cuda.so     — the CUDA execution provider (~366 MB)
# (TensorRT's provider ships too but we don't use it, so it's skipped.)
#
# The CUDA runtime + cuDNN themselves are NOT vendored — they're expected on the
# target machine; a missing/mismatched CUDA runtime makes the CUDA EP fail to
# load, which the backend turns into a transparent CPU fallback.
#
# Headers are IDENTICAL to the CPU build (only cpu_provider_factory.h +
# provider_options.h + the C API — CUDA uses the in-header
# `OrtSessionOptionsAppendExecutionProvider_CUDA`, no extra header), and this is
# ORT 1.27.0 like the CPU build, so the committed `Vendor/onnxruntime-desktop-
# headers/` (module ONNXRuntimeDesktop) is reused as-is — this script only
# fetches the libs.
#
# Usage:
#   Scripts/vendor-onnxruntime-linux-gpu.sh [version]
# Requires: curl, tar, shasum. Runs on any host (download + extract are
# platform-independent; only the link/run against the ELF `.so`s needs Linux).
set -euo pipefail

ONNXRUNTIME_VERSION="${1:-1.27.0}"
SLUG="onnxruntime-linux-x64-gpu_cuda12-${ONNXRUNTIME_VERSION}"
URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/${SLUG}.tgz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/onnxruntime-linux-gpu}"
OUT="${OUT:-$ROOT/Vendor/onnxruntime-desktop-gpu/linux-x86_64}" # gitignored; .so's land here

mkdir -p "$WORK" "$OUT"

TGZ="$WORK/${SLUG}.tgz"
if [ ! -f "$TGZ" ]; then
    echo "=== downloading $URL ==="
    curl -sL --fail -o "$TGZ" "$URL"
fi

EXTRACT="$WORK/extracted"
rm -rf "$EXTRACT" && mkdir -p "$EXTRACT"
tar -xzf "$TGZ" -C "$EXTRACT"
SRC="$EXTRACT/$SLUG"

# --- shared libs: same SONAME convention as the CPU build (real file named
# `.so.1`, plus a `.so` symlink for the linker's `-lonnxruntime`). The two
# provider libs sit alongside and are dlopened by the runtime at session
# creation when the CUDA EP is appended. ---
REALSO="$(readlink -f "$SRC/lib/libonnxruntime.so" 2>/dev/null || echo "$SRC/lib/libonnxruntime.so.${ONNXRUNTIME_VERSION}")"
[ -f "$REALSO" ] || { echo "FATAL: no libonnxruntime.so in $SRC/lib" >&2; exit 1; }
cp "$REALSO" "$OUT/libonnxruntime.so.1"
ln -sf libonnxruntime.so.1 "$OUT/libonnxruntime.so"
for f in libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so; do
    [ -f "$SRC/lib/$f" ] || { echo "FATAL: no $f in $SRC/lib" >&2; exit 1; }
    cp "$SRC/lib/$f" "$OUT/$f"
done
# Publishable asset names (arch-tagged), mirroring the CPU script — the CLI's
# OnnxRuntimeLinuxGpuArtifact downloads these directly.
cp -f "$OUT/libonnxruntime.so.1" "$OUT/libonnxruntime-linux-x86_64-gpu.so"

echo
echo "=== files ==="
for f in libonnxruntime.so.1 libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so; do
    echo "$OUT/$f ($(du -h "$OUT/$f" | cut -f1))"
done
echo
echo "=== publishable asset checksums (sha256; pin into OnnxRuntimeLinuxGpuArtifact.swift) ==="
for f in libonnxruntime-linux-x86_64-gpu.so libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so; do
    printf '%s: ' "$f"
    shasum -a 256 "$OUT/$f" | awk '{print $1}'
done
