#!/usr/bin/env bash
#
# Vendor the ONNX Runtime **Windows x64** C API from Microsoft's official
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
#   Scripts/vendor-onnxruntime-windows.sh [version]
#
# Requires: curl, unzip, shasum.
set -euo pipefail

ONNXRUNTIME_VERSION="${1:-1.27.0}"
SLUG="onnxruntime-win-x64-${ONNXRUNTIME_VERSION}"
URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/${SLUG}.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/onnxruntime-windows}"
OUT="${OUT:-$ROOT/Vendor/onnxruntime-desktop/windows-x86_64}"          # gitignored; dll/lib land here
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

# --- headers: identical to the Linux release's, so write the same committed
# dir (the two scripts are interchangeable for headers; running either is
# enough). ---
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

echo
echo "=== publishable asset checksums (sha256; pin into OnnxRuntimeWindowsArtifact.swift) ==="
for f in onnxruntime.lib onnxruntime.dll; do
    printf '%s: ' "$f"
    shasum -a 256 "$OUT/$f" | awk '{print $1}'
done
