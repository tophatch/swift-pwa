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
        found="$(find "$bdir" -name "$name" -path '*Release*' | head -1)"
        [ -z "$found" ] && found="$(find "$bdir" -name "$name" | head -1)"
        [ -z "$found" ] && { echo "missing $name for $slice" >&2; exit 1; }
        libs+=("$found")
    done
    libtool -static -o "$WORK/$slice-combined.a" "${libs[@]}" 2>/dev/null
}

CREATE_ARGS=()
for slice in "${PLATFORMS[@]}"; do
    echo "=== building slice: $slice ==="
    # shellcheck disable=SC2046
    configure_slice "$slice" $(case_for "$slice")
    cmake --build "$WORK/build-$slice" --config Release -j "$(sysctl -n hw.logicalcpu)" -- -quiet
    combine_slice "$slice"
    CREATE_ARGS+=(-library "$WORK/$slice-combined.a" -headers "$WORK/headers")
done

# --- headers (llama + ggml public headers, flattened, with a module map) ---
rm -rf "$WORK/headers" && mkdir -p "$WORK/headers"
cp "$SRC/include/llama.h" "$SRC/include/llama-cpp.h" "$SRC"/ggml/include/*.h "$WORK/headers/"
cat > "$WORK/headers/module.modulemap" <<'EOF'
module CLlama {
    header "llama.h"
    export *
}
EOF

# --- assemble the xcframework ---
rm -rf "$OUT/llama.xcframework"
mkdir -p "$OUT"
xcrun xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "$OUT/llama.xcframework"

echo "=== wrote $OUT/llama.xcframework (slices: ${PLATFORMS[*]}) ==="
# Zip + checksum for release hosting (consumed by Package.swift url+checksum).
( cd "$OUT" && zip -q -r -X llama.xcframework.zip llama.xcframework )
echo "checksum (swift package compute-checksum):"
swift package compute-checksum "$OUT/llama.xcframework.zip" 2>/dev/null || shasum -a 256 "$OUT/llama.xcframework.zip"
