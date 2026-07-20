#!/usr/bin/env bash
#
# Build the llama.cpp Apple xcframework that `SwiftPWALlama` consumes via
# `.binaryTarget`. This is the maintained artifact behind the
# `ai.local_llama` pwa.json flag: CI builds it from a pinned llama.cpp commit,
# attaches the zipped xcframework + its SHA-256 to the swift-pwa GitHub
# release, and `Package.swift` references it (url + checksum) when
# `SWIFT_PWA_LLAMA=1` is set.
#
# We don't hand-vendor ggml/llama source: it's 135+ per-arch model files, a
# C++/ObjC Metal backend with a shader-embed step, and per-file SIMD flags that
# SwiftPM can't express (and `unsafeFlags` would poison dependency resolution
# for every adopter). CMake does all of that correctly; we package its output.
#
# Usage:
#   Scripts/build-llama-xcframework.sh [platforms...]
# Platforms default to "macos ios ios-sim" (what we ship). Pass a subset to
# build faster locally, e.g. `Scripts/build-llama-xcframework.sh macos`.
#
# Requires: cmake >= 3.28, Xcode + command line tools.
set -euo pipefail

# Pinned llama.cpp commit — bump deliberately, re-test, re-pin the checksum in
# Package.swift. (ggml 0.15.2 as of this pin.)
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_COMMIT="${LLAMA_COMMIT:-5a6a0dd}"

IOS_MIN="16.4"
MACOS_MIN="13.3"

PLATFORMS=("$@")
if [ ${#PLATFORMS[@]} -eq 0 ]; then
    PLATFORMS=(macos ios ios-sim)
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/llama-xcframework}"
OUT="${OUT:-$ROOT/Vendor/llama}"
SRC="$WORK/llama.cpp"

mkdir -p "$WORK"

# --- fetch pinned source ---
if [ ! -d "$SRC/.git" ]; then
    git clone "$LLAMA_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$LLAMA_COMMIT" 2>/dev/null || git -C "$SRC" fetch origin
git -C "$SRC" checkout -q "$LLAMA_COMMIT"

# Shared CMake options — no examples/tools/server, Metal embedded so the lib is
# self-contained, GGML_NATIVE off so each slice is portable across that arch.
COMMON_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_OPENMP=OFF
    -DGGML_NATIVE=OFF
    # Build every requested arch, not just the host's — without this the Xcode
    # generator honors ONLY_ACTIVE_ARCH and a "universal" slice comes out thin.
    -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO
    # Static libs aren't signed, but the iOS device slice's Xcode project still
    # trips over code-signing without a team — disable it (matches upstream's
    # build-xcframework.sh).
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DLLAMA_BUILD_COMMON=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_APP=OFF
)

configure_slice() {
    local slice="$1"; shift
    cmake -B "$WORK/build-$slice" -G Xcode -S "$SRC" "${COMMON_ARGS[@]}" "$@"
}

case_for() {
    # Echoes the extra cmake args for a slice.
    case "$1" in
        macos)   echo "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN -DCMAKE_OSX_ARCHITECTURES=arm64;x86_64" ;;
        ios)     echo "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DCMAKE_OSX_ARCHITECTURES=arm64" ;;
        ios-sim) echo "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DCMAKE_OSX_ARCHITECTURES=arm64;x86_64" ;;
        *) echo "unknown platform: $1" >&2; exit 1 ;;
    esac
}

