#!/usr/bin/env bash
#
# Cross-compile a fresh `swift-pwa init` app for Android through the CLI, check
# the APK carries everything its native code needs, and — with a device or
# emulator attached — deploy it and ask the page whether the bridge is there
# (#278).
#
# CI's `android` job builds the Gradle scaffold without the Swift cross-compile,
# so nothing else exercises the path an adopter's `swift-pwa build --target
# android --cross-compile-android` takes. Faults that shipped through that gap:
# an APK with no `libc++_shared.so` once the Swift SDK stopped vendoring the
# NDK sysroot, and an undeclared dependency whose `.so` linked clean and died
# at load.
#
# Checks:
#   apk-<abi>       the APK has the app's .so, the Swift runtime and
#                   libc++_shared.so for each ABI, and every library any of
#                   them needs is either in the APK or one Android provides.
#   deployed        `swift-pwa deploy` reports the app running (#313).
#   bridge          `typeof __SWIFT_PWA__` is "object": bridge.js was found and
#                   injected into a live page.
#   invoke          an invoke round-trips through Swift.
#
# The app is scaffolded against this checkout, not the release it would pin
# (the examples are not the scaffold).
#
# Usage:
#   Scripts/bundle-smoke-android.sh [-s <adb-serial>] [--no-device]
#       [--abis arm64-v8a,x86_64] [--cli <swift-pwa>] [--work <dir>] [-k]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL="${ANDROID_SERIAL:-}"
DEVICE=1
ABIS="arm64-v8a,x86_64"
CLI=""
WORK="${TMPDIR:-/tmp}/swift-pwa-bundle-smoke-android"
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERIAL="$2"; shift 2 ;;
        --no-device) DEVICE=0; shift ;;
        --abis) ABIS="$2"; shift 2 ;;
        --cli) CLI="$2"; shift 2 ;;
        --work) WORK="$2"; shift 2 ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 [-s serial] [--no-device] [--abis list] [--cli path] [--work dir] [-k]" >&2; exit 2 ;;
    esac
done

APP=AndroidSmoke
PKG=com.example.androidsmoke
ADB=(adb)
[ -n "$SERIAL" ] && { ADB=(adb -s "$SERIAL"); export ANDROID_SERIAL="$SERIAL"; }
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

RESULTS=()
pass() { RESULTS+=("PASS  $1 - $2"); }
fail() { RESULTS+=("FAIL  $1 - $2"); }

if [ "$DEVICE" -eq 1 ]; then
    "${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device (pass --no-device to build only)" >&2; exit 1; }
    # A Samsung with its screen off freezes a launching app.
    "${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
fi

if [ -z "$CLI" ]; then
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa)
    CLI="$REPO/.build/debug/swift-pwa"
fi

echo "== scaffolding $APP against $REPO =="
rm -rf "$WORK"; mkdir -p "$WORK"
(cd "$WORK" && "$CLI" init "$APP" >/dev/null)
# A path dependency is named after its directory, so the product reference has
# to follow a checkout that isn't called swift-pwa.
perl -pi -e 's|\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]*"\)|.package(path: "'"$REPO"'")|;
    s|package: "swift-pwa"|package: "'"$(basename "$REPO")"'"|' "$WORK/$APP/Package.swift"
grep -q 'package(path:' "$WORK/$APP/Package.swift" \
    || { echo "the scaffold's Package.swift no longer matches the rewrite - it would test the released package" >&2; exit 1; }

cd "$WORK/$APP"
if [ "$DEVICE" -eq 1 ]; then
    echo "== swift-pwa deploy --target android --android-abis $ABIS =="
    "$CLI" deploy --target android --android-abis "$ABIS" 2>&1 | tee "$WORK/deploy.log"
else
    echo "== swift-pwa build --target android --cross-compile-android --android-abis $ABIS =="
    "$CLI" build --target android --cross-compile-android --android-abis "$ABIS"
    (cd "build/android/$APP-android" && ./gradlew --no-daemon -q assembleDebug)
fi

APK="build/android/$APP-android/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || { echo "no APK at $APK" >&2; exit 1; }

