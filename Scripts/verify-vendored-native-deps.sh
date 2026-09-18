#!/usr/bin/env bash
#
# End-to-end check that an app can vendor a native library with an API (#238).
#
# The library half (`native_library_dirs`, #220) got the `.so`/`.a` to the
# linker. The compile happens first, so a C shim's `#include <vendoredprobe.h>`
# used to stop the build at the first Swift module importing it, and the link
# step was never reached at all. This drives the shape that reported it: a C
# target whose umbrella header includes the vendored header, and a Swift call
# into the library.
#
# Two runs, and the FIRST one is the instrument's control: the same app, same
# vendored files, `native_include_dirs` removed, must fail with
# `'vendoredprobe.h' file not found`. A green control run means the header
# reached the compile some other way - a warm module cache, a global CPATH - and
# nothing the second run says can be trusted.
#
# The probe library is the SQLite amalgamation (the reported case: GRDB needs a
# SQLite the platform doesn't ship) but built and included under a name nothing
# else can provide. Its own name would make the control a lie on any box with
# libsqlite3-dev installed, which is most Linux boxes - the header would resolve
# from /usr/include and the run would report a pass it hadn't earned.
#
# Clang caches the built module across a *change of include flags*, so each run
# gets a fresh `.build`. Deleting Products or the intermediates is not enough:
# the first report of this bug looked fixed twice for exactly that reason.
#
# Usage:
#   Scripts/verify-vendored-native-deps.sh [-t android|linux] [-a <abi>]
#                                          [-s <amalgamation-dir>] [-k]
#     -t  target to verify (default: android - the target where both halves are
#         needed at once and neither environment variable survives)
#     -a  Android ABI to build (default: arm64-v8a); ignored for linux
#     -s  directory holding the SQLite amalgamation (sqlite3.c + sqlite3.h).
#         Default: the newest $HOME/Code-3p/sqlite/sqlite-amalgamation-*
#     -k  keep the scaffolded app directory for debugging
#
# On Linux, run this on the box itself (Scripts/remote-linux.sh sync puts the
# tree there), and export SWIFT_PWA_GTK4=1 on a GTK4 box.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="android"
ABI="arm64-v8a"
AMALGAMATION=""
KEEP=0
while getopts "t:a:s:k" opt; do
    case "$opt" in
        t) TARGET="$OPTARG" ;;
        a) ABI="$OPTARG" ;;
        s) AMALGAMATION="$OPTARG" ;;
        k) KEEP=1 ;;
        *) echo "usage: $0 [-t android|linux] [-a abi] [-s amalgamation-dir] [-k]" >&2; exit 2 ;;
    esac
done

case "$TARGET" in
    android|linux) ;;
    *) echo "unsupported target '$TARGET' (android, linux)" >&2; exit 2 ;;
esac
case "$ABI" in
    arm64-v8a) NDK_ARCH="aarch64"; ARCH_DIR="aarch64" ;;
    x86_64) NDK_ARCH="x86_64"; ARCH_DIR="x86_64" ;;
    *) echo "unsupported abi '$ABI' (arm64-v8a, x86_64)" >&2; exit 2 ;;
esac

if [ -z "$AMALGAMATION" ]; then
    AMALGAMATION="$(find "$HOME/Code-3p/sqlite" -maxdepth 1 -type d \
        -name 'sqlite-amalgamation-*' 2>/dev/null | sort | tail -1)"
fi
if [ -z "$AMALGAMATION" ] || [ ! -f "$AMALGAMATION/sqlite3.c" ]; then
    echo "no SQLite amalgamation found - pass -s <dir> holding sqlite3.c and sqlite3.h." >&2
    echo "Download: https://www.sqlite.org/download.html (sqlite-amalgamation-*.zip)" >&2
    exit 1
fi

# SwiftPM package fetches need this when a global git safe.bareRepository
# setting is in play; harmless otherwise.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all
# linuxdeploy self-mounts through FUSE otherwise and never returns.
export APPIMAGE_EXTRACT_AND_RUN=1

WORK="${TMPDIR:-/tmp}/swift-pwa-vendored-native-deps"
APP="VendoredDepApp"
APP_DIR="$WORK/$APP"

cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK"

# --- the vendored library, built under a name nothing else provides ----------

