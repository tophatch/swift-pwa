#!/usr/bin/env bash
#
# Vendor the ONNX Runtime **Windows x64 DirectML** build for the desktop
# `MobileSAMBackend` when `ai.onnx_gpu` is set (see
# docs/proposals/onnx-gpu-execution-providers.md). The GPU analogue of
# Scripts/vendor-onnxruntime-windows.sh, but the source is a **NuGet package**,
# not a GitHub release: DirectML is not published as a release asset (the
# release `-gpu_cuda*` Windows zips are CUDA, i.e. NVIDIA-only). DirectML is the
# cross-vendor choice — any DX12 GPU (NVIDIA/AMD/Intel), no external runtime
# dependency (DirectML is in-box on Windows 10+), and verifiable on our AMD
# Radeon box.
#
# Two NuGet packages:
#   Microsoft.ML.OnnxRuntime.DirectML  — the DirectML ORT build:
#       runtimes/win-x64/native/{onnxruntime.dll, onnxruntime.lib,
#       onnxruntime_providers_shared.dll} + build/native/include/*.h
#   Microsoft.AI.DirectML              — a dependency, ships bin/x64-win/DirectML.dll
#
# The DirectML NuGet's latest is **1.24.4**, which LAGS the CPU/CUDA desktop
# build's 1.27.0 — its headers declare `ORT_API_VERSION 24`, so requesting the
# 1.27 header's version 27 from a 1.24.4 runtime would make
# `OrtGetApiBase()->GetApi()` return null and crash. This script therefore
# writes a SEPARATE committed header set + module (ONNXRuntimeDirectML) matched
# to the 1.24.4 runtime, kept apart from the shared 1.27 ONNXRuntimeDesktop set.
# `dml_provider_factory.h` (for `OrtSessionOptionsAppendExecutionProvider_DML`)
# ships only in this DirectML package.
#
# Usage:
#   Scripts/vendor-onnxruntime-windows-directml.sh [ort_dml_version] [dml_redist_version]
# Requires: curl, unzip, shasum. Runs on any host (only the link/run needs Windows).
set -euo pipefail

ORT_DML_VERSION="${1:-1.24.4}"
DML_REDIST_VERSION="${2:-1.15.4}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/onnxruntime-directml}"
OUT="${OUT:-$ROOT/Vendor/onnxruntime-desktop-gpu/windows-x86_64}"          # gitignored; dll/lib land here
HEADERS_OUT="${HEADERS_OUT:-$ROOT/Vendor/onnxruntime-directml-headers}"    # COMMITTED (module ONNXRuntimeDirectML)

mkdir -p "$WORK" "$OUT"

fetch_nupkg() { # id version -> extracted dir
    local id="$1" ver="$2" lower dir
    lower="$(echo "$id" | tr '[:upper:]' '[:lower:]')"
    dir="$WORK/${lower}.${ver}"
    if [ ! -d "$dir" ]; then
        local pkg="$WORK/${lower}.${ver}.nupkg"
        [ -f "$pkg" ] || { echo "=== downloading $id $ver ==="; \
            curl -sL --fail -o "$pkg" \
            "https://api.nuget.org/v3-flatcontainer/${lower}/${ver}/${lower}.${ver}.nupkg"; }
        mkdir -p "$dir" && unzip -oq "$pkg" -d "$dir"
    fi
    echo "$dir"
}

ORT_DIR="$(fetch_nupkg Microsoft.ML.OnnxRuntime.DirectML "$ORT_DML_VERSION")"
DML_DIR="$(fetch_nupkg Microsoft.AI.DirectML "$DML_REDIST_VERSION")"

# --- committed headers (1.24.4, ORT_API_VERSION 24), separate module ---
INC="$ORT_DIR/build/native/include"
[ -f "$INC/dml_provider_factory.h" ] || { echo "FATAL: no dml_provider_factory.h in $INC" >&2; exit 1; }
rm -rf "$HEADERS_OUT" && mkdir -p "$HEADERS_OUT"
cp "$INC"/*.h "$HEADERS_OUT/"
cat > "$HEADERS_OUT/module.modulemap" <<'EOF'
module ONNXRuntimeDirectML {
    header "onnxruntime_c_api.h"
    header "cpu_provider_factory.h"
    header "dml_provider_factory.h"
    export *
}
EOF

# --- link-time import lib + runtime DLLs (staged next to the .exe by
# WindowsBundler): the DirectML onnxruntime.dll, the shared-provider bridge,
# and DirectML.dll (the x64-win redist — NOT the xbox-scarlett variants). ---
cp "$ORT_DIR/runtimes/win-x64/native/onnxruntime.lib" "$OUT/onnxruntime.lib"
cp "$ORT_DIR/runtimes/win-x64/native/onnxruntime.dll" "$OUT/onnxruntime.dll"
cp "$ORT_DIR/runtimes/win-x64/native/onnxruntime_providers_shared.dll" "$OUT/onnxruntime_providers_shared.dll"
cp "$DML_DIR/bin/x64-win/DirectML.dll" "$OUT/DirectML.dll"

echo
echo "=== files ==="
for f in onnxruntime.lib onnxruntime.dll onnxruntime_providers_shared.dll DirectML.dll; do
    echo "$OUT/$f ($(du -h "$OUT/$f" | cut -f1))"
done
echo
echo "=== publishable asset checksums (sha256; pin into OnnxRuntimeWindowsDirectMLArtifact.swift) ==="
for f in onnxruntime.lib onnxruntime.dll onnxruntime_providers_shared.dll DirectML.dll; do
    printf '%s: ' "$f"
    shasum -a 256 "$OUT/$f" | awk '{print $1}'
done
