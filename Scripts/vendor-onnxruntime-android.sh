#!/usr/bin/env bash
#
# Vendor the ONNX Runtime **Android** C API from Microsoft's official Maven
# artifact for `SwiftPWAONNXRuntimeAndroidSmoke` (and, later, a real
# segmentation backend) to link via a `.systemLibrary` — the
# `SWIFT_PWA_ONNXRUNTIME`-gated block in Package.swift. The Android
# analogue of Scripts/vendor-onnxruntime-apple.sh; the off-Apple linking
# story otherwise mirrors `Scripts/build-llama-linux.sh` (headers committed,
# the actual prebuilt lib fetched separately and pointed to via a search-path
# env var at link time — `LIBRARY_PATH`, the same one Linux already uses;
# clang's cross-Android linker driver honors it exactly like the host one).
#
# Unlike llama.cpp (built from source per-platform), ONNX Runtime already
# ships a prebuilt Android artifact: the `onnxruntime-android` AAR on Maven
# Central. An AAR is just a zip — it bundles the plain C API headers
# (`onnxruntime_c_api.h` etc.) directly (no Java/JNI glue involvement
# needed) plus a `libonnxruntime.so` **per ABI** under `jni/<abi>/` — that's
# the C-API shared lib we link; each ABI dir also ships
# `libonnxruntime4j_jni.so` (Microsoft's own Java/Kotlin JNI bindings),
# which we don't use and don't vendor.
#
# Usage:
#   Scripts/vendor-onnxruntime-android.sh [version] [abis...]
# `version` defaults to the pin below. `abis` defaults to `arm64-v8a` only —
# matching this repo's existing Android device-verification practice
# (Fold7 / Tab S10+, both arm64-v8a); pass more (`armeabi-v7a`, `x86_64`,
# `x86`) if you need emulator or 32-bit device coverage.
#
# Requires: curl, unzip, shasum (all standard on macOS/Linux CI hosts).
set -euo pipefail

ONNXRUNTIME_VERSION="${1:-1.27.0}"
shift || true
ABIS=("$@")
if [ ${#ABIS[@]} -eq 0 ]; then
    ABIS=(arm64-v8a)
fi

MAVEN_BASE="https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/${ONNXRUNTIME_VERSION}"
AAR_URL="${MAVEN_BASE}/onnxruntime-android-${ONNXRUNTIME_VERSION}.aar"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/onnxruntime-android}"
OUT="${OUT:-$ROOT/Vendor/onnxruntime-android}"                    # gitignored; .so files land here
HEADERS_OUT="${HEADERS_OUT:-$ROOT/Vendor/onnxruntime-android-headers}" # COMMITTED (Package.swift systemLibrary)

mkdir -p "$WORK" "$OUT"

AAR="$WORK/onnxruntime-android-${ONNXRUNTIME_VERSION}.aar"
if [ ! -f "$AAR" ]; then
    echo "=== downloading $AAR_URL ==="
    curl -sL --fail -o "$AAR" "$AAR_URL"
fi

# Maven Central publishes a SHA-1 sidecar per artifact (its own integrity
# convention — not SHA-256, unlike this repo's other pinned checksums).
# Verify against it before trusting the download; the SHA-256 we print at
# the end (of the vendored .so, not the AAR) is what actually gets pinned
# for a future CLI-side fetch, matching Scripts/build-llama-linux.sh.
echo "=== verifying against Maven's published sha1 ==="
WANT_SHA1="$(curl -sL --fail "${AAR_URL}.sha1")"
GOT_SHA1="$(shasum -a 1 "$AAR" | awk '{print $1}')"
if [ "$WANT_SHA1" != "$GOT_SHA1" ]; then
    echo "FATAL: sha1 mismatch for $AAR (expected $WANT_SHA1, got $GOT_SHA1)" >&2
    exit 1
fi
echo "sha1 OK: $GOT_SHA1"

EXTRACT="$WORK/extracted"
rm -rf "$EXTRACT" && mkdir -p "$EXTRACT"
unzip -q "$AAR" -d "$EXTRACT"

# --- headers: ALL of the AAR's headers (onnxruntime_c_api.h #includes a few
# more, e.g. onnxruntime_ep_c_api.h, that aren't part of the public module
# surface but must still resolve), with our own module map naming the
# public surface. ---
rm -rf "$HEADERS_OUT" && mkdir -p "$HEADERS_OUT"
cp "$EXTRACT"/headers/*.h "$HEADERS_OUT/"
cat > "$HEADERS_OUT/module.modulemap" <<'EOF'
module ONNXRuntimeAndroid {
    header "onnxruntime_c_api.h"
    header "cpu_provider_factory.h"
    header "nnapi_provider_factory.h"
    export *
}
EOF

# --- per-ABI shared lib: just the C-API .so, not Microsoft's JNI glue ---
for abi in "${ABIS[@]}"; do
    src="$EXTRACT/jni/$abi/libonnxruntime.so"
    [ -f "$src" ] || { echo "FATAL: no libonnxruntime.so for ABI $abi in the AAR" >&2; exit 1; }
    mkdir -p "$OUT/$abi"
    cp "$src" "$OUT/$abi/libonnxruntime.so"
    echo "=== wrote $OUT/$abi/libonnxruntime.so ($(du -h "$src" | cut -f1)) ==="

    # The publishable asset: the raw .so renamed per-ABI (mirroring
    # build-llama-linux.sh's `libllama-linux-$ARCH.a` convention) — the CLI
    # (once it has an Android artifact resolver, LlamaLinuxArtifact-style)
    # downloads this directly and verifies its SHA-256, no archive/unzip
    # dependency needed.
    cp -f "$OUT/$abi/libonnxruntime.so" "$OUT/libonnxruntime-android-$abi.so"
done

echo
echo "=== publishable asset checksums (sha256; for a future CLI-side fetch, see LlamaLinuxArtifact.swift for the pattern) ==="
for abi in "${ABIS[@]}"; do
    printf '%s: ' "$abi"
    shasum -a 256 "$OUT/libonnxruntime-android-$abi.so" | awk '{print $1}'
done