echo "== building the probe library =="
VENDOR="$WORK/vendor"
mkdir -p "$VENDOR/include" "$VENDOR/lib"
cp "$AMALGAMATION/sqlite3.h" "$VENDOR/include/vendoredprobe.h"
if [ "$TARGET" = "android" ]; then
    CLANG="$(ls "$HOME"/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/bin/clang 2>/dev/null | head -1)"
    if [ -z "$CLANG" ] && [ -n "${ANDROID_NDK_HOME:-}" ]; then
        CLANG="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/clang 2>/dev/null | head -1)"
    fi
    if [ -z "$CLANG" ]; then
        echo "no NDK clang found - install the NDK (see docs/android-setup.md)." >&2
        exit 1
    fi
    AR="$(dirname "$CLANG")/llvm-ar"
    NM="$(dirname "$CLANG")/llvm-nm"
    CC=("$CLANG" "--target=$NDK_ARCH-linux-android28")
else
    AR="ar"
    NM="nm"
    CC=(cc)
fi
# -fPIC: the Android product links `-shared` and a Linux executable links PIE,
# and a non-PIC archive can go into neither (the link fails with a wall of
# "relocation ... cannot be used against symbol", not one legible error).
# SQLITE_OMIT_LOAD_EXTENSION drops the dlopen path, which nothing here needs.
"${CC[@]}" -O0 -fPIC -DSQLITE_OMIT_LOAD_EXTENSION -c "$AMALGAMATION/sqlite3.c" -o "$WORK/probe.o"
"$AR" rcs "$VENDOR/lib/libvendoredprobe.a" "$WORK/probe.o"

# --- the app ----------------------------------------------------------------

echo "== building the CLI =="
(cd "$REPO" && swift build --product swift-pwa >/dev/null)
CLI="$REPO/.build/debug/swift-pwa"

echo "== scaffolding $APP =="
# A fresh `init` app, not an example: the examples carry resource declarations
# and Bundle.module fallbacks the scaffold never emits.
(cd "$WORK" && "$CLI" init "$APP" >/dev/null)

python3 - "$APP_DIR" "$REPO" <<'PY'
import pathlib, re, sys
app_dir, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
pkg = pathlib.Path(repo).name

# The scaffold pins the published release, so without this the run would verify
# the shipped backend rather than the working tree.
manifest = app_dir / "Package.swift"
text = manifest.read_text()
text = re.sub(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
              f'.package(path: "{repo}")', text)
text = text.replace('package: "swift-pwa"', f'package: "{pkg}"')

# The reported shape: a C target whose umbrella header includes the vendored
# header, which the app's Swift module imports. GRDB's `GRDBSQLite/shim.h` is
# this exact one-liner.
text = text.replace(
    f'''            dependencies: [
                .product(name: "SwiftPWA", package: "{pkg}"),
            ],''',
    f'''            dependencies: [
                .product(name: "SwiftPWA", package: "{pkg}"),
                "CVendoredProbe",
            ],''')
text = text.replace(
    "        ),\n    ]\n)",
    """        ),
        .target(
            name: "CVendoredProbe",
            linkerSettings: [.linkedLibrary("vendoredprobe")]
        ),
    ]
)""")
manifest.write_text(text)

shim = app_dir / "Sources" / "CVendoredProbe"
(shim / "include").mkdir(parents=True)
(shim / "include" / "shim.h").write_text("#include <vendoredprobe.h>\n")
(shim / "shim.c").write_text('#include "include/shim.h"\n')

# Call into the library as well as including its header, so a green run proves
# both halves rather than just the compile.
probe = app_dir / "Sources" / app_dir.name / "VendoredProbe.swift"
probe.write_text('''import CVendoredProbe
import Foundation

enum VendoredProbe {
    static var version: String { String(cString: sqlite3_libversion()) }
}
''')
app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
app_swift.write_text(re.sub(
    r'(?m)^    _ = try ctx\.createWindow\(',
    '    print("vendored probe " + VendoredProbe.version)\n\n    _ = try ctx.createWindow(',
    app_swift.read_text()))
PY

cp -R "$VENDOR/include" "$APP_DIR/Vendor-include"
cp -R "$VENDOR/lib" "$APP_DIR/Vendor-lib"

