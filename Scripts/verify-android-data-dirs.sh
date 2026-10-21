#!/usr/bin/env bash
#
# Where an Android app's data and cache directories are, from `configure` on
# (#312). They were derived from `NSTemporaryDirectory()`, which is the app's
# cache dir only where `TMPDIR` is set to it, and on Android 11 nothing sets
# it: Foundation fell back to /data/local/tmp, `ctx.dataDirectory()` became
# /data/local/files, and the app's first write in `configure` failed, leaving a
# blank page. Rows, each read from inside `configure`:
#
#   1. `ctx.dataDirectory()` is the Activity's `filesDir`.
#   2. A file written there in `configure` is written.
#   3. `ctx.cacheDirectory()` is the Activity's `cacheDir`.
#   4. `NSTemporaryDirectory()` is the Activity's `cacheDir`, so app code that
#      uses Foundation's temporary directory can write there too.
#
# The real directories come from `run-as`, so the comparison doesn't trust the
# app's own answer. With --released the same app is built by the last
# release's CLI: on Android 11 every row has to fail (measured on a Boox
# Note5: /data/local/files, /data/local/tmp); on a newer Android, which sets
# `TMPDIR` itself, they pass either way, so that run is no control.
#
# Usage:
#   Scripts/verify-android-data-dirs.sh [-s <adb-serial>] [--released] [-k]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
RELEASED=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERIAL="$2"; shift 2 ;;
        --released) RELEASED=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 [-s serial] [--released] [-k]" >&2; exit 2 ;;
    esac
done

ADB=(adb)
# Exported, so `swift-pwa deploy` picks the same device when several are attached.
[ -n "$SERIAL" ] && { ADB=(adb -s "$SERIAL"); export ANDROID_SERIAL="$SERIAL"; }

WORK="${TMPDIR:-/tmp}/swift-pwa-android-data-dirs${SERIAL:+-$SERIAL}"
APP="DataDirsCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.datadirscheck"

cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "no device: attach one over USB (wireless adb ports rotate and are flaky)" >&2
    exit 1
fi
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
echo "== device: Android $("${ADB[@]}" shell getprop ro.build.version.release | tr -d '\r') =="

rm -rf "$WORK"; mkdir -p "$WORK"
if [ "$RELEASED" -eq 1 ]; then
    echo "== downloading the last release's CLI =="
    gh release download --repo tophatch/swift-pwa --pattern "swift-pwa-macos-$(uname -m)" --dir "$WORK"
    CLI="$WORK/swift-pwa-macos-$(uname -m)"
    chmod +x "$CLI"
else
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa >/dev/null)
    CLI="$REPO/.build/debug/swift-pwa"
fi

(cd "$WORK" && "$CLI" init "$APP" >/dev/null)
python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import pathlib, re, sys
app_dir, repo, released = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
if not released:
    manifest = app_dir / "Package.swift"
    text = manifest.read_text()
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', text)
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
    manifest.write_text(text)

# Reported from `configure`, before any window: that is where the app in the
# issue failed. An Android app's stdout goes nowhere, so through logcat.
probe = '''import Foundation
import SwiftPWA

@MainActor
func reportDirectories(_ ctx: any AppContext) {
    let data = ctx.dataDirectory()
    var wrote = "ok"
    do {
        try Data("x".utf8).write(to: data.appendingPathComponent("probe.txt"))
    } catch {
        wrote = "failed"
    }
    RuntimeDiagnostics.emit("DIRSPROBE data=\\(data.path) wrote=\\(wrote)")
    RuntimeDiagnostics.emit("DIRSPROBE cache=\\(ctx.cacheDirectory().path)")
    RuntimeDiagnostics.emit("DIRSPROBE tmp=\\(NSTemporaryDirectory())")
}
'''
(app_dir / "Sources" / app_dir.name / "Probe.swift").write_text(probe)
app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text = app_swift.read_text()
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    reportDirectories(ctx)\n\n    _ = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app_swift.write_text(text)
PY

if [ "$RELEASED" -eq 1 ]; then
    echo "== scaffolded by $("$CLI" --version), against the released package =="
else
    echo "== scaffolded against this checkout =="
fi

"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
echo "== deploying ($ABI) =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis "$ABI" >"$WORK/deploy.log" 2>&1) \
    || { tail -30 "$WORK/deploy.log"; exit 1; }

# An OEM "auto freeze" (Boox) disables a freshly installed app as it first
# launches, and the probe then never runs. Enabled by hand, it stays enabled.
"${ADB[@]}" shell pm enable "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" logcat -c
"${ADB[@]}" shell am start -S -W -n "$PKG/.MainActivity" >/dev/null
LOG="$WORK/logcat.txt"
for _ in $(seq 1 30); do
    "${ADB[@]}" logcat -d -s swift-pwa > "$LOG" 2>/dev/null || true
    grep -q "DIRSPROBE tmp=" "$LOG" && break
    sleep 1
done
grep -o 'DIRSPROBE .*' "$LOG" | sed 's/^/   /' || echo "   (the app reported nothing)"

# The real ones, resolved by the shell inside the app's sandbox. `pwd -P`
# because /data/user/0 is a link to /data/data on some builds and not others.
# Created first: an app that wrote nowhere near them never made them.
real() { "${ADB[@]}" shell run-as "$PKG" sh -c "'mkdir -p $1 && cd $1 && pwd -P'" | tr -d '\r'; }
FILES=$(real files)
CACHE=$(real cache)
resolved() { # a path the app reported, resolved the same way
    "${ADB[@]}" shell run-as "$PKG" sh -c "'cd \"$1\" 2>/dev/null && pwd -P || echo missing:$1'" | tr -d '\r'
}
reported() { grep -o "DIRSPROBE $1=[^ ]*" "$LOG" | head -1 | sed "s/DIRSPROBE $1=//"; }

FAILED=0
row() { # <name> <0|1 passed> <detail>
    if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1 ($3)"; FAILED=1; fi
}

data=$(reported data)
[ -n "$data" ] && [ "$(resolved "$data")" = "$FILES" ] && r=1 || r=0
row "1. ctx.dataDirectory() is filesDir" "$r" "got '$data', filesDir is $FILES"
grep -q "DIRSPROBE data=.* wrote=ok" "$LOG" && r=1 || r=0
row "2. configure can write there" "$r" "the write failed or never ran"
cache=$(reported cache)
[ -n "$cache" ] && [ "$(resolved "$cache")" = "$CACHE" ] && r=1 || r=0
row "3. ctx.cacheDirectory() is cacheDir" "$r" "got '$cache', cacheDir is $CACHE"
tmp=$(reported tmp)
[ -n "$tmp" ] && [ "$(resolved "$tmp")" = "$CACHE" ] && r=1 || r=0
row "4. NSTemporaryDirectory() is cacheDir" "$r" "got '$tmp', cacheDir is $CACHE"

"${ADB[@]}" shell am force-stop "$PKG"
[ "$KEEP" -eq 1 ] || "${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true

echo
if [ "$FAILED" -eq 0 ]; then echo "PASS: every row held."; else echo "FAIL: see above."; fi
exit "$FAILED"