# Combine a slice's static libs into one archive create-xcframework accepts.
combine_slice() {
    local slice="$1"
    local bdir="$WORK/build-$slice"
    local libs=()
    for name in libllama.a libggml.a libggml-cpu.a libggml-metal.a libggml-blas.a libggml-base.a; do
        local found
        # Pick the final (universal) product under `.../Release*/`, NOT the
        # per-arch `Objects-normal/<arch>/Binary/` intermediates the Xcode
        # generator also leaves around — matching one of those yields a thin
        # slice and silently drops x86_64. (Don't filter on `.build` here: the
        # default WORK dir is `$ROOT/.build/llama-xcframework`, so the whole
        # path contains `.build/` and such a filter would exclude everything —
        # the `Objects-normal` exclusion alone skips the thin intermediates.)
        found="$(find "$bdir" -name "$name" -path '*Release*' -not -path '*Objects-normal*' | head -1)"
        [ -z "$found" ] && found="$(find "$bdir" -name "$name" -not -path '*Objects-normal*' | head -1)"
        [ -z "$found" ] && { echo "missing $name for $slice" >&2; exit 1; }
        libs+=("$found")
    done
    # Name the combined archive `libllama.a` (SwiftPM rejects xcframework
    # static libs whose basename isn't `lib`-prefixed) in a per-slice dir so
    # the three slices don't collide.
    mkdir -p "$WORK/combined-$slice"
    libtool -static -o "$WORK/combined-$slice/libllama.a" "${libs[@]}" 2>/dev/null
}

# --- headers (llama + ggml public headers, flattened) — built before the
# per-slice frameworks that embed them ---
rm -rf "$WORK/headers" && mkdir -p "$WORK/headers"
cp "$SRC/include/llama.h" "$SRC/include/llama-cpp.h" "$SRC"/ggml/include/*.h "$WORK/headers/"

# Wrap each slice's static archive in a static `CLlama.framework` whose module
# map lives *inside* the bundle (Modules/module.modulemap). Framework style (not
# `-library -headers`) so CLlama can coexist with the ONNXRuntime xcframework in
# one iOS build: a `-library -headers` xcframework drops its `module.modulemap`
# at the shared `Build/Products/<cfg>/include/` root, and two of them collide
# ("Multiple commands produce include/module.modulemap"). Framework xcframeworks
# are never flattened into that shared include/. The module map lists the C
# header explicitly (llama.h); an `umbrella` map would drag in the C++ headers
# (ggml-cpp.h → <memory>) and fail to compile as a C module. See
# docs/proposals/dual-xcframework-ios-collision.md.
make_framework() {
    local slice="$1"
    local fw="$WORK/fw-$slice/CLlama.framework"
    rm -rf "$fw"
    mkdir -p "$fw/Headers" "$fw/Modules"
    cp "$WORK/headers"/*.h "$fw/Headers/"
    cp "$WORK/combined-$slice/libllama.a" "$fw/CLlama"
    cat > "$fw/Modules/module.modulemap" <<'EOF'
framework module CLlama {
    header "llama.h"
    export *
}
EOF
    cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CLlama</string>
  <key>CFBundleIdentifier</key><string>org.ggml.CLlama</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>CLlama</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$IOS_MIN</string>
</dict></plist>
EOF
}

CREATE_ARGS=()
for slice in "${PLATFORMS[@]}"; do
    echo "=== building slice: $slice ==="
    # shellcheck disable=SC2046
    configure_slice "$slice" $(case_for "$slice")
    cmake --build "$WORK/build-$slice" --config Release -j "$(sysctl -n hw.logicalcpu)" -- -quiet
    combine_slice "$slice"
    make_framework "$slice"
    CREATE_ARGS+=(-framework "$WORK/fw-$slice/CLlama.framework")
done

# --- assemble the xcframework ---
rm -rf "$OUT/llama.xcframework"
mkdir -p "$OUT"
xcrun xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "$OUT/llama.xcframework"

echo "=== wrote $OUT/llama.xcframework (slices: ${PLATFORMS[*]}) ==="
# Zip + checksum for release hosting (consumed by Package.swift url+checksum).
( cd "$OUT" && zip -q -r -X llama.xcframework.zip llama.xcframework )
echo "checksum (swift package compute-checksum):"
swift package compute-checksum "$OUT/llama.xcframework.zip" 2>/dev/null || shasum -a 256 "$OUT/llama.xcframework.zip"
