#!/usr/bin/env bash
#
# Repackage Microsoft's official ONNX Runtime Apple distribution into the
# flat static-lib + headers xcframework shape `SwiftPWAONNXRuntimeSmoke`
# (and, later, a real segmentation backend) consumes via `.binaryTarget` —
# the SWIFT_PWA_ONNXRUNTIME-gated block in Package.swift. Mirrors
# Scripts/build-llama-xcframework.sh's role for llama.cpp.
#
# Why repackage instead of vendoring Microsoft's zip as-is: their artifact
# ships each platform slice as a versioned `.framework` *bundle*
# (Headers/Modules/Versions/…) with no `Modules/module.modulemap`, so Swift
# can't `import onnxruntime` out of the box — and despite the bundle
# wrapping, the actual `onnxruntime` binary inside is a plain static
# archive (`ar` format, confirmed via `file`/`otool -D`), not a dylib. So
# rather than hand-patch Microsoft's bundle layout, we extract the static
# lib + headers from each slice and hand them to `xcodebuild
# -create-xcframework -library -headers` — the same library-type
# xcframework shape llama.cpp already uses, with our own `module.modulemap`
# (named `ONNXRuntime`, matching the SwiftPM target) covering the C API
# headers a segmentation backend needs (core + CPU + CoreML EP).
#
# Usage:
#   Scripts/vendor-onnxruntime-apple.sh [version]
# `version` defaults to the pin below. Downloads Microsoft's per-version pod
# archive from download.onnxruntime.ai (the same artifact
# microsoft/onnxruntime-swift-package-manager vendors internally — there is
# no GitHub Release asset for the Apple build), verifies nothing but its own
# internal structure (the URL has no independent immutability guarantee;
# the checksum pinned in Package.swift against OUR repackaged output is the
# real trust anchor), and writes Vendor/onnxruntime/onnxruntime.xcframework.
#
# Requires: Xcode command line tools (xcodebuild, libtool not needed —
# Microsoft's binary is already a combined per-slice universal archive).
set -euo pipefail

ONNXRUNTIME_VERSION="${1:-1.27.0}"
POD_URL="https://download.onnxruntime.ai/pod-archive-onnxruntime-c-${ONNXRUNTIME_VERSION}.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/onnxruntime-xcframework}"
OUT="${OUT:-$ROOT/Vendor/onnxruntime}"

# Apple's official artifact only ships these three slices (no macOS
# Catalyst, no watchOS/tvOS) — matches what MobileSAM on Apple needs
# (device + simulator for development, macOS for `swift test`/desktop).
SLICES=(macos-arm64_x86_64 ios-arm64 ios-arm64_x86_64-simulator)

mkdir -p "$WORK"
POD_ZIP="$WORK/pod-archive-onnxruntime-c-${ONNXRUNTIME_VERSION}.zip"
if [ ! -f "$POD_ZIP" ]; then
    echo "=== downloading $POD_URL ==="
    curl -sL --fail -o "$POD_ZIP" "$POD_URL"
fi
echo "checksum of the downloaded pod archive (for your own records, not pinned anywhere):"
shasum -a 256 "$POD_ZIP"

EXTRACT="$WORK/extracted"
rm -rf "$EXTRACT" && mkdir -p "$EXTRACT"
unzip -q "$POD_ZIP" -d "$EXTRACT"

# --- headers: flatten once (identical across slices), write our own module map ---
HEADERS="$WORK/headers"
rm -rf "$HEADERS" && mkdir -p "$HEADERS"
cp "$EXTRACT"/Headers/*.h "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'EOF'
module ONNXRuntime {
    header "onnxruntime_c_api.h"
    header "cpu_provider_factory.h"
    header "coreml_provider_factory.h"
    export *
}
EOF

# --- extract each slice's static archive out of its .framework bundle ---
CREATE_ARGS=()
for slice in "${SLICES[@]}"; do
    fw="$EXTRACT/onnxruntime.xcframework/$slice/onnxruntime.framework"
    # macOS slices are versioned bundles (Versions/A/onnxruntime); iOS
    # device/simulator slices are flat (onnxruntime.framework/onnxruntime).
    bin="$fw/Versions/A/onnxruntime"
    [ -f "$bin" ] || bin="$fw/onnxruntime"
    [ -f "$bin" ] || { echo "no binary found for slice $slice at $fw" >&2; exit 1; }

    file_type="$(file -b "$bin")"
    case "$file_type" in
        *"ar archive"*) ;; # expected: a static archive, not a dylib
        *) echo "unexpected binary format for $slice: $file_type" >&2; exit 1 ;;
    esac

    mkdir -p "$WORK/lib-$slice"
    cp "$bin" "$WORK/lib-$slice/libonnxruntime.a"
    CREATE_ARGS+=(-library "$WORK/lib-$slice/libonnxruntime.a" -headers "$HEADERS")
done

rm -rf "$OUT/onnxruntime.xcframework"
mkdir -p "$OUT"
xcrun xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "$OUT/onnxruntime.xcframework"

echo "=== wrote $OUT/onnxruntime.xcframework (slices: ${SLICES[*]}) ==="
( cd "$OUT" && zip -q -r -X onnxruntime.xcframework.zip onnxruntime.xcframework )
echo "checksum to pin in Package.swift (once this zip is published as a release asset):"
swift package compute-checksum "$OUT/onnxruntime.xcframework.zip" 2>/dev/null || shasum -a 256 "$OUT/onnxruntime.xcframework.zip"
