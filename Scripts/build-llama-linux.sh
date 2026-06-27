#!/usr/bin/env bash
#
# Build the llama.cpp Linux static lib (Vulkan GPU backend) that `SwiftPWALlama`
# links on Linux. The off-Apple analogue of build-llama-xcframework.sh: CI builds
# it from the same pinned llama.cpp commit, publishes the zipped `libllama.a` +
# its SHA-256 to a stable release, and the CLI downloads + extracts it and points
# `LIBRARY_PATH` at it for the `swift build` (Package.swift links `-lllama` via
# `.linkedLibrary` — NO `unsafeFlags`, which would poison dependency resolution).
#
# Unlike Apple's Metal slice, the GPU backend is **Vulkan** (GGML_VULKAN=ON): one
# artifact covers NVIDIA + AMD + Intel via the driver's Vulkan ICD, with CPU
# fallback. The compute shaders are compiled to SPIR-V at build (glslc) and
# embedded in the static lib, so the only runtime dependency is the Vulkan loader
# (`libvulkan.so.1`), which the GPU driver provides.
#
# Usage:
#   Scripts/build-llama-linux.sh            # build + refresh Vendor/llama-headers
#   LLAMA_COMMIT=<sha> Scripts/build-llama-linux.sh
#
# Requires: cmake >= 3.28, a C/C++ toolchain, and the **Vulkan SDK** — system
# `libvulkan-dev` alone is NOT enough (ggml's Vulkan build needs SPIRV-Headers'
# cmake config + glslc, which the LunarG SDK provides). Point $VULKAN_SDK at it
# (e.g. `source <sdk>/setup-env.sh`) or have `glslc` on PATH.
set -euo pipefail

# Pinned llama.cpp commit — keep in lockstep with build-llama-xcframework.sh so
# the Apple xcframework and the Linux static lib expose the same ABI/headers.
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_COMMIT="${LLAMA_COMMIT:-5a6a0dd}"

ARCH="$(uname -m)" # x86_64 (only target for now)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/llama-linux}"
OUT="${OUT:-$ROOT/Vendor/llama-linux}"     # gitignored; libllama.a + zip land here
HEADERS_OUT="${HEADERS_OUT:-$ROOT/Vendor/llama-headers}" # COMMITTED (Package.swift systemLibrary)
SRC="$WORK/llama.cpp"
BUILD="$WORK/build"

mkdir -p "$WORK" "$OUT"

# --- locate the Vulkan SDK's glslc (ggml's GGML_VULKAN build needs it) ---
GLSLC="$(command -v glslc || true)"
if [ -z "$GLSLC" ] && [ -n "${VULKAN_SDK:-}" ]; then
    GLSLC="$VULKAN_SDK/bin/glslc"
fi
[ -x "$GLSLC" ] || {
    echo "FATAL: glslc not found. Install the Vulkan SDK and source its setup-env.sh," >&2
    echo "       or put glslc on PATH. (system libvulkan-dev does NOT include it.)" >&2
    exit 1
}
echo "glslc: $GLSLC"

# --- fetch pinned source ---
if [ ! -d "$SRC/.git" ]; then
    git clone "$LLAMA_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$LLAMA_COMMIT" 2>/dev/null || git -C "$SRC" fetch origin
git -C "$SRC" checkout -q "$LLAMA_COMMIT"
echo "=== llama.cpp at $(git -C "$SRC" rev-parse --short HEAD) ==="

# CMake options mirror the Apple build (no examples/tools/server/app, static,
# GGML_NATIVE off for portability) with Metal swapped for Vulkan. LLAMA_BUILD_APP
# MUST be OFF — this commit's new app/ dir needs `common` headers we don't build.
CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_VULKAN=ON
    -DGGML_OPENMP=OFF
    -DGGML_NATIVE=OFF
    -DLLAMA_BUILD_COMMON=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_APP=OFF
    -DLLAMA_CURL=OFF
    -DVulkan_GLSLC_EXECUTABLE="$GLSLC"
)
[ -n "${VULKAN_SDK:-}" ] && CMAKE_ARGS+=(-DCMAKE_PREFIX_PATH="$VULKAN_SDK")

# Reuse $BUILD across runs — the Vulkan shader compile is the slow part and cmake
# reconfigures in place when flags change.
cmake -S "$SRC" -B "$BUILD" "${CMAKE_ARGS[@]}"
cmake --build "$BUILD" --config Release -j "$(nproc)"

# Combine all static slices into one libllama.a via an ar MRI script (the GNU-ld
# analogue of Apple's `libtool -static`; proven to link with no --start-group, so
# no unsafeFlags). Exclude CMake intermediates.
COMBINED="$OUT/libllama.a"
rm -f "$COMBINED"
mapfile -t SLICES < <(find "$BUILD" -name '*.a' -not -path '*CMakeFiles*' | sort -u)
[ "${#SLICES[@]}" -gt 0 ] || { echo "FATAL: no static libs produced" >&2; exit 1; }
echo "=== combining ${#SLICES[@]} static libs ==="
printf '%s\n' "${SLICES[@]}"
{
    echo "create $COMBINED"
    for a in "${SLICES[@]}"; do echo "addlib $a"; done
    echo "save"
    echo "end"
} | ar -M
ranlib "$COMBINED"
echo "=== wrote $COMBINED ($(du -h "$COMBINED" | cut -f1)) ==="

# --- refresh committed headers (llama + ggml, flattened, with a module map) ---
rm -rf "$HEADERS_OUT" && mkdir -p "$HEADERS_OUT"
cp "$SRC/include/llama.h" "$SRC/include/llama-cpp.h" "$SRC"/ggml/include/*.h "$HEADERS_OUT/"
cat > "$HEADERS_OUT/module.modulemap" <<'EOF'
module CLlama {
    header "llama.h"
    export *
}
EOF

# --- checksum for release hosting ---
# The publishable asset is the raw libllama.a (renamed per-arch): the CLI
# downloads it directly and verifies this SHA-256 — no client-side unzip needed,
# so the CLI carries no archive dependency. CI uploads this file to the stable
# `llama-vendor-linux-<arch>` release and sed-pins the checksum into the CLI.
ASSET="$OUT/libllama-linux-$ARCH.a"
cp -f "$COMBINED" "$ASSET"
echo "=== publishable asset: $ASSET ==="
echo "sha256:"
sha256sum "$ASSET" | awk '{print $1}'