# Written twice below; `native_include_dirs` is what the control run drops.
write_manifest() {
    python3 - "$APP_DIR" "$1" "$TARGET" <<'PY'
import json, pathlib, sys
app_dir, mode, target = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
path = app_dir / "pwa.json"
m = json.loads(path.read_text())
section = m.setdefault(target, {})
section["native_library_dirs"] = ["Vendor-lib"]
if mode == "with-headers":
    section["native_include_dirs"] = ["Vendor-include"]
else:
    section.pop("native_include_dirs", None)
path.write_text(json.dumps(m, indent=2, sort_keys=True))
PY
}

build_cold() {
    # A genuinely cold clang module cache. `.build/out/Products` is not enough
    # and neither are the intermediates - the built `CVendoredProbe` module
    # survives a change of include flags and the run confirms whatever it
    # already believed.
    rm -rf "$APP_DIR/.build"
    if [ "$TARGET" = "android" ]; then
        (cd "$APP_DIR" && "$CLI" build --target android --cross-compile-android \
            --android-abis "$ABI") 2>&1
    else
        (cd "$APP_DIR" && "$CLI" build --target linux) 2>&1
    fi
}

echo
echo "== control: native_library_dirs alone, cold module cache =="
write_manifest without-headers
CONTROL_LOG="$WORK/control.log"
if build_cold > "$CONTROL_LOG"; then
    echo "CONTROL FAILED: the build SUCCEEDED without native_include_dirs." >&2
    echo "The header reached the compile some other way (a warm cache, a global" >&2
    echo "CPATH). This run proves nothing - fix the instrument before trusting" >&2
    echo "the measurement." >&2
    exit 1
fi
if ! grep -q "'vendoredprobe.h' file not found" "$CONTROL_LOG"; then
    echo "CONTROL FAILED: the build failed, but not on the missing header." >&2
    echo "Whatever stopped it is upstream of what this checks; tail follows." >&2
    tail -30 "$CONTROL_LOG" >&2
    exit 1
fi
echo "control ok - 'vendoredprobe.h' file not found, as it should be"

echo
echo "== subject: native_include_dirs added, cold module cache =="
write_manifest with-headers
SUBJECT_LOG="$WORK/subject.log"
if ! build_cold > "$SUBJECT_LOG"; then
    echo "FAILED: the build still doesn't reach the vendored header." >&2
    tail -40 "$SUBJECT_LOG" >&2
    exit 1
fi

if [ "$TARGET" = "android" ]; then
    BINARY="$APP_DIR/.build/out/Products/Release-android-$ARCH_DIR/$APP"
    STAGED="$APP_DIR/build/android/$APP-android/app/src/main/jniLibs/$ABI/lib$APP.so"
else
    BINARY="$(find "$APP_DIR/.build" -type f -name "$APP" -path '*release*' | head -1)"
    STAGED="$(find "$APP_DIR/build/linux" -name '*.AppImage' 2>/dev/null | head -1)"
fi
if [ -z "$BINARY" ] || [ ! -f "$BINARY" ]; then
    echo "FAILED: the build reported success but produced no binary." >&2
    tail -40 "$SUBJECT_LOG" >&2
    exit 1
fi

# The compile succeeding isn't the whole claim: the *library* half has to have
# resolved too, or the app would carry a header it can't call.
#
# Through a file, not a pipe: `nm | grep -q` under `set -o pipefail` reports the
# pipeline as failed whenever grep matches early enough to SIGPIPE nm, so the
# check reads "symbol missing" on a perfectly good binary.
NM_OUT="$WORK/symbols.txt"
"$NM" --defined-only "$BINARY" > "$NM_OUT" 2>/dev/null || true
if ! grep -q ' sqlite3_libversion$' "$NM_OUT"; then
    echo "FAILED: the app compiled, but sqlite3_libversion isn't defined in the" >&2
    echo "built binary - the header reached the compile and the library didn't" >&2
    echo "reach the link." >&2
    exit 1
fi
SYMBOLS="$(grep -c ' sqlite3_' "$NM_OUT" || true)"

if [ -z "$STAGED" ] || [ ! -f "$STAGED" ]; then
    echo "FAILED: the build produced no packaged artifact." >&2
    tail -40 "$SUBJECT_LOG" >&2
    exit 1
fi

echo
echo "PASS ($TARGET)"
echo "  control : 'vendoredprobe.h' file not found without native_include_dirs"
echo "  subject : compiled against the vendored header, cold module cache"
echo "  linked  : $SYMBOLS probe symbols defined in the built binary"
echo "  packaged: $STAGED"