# The NDK's readelf reads any ABI; the host's may not exist (macOS).
READELF="$(ls "${ANDROID_NDK_HOME:-/nonexistent}"/toolchains/llvm/prebuilt/*/bin/llvm-readelf \
    "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-readelf \
    2>/dev/null | tail -1 || true)"
[ -n "$READELF" ] || READELF="$(command -v llvm-readelf || command -v readelf || true)"
[ -n "$READELF" ] || { echo "no readelf: set ANDROID_NDK_HOME" >&2; exit 1; }

# What Android itself provides to an app (the NDK's stable system libraries).
SYSTEM_LIBS=" libc.so libm.so libdl.so liblog.so libandroid.so libz.so libEGL.so libGLESv2.so \
libGLESv3.so libjnigraphics.so libmediandk.so libOpenSLES.so libaaudio.so libvulkan.so \
libnativewindow.so libcamera2ndk.so libbinder_ndk.so libsync.so libamidi.so "

unzip -q -o "$APK" 'lib/*' -d "$WORK/apk"
for abi in ${ABIS//,/ }; do
    dir="$WORK/apk/lib/$abi"
    missing=()
    for want in "lib$APP.so" libswiftCore.so libc++_shared.so; do
        [ -f "$dir/$want" ] || missing+=("$want")
    done
    unresolved=()
    for so in "$dir"/*.so; do
        [ -f "$so" ] || continue
        for need in $("$READELF" -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'); do
            [ -f "$dir/$need" ] || [[ "$SYSTEM_LIBS" == *" $need "* ]] || unresolved+=("$(basename "$so") needs $need")
        done
    done
    count=$(find "$dir" -name '*.so' 2>/dev/null | wc -l | tr -d ' ')
    if [ ${#missing[@]} -gt 0 ]; then
        fail "apk-$abi" "missing ${missing[*]} ($count .so)"
    elif [ ${#unresolved[@]} -gt 0 ]; then
        fail "apk-$abi" "$(printf '%s; ' "${unresolved[@]}")"
    else
        pass "apk-$abi" "$count .so, every NEEDED library in the APK or the system"
    fi
done

if [ "$DEVICE" -eq 1 ]; then
    if grep -q "^Deployed to" "$WORK/deploy.log"; then
        pass deployed "$(grep '^Deployed to' "$WORK/deploy.log")"
    else
        fail deployed "$(grep -E 'not running|error' "$WORK/deploy.log" | tail -1)"
        "${ADB[@]}" logcat -d -t 200 "swift-pwa:I" "AndroidRuntime:E" "*:F" || true
    fi
    eval_js() { python3 "$REPO/Scripts/android-cdp-eval.py" ${SERIAL:+-s "$SERIAL"} "$PKG" "$1" 2>&1 || true; }
    # A WebView in the background has no DevTools socket, and a foldable can
    # send a freshly launched app home. Bring the *same* process back to the
    # front — a crashed one has no pid, and fails here rather than being
    # relaunched into a pass.
    pidof() { "${ADB[@]}" shell pidof "$PKG" | tr -d '\r' || true; }
    pid="$(pidof)"
    out="the app's process is gone after deploy"
    # The page may still be loading when deploy returns.
    for _ in $(seq 1 30); do
        [ -n "$pid" ] || break
        now="$(pidof)"
        [ "$now" = "$pid" ] || { out="the app's process changed (${pid} -> ${now:-none}): it died"; break; }
        "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
        out="$(eval_js 'typeof __SWIFT_PWA__')"
        [ "$out" = '"object"' ] && break
        sleep 1
    done
    if [ "$out" = '"object"' ]; then pass bridge "typeof __SWIFT_PWA__ = object"; else fail bridge "$out"; fi
    # Compared whole: an error from the helper names the package, which
    # contains "android" too.
    out="$(eval_js "(async()=>(await __SWIFT_PWA__.invoke('__platform.info')).os)()")"
    if [ "$out" = '"android"' ]; then pass invoke "__platform.info answered os=android from Swift"; else fail invoke "$out"; fi
fi

echo
printf '%s\n' "${RESULTS[@]}"
for r in "${RESULTS[@]}"; do [[ "$r" == FAIL* ]] && exit 1; done
exit 0
