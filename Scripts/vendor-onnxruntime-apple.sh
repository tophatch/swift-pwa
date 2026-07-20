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
# lib + headers from each slice and re-wrap them in a **framework-style**
# xcframework (a static `ONNXRuntime.framework` per slice, with our own
# `Modules/module.modulemap` named `ONNXRuntime` covering the C API headers a
# segmentation backend needs — core + CPU + CoreML EP). Framework style (not
# `-library -headers`) so this can coexist with llama's `CLlama` xcframework in
# one iOS build — see docs/proposals/dual-xcframework-ios-collision.md and the
# make_framework note below.
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

# --- headers: flatten once (identical across slices) ---
HEADERS="$WORK/headers"
rm -rf "$HEADERS" && mkdir -p "$HEADERS"
cp "$EXTRACT"/Headers/*.h "$HEADERS/"

# Assemble a **framework-style** slice: a static `ONNXRuntime.framework` whose
# module map lives *inside* the bundle (Modules/module.modulemap). This matters
# when an app links BOTH this and llama's `CLlama` xcframework for iOS: a plain
# `-library -headers` xcframework drops its `module.modulemap` at the shared
# `Build/Products/<cfg>/include/` root, and two of them collide with
# "Multiple commands produce include/module.modulemap". Framework xcframeworks
# are never flattened into that shared include/, so they coexist. The module map
# lists the C-API headers explicitly (an `umbrella` map would drag in the C++
# headers — onnxruntime_float16.h → <cmath> — and fail to compile as a C module).
# See docs/proposals/dual-xcframework-ios-collision.md.
make_framework() {
    local lib="$1"
    local fw="$2"
    rm -rf "$fw"
    mkdir -p "$fw/Headers" "$fw/Modules"
    cp "$HEADERS"/*.h "$fw/Headers/"
    cp "$lib" "$fw/ONNXRuntime"
    cat > "$fw/Modules/module.modulemap" <<'EOF'
framework module ONNXRuntime {
    header "onnxruntime_c_api.h"
    header "cpu_provider_factory.h"
    header "coreml_provider_factory.h"
    export *
}
EOF
    cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ONNXRuntime</string>
  <key>CFBundleIdentifier</key><string>ai.onnxruntime.ONNXRuntime</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ONNXRuntime</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${ONNXRUNTIME_VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>13.0</string>
</dict></plist>
EOF
}

# --- extract each slice's static archive, wrap it in a framework ---
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
    make_framework "$WORK/lib-$slice/libonnxruntime.a" "$WORK/fw-$slice/ONNXRuntime.framework"
    CREATE_ARGS+=(-framework "$WORK/fw-$slice/ONNXRuntime.framework")
done

rm -rf "$OUT/onnxruntime.xcframework"
mkdir -p "$OUT"
xcrun xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "$OUT/onnxruntime.xcframework"

echo "=== wrote $OUT/onnxruntime.xcframework (slices: ${SLICES[*]}) ==="
( cd "$OUT" && zip -q -r -X onnxruntime.xcframework.zip onnxruntime.xcframework )
echo "checksum to pin in Package.swift (once this zip is published as a release asset):"
swift package compute-checksum "$OUT/onnxruntime.xcframework.zip" 2>/dev/null || shasum -a 256 "$OUT/onnxruntime.xcframework.zip"
