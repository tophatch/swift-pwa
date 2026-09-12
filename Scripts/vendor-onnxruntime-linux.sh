#!/usr/bin/env bash
#
# Vendor the ONNX Runtime **Linux x86_64** C API from Microsoft's official
# prebuilt release for the desktop `MobileSAMBackend` (ai.vision.*) to link
# via a `.systemLibrary` — the `SWIFT_PWA_ONNXRUNTIME`-gated block in
# Package.swift. The Linux analogue of Scripts/vendor-onnxruntime-android.sh:
# headers committed, the actual prebuilt `.so` fetched separately and pointed
# to via `LIBRARY_PATH` at link time (the same mechanism Scripts/build-llama-
# linux.sh uses for llama's Linux static lib).
#
# Unlike llama.cpp (built from source per-platform), ONNX Runtime already
# ships a prebuilt desktop artifact: `onnxruntime-linux-x64-<ver>.tgz` on
# Microsoft's GitHub releases. It's the **CPU** build (matching our CPU-only
# OrtModelSession — no GPU execution provider is configured anywhere in the
# backend); the GPU EP builds (CUDA/TensorRT) are a much larger, separate
# story and out of scope here.
#
# Usage:
#   Scripts/vendor-onnxruntime-linux.sh [version]
# `version` defaults to the pin below.
#
# Requires: curl, tar, shasum (all standard on macOS/Linux CI hosts). Runs on
# any host — the download + extract is platform-independent; only the *link*
# against the resulting ELF `.so` needs a Linux host.
set -euo pipefail

ONNXRUNTIME_VERSION="${1:-1.29.0}"
SLUG="onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}"
URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/${SLUG}.tgz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/onnxruntime-linux}"
OUT="${OUT:-$ROOT/Vendor/onnxruntime-desktop/linux-x86_64}"            # gitignored; .so lands here
# The committed header set (Package.swift systemLibrary) is written by
# Scripts/vendor-onnxruntime-windows.sh — see the headers block below.

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

# --- headers: NOT written here by default. The committed
# `Vendor/onnxruntime-desktop-headers/` (module ONNXRuntimeDesktop) is shared by
# Linux and Windows and is owned by Scripts/vendor-onnxruntime-windows.sh —
# the two upstream releases declare the same API but are not byte-identical
# (the Windows zip ships CRLF headers plus the training headers the Linux
# tarball drops), so whichever script ran last used to decide, and running the
# other one rewrote every line of every header for no change in meaning.
# Pass HEADERS_OUT explicitly to write the Linux set somewhere for comparison. ---
if [ -n "${HEADERS_OUT:-}" ]; then
    rm -rf "$HEADERS_OUT" && mkdir -p "$HEADERS_OUT"
    cp "$SRC"/include/*.h "$HEADERS_OUT/"
    cat > "$HEADERS_OUT/module.modulemap" <<'EOF'
module ONNXRuntimeDesktop {
    header "onnxruntime_c_api.h"
    header "cpu_provider_factory.h"
    export *
}
EOF
    echo "=== wrote headers to $HEADERS_OUT ==="
fi

# --- shared lib: the release ships lib/libonnxruntime.so.<ver> plus an
# unversioned libonnxruntime.so symlink. The lib's SONAME is
# `libonnxruntime.so.1`, so a binary linked against it records
# `libonnxruntime.so.1` as its NEEDED entry and the loader looks for exactly
# that at runtime. We therefore vendor the real file as `libonnxruntime.so.1`
# (the runtime name) plus a `libonnxruntime.so` symlink (the plain name the
# linker's `-lonnxruntime` search wants at link time). ---
REALSO="$(readlink -f "$SRC/lib/libonnxruntime.so" 2>/dev/null || echo "$SRC/lib/libonnxruntime.so.${ONNXRUNTIME_VERSION}")"
[ -f "$REALSO" ] || { echo "FATAL: no libonnxruntime.so in $SRC/lib" >&2; exit 1; }
cp "$REALSO" "$OUT/libonnxruntime.so.1"
ln -sf libonnxruntime.so.1 "$OUT/libonnxruntime.so"
echo "=== wrote $OUT/libonnxruntime.so.1 ($(du -h "$OUT/libonnxruntime.so.1" | cut -f1)) + libonnxruntime.so symlink ==="

# The publishable asset: the raw lib with an arch- and version-tagged name
# (mirroring build-llama-linux.sh's `libllama-linux-$ARCH.a`) — the CLI's
# OnnxRuntimeLinuxArtifact downloads this directly, saves it under the SONAME
# name, and re-creates the `.so` symlink. (Content is identical to the .so.1,
# so the pinned SHA-256 is unaffected by the naming.) The **version** in the
# name is what makes a bump additive: the asset sits beside its predecessor on
# the same release, so a CLI pinned to the old checksum keeps resolving.
ASSET="libonnxruntime-linux-x86_64-${ONNXRUNTIME_VERSION}.so"
cp -f "$OUT/libonnxruntime.so.1" "$OUT/$ASSET"

echo
echo "=== publishable asset checksum (sha256; pin into OnnxRuntimeLinuxArtifact.swift) ==="
echo "asset name: $ASSET"
shasum -a 256 "$OUT/$ASSET" | awk '{print $1}'
