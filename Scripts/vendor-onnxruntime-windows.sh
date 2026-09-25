#!/usr/bin/env bash
#
# Vendor the ONNX Runtime **Windows** (x64 or arm64) C API from Microsoft's official
# prebuilt release for the desktop `MobileSAMBackend` (ai.vision.*). The
# Windows analogue of Scripts/vendor-onnxruntime-linux.sh — same CPU build,
# same committed-headers + fetched-lib split. Windows needs **two** files
# (unlike Linux's single `.so`): the import lib `onnxruntime.lib` at link time
# (staged on the `LIB` env path, mirroring llama's `LIB` mechanism) and the
# runtime `onnxruntime.dll` next to the built `.exe`.
#
# Runs on any host — download + unzip is platform-independent; only the link
# against `onnxruntime.lib` needs a Windows host.
#
# Usage:
#   [ARCH=x64|arm64] Scripts/vendor-onnxruntime-windows.sh [version]
#
# arm64's publishable assets carry an `-arm64` suffix; x64's keep the plain
# names they first shipped under, which older swift-pwa releases pin.
#
# Requires: curl, unzip, shasum.
set -euo pipefail

ONNXRUNTIME_VERSION="${1:-1.29.0}"
ARCH="${ARCH:-x64}"
case "$ARCH" in
    x64) ARCH_DIR="windows-x86_64"; ASSET_SUFFIX="" ;;
    arm64) ARCH_DIR="windows-arm64"; ASSET_SUFFIX="-arm64" ;;
    *) echo "unknown arch '$ARCH' (x64 or arm64)" >&2; exit 2 ;;
esac
SLUG="onnxruntime-win-${ARCH}-${ONNXRUNTIME_VERSION}"
URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/${SLUG}.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/onnxruntime-windows-$ARCH}"
OUT="${OUT:-$ROOT/Vendor/onnxruntime-desktop/$ARCH_DIR}"          # gitignored; dll/lib land here
HEADERS_OUT="${HEADERS_OUT:-$ROOT/Vendor/onnxruntime-desktop-headers}" # COMMITTED (shared with the linux script)

mkdir -p "$WORK" "$OUT"

ZIP="$WORK/${SLUG}.zip"
if [ ! -f "$ZIP" ]; then
    echo "=== downloading $URL ==="
    curl -sL --fail -o "$ZIP" "$URL"
fi

EXTRACT="$WORK/extracted"
rm -rf "$EXTRACT" && mkdir -p "$EXTRACT"
unzip -q "$ZIP" -d "$EXTRACT"
SRC="$EXTRACT/$SLUG"

# --- headers: this script OWNS the committed
# `Vendor/onnxruntime-desktop-headers/` set that both desktop platforms compile
# against (module ONNXRuntimeDesktop). The Linux release declares the same API
# but isn't byte-identical (LF vs CRLF, and it drops the training headers), so
# only one release can own the directory — this one, because it's what is
# committed today. Scripts/vendor-onnxruntime-linux.sh leaves it alone. ---
rm -rf "$HEADERS_OUT" && mkdir -p "$HEADERS_OUT"
cp "$SRC"/include/*.h "$HEADERS_OUT/"
cat > "$HEADERS_OUT/module.modulemap" <<'EOF'
module ONNXRuntimeDesktop {
    header "onnxruntime_c_api.h"
    header "cpu_provider_factory.h"
    export *
}
EOF

# --- link-time import lib + runtime DLL ---
for f in onnxruntime.lib onnxruntime.dll; do
    [ -f "$SRC/lib/$f" ] || { echo "FATAL: no $f in $SRC/lib" >&2; exit 1; }
    cp "$SRC/lib/$f" "$OUT/$f"
    echo "=== wrote $OUT/$f ($(du -h "$OUT/$f" | cut -f1)) ==="
done

# Publishable copies carry the ONNX Runtime version in their names, so a bump
# adds assets to the release instead of replacing the ones older swift-pwa
# versions pin by checksum. The local (unversioned) copies above are what the
# linker and the bundler consume.
for ext in lib dll; do
    cp -f "$OUT/onnxruntime.$ext" "$OUT/onnxruntime-${ONNXRUNTIME_VERSION}${ASSET_SUFFIX}.$ext"
done

echo
echo "=== publishable asset checksums (sha256; pin into OnnxRuntimeWindowsArtifact.swift) ==="
for ext in lib dll; do
    f="onnxruntime-${ONNXRUNTIME_VERSION}${ASSET_SUFFIX}.$ext"
    printf '%s: ' "$f"
    shasum -a 256 "$OUT/$f" | awk '{print $1}'
done
