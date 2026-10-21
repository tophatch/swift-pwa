#!/usr/bin/env bash
#
# App icon appearances and alternate icons on Android (#314), on a fresh
# `swift-pwa init` app deployed to a device. Rows:
#
#   1. The launcher entry is the primary icon's alias (`.LauncherDefault`), not
#      MainActivity: the manifest carries one <activity-alias> per icon.
#   2. The build staged an adaptive icon with a monochrome (themed) layer for
#      each icon, from the tinted art.
#   3. app.icon.list lists the alternate, with current null.
#   4. app.icon.set to the alternate: current follows, the launcher entry is the
#      alternate's alias, and the app's process survives (DONT_KILL_APP).
#   5. An undeclared name fails with E_NOT_FOUND.
#   6. app.icon.set null: the launcher entry is the primary's alias again.
#
# How the launcher draws the icons — the inset art, the themed layer with the
# palette applied — was checked by eye on One UI; see
# docs/proposals/app-icon-appearances.md.
#
# With --released, the app is built by the last release's CLI and package: the
# control, where every row has to fail.
#
# Usage:
#   Scripts/verify-android-app-icons.sh [-s <adb-serial>] [--released] [-k]
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
CDP=("$REPO/Scripts/android-cdp-eval.py")
DEVICE_FLAG=()
if [ -n "$SERIAL" ]; then
    ADB=(adb -s "$SERIAL")
    CDP+=(-s "$SERIAL")
    DEVICE_FLAG=(--device "$SERIAL")
fi
PKG=com.example.iconprobe

WORK="${TMPDIR:-/tmp}/swift-pwa-android-app-icons"
APP_DIR="$WORK/IconProbe"
cleanup() {
    if [ "$KEEP" -eq 0 ]; then
        "${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT
rm -rf "$WORK"; mkdir -p "$WORK"

if [ "$RELEASED" -eq 1 ]; then
    echo "== downloading the last release's CLI =="
    gh release download --repo tophatch/swift-pwa --pattern "swift-pwa-macos-$(uname -m)" --dir "$WORK"
    CLI="$WORK/swift-pwa-macos-$(uname -m)"
    chmod +x "$CLI"
else
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa >"$WORK/cli-build.log" 2>&1) \
        || { grep -E "error:" "$WORK/cli-build.log" | head -20; tail -5 "$WORK/cli-build.log"; exit 1; }
    CLI="$REPO/.build/debug/swift-pwa"
fi
(cd "$WORK" && "$CLI" init IconProbe >/dev/null)

python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import json, pathlib, re, struct, sys, zlib
app_dir, repo, released = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "1"
art = app_dir / "art"
art.mkdir()
def png(name, rgb, alpha=lambda x, y: 255):
    n = 512
    rows = b"".join(b"\x00" + b"".join(bytes(rgb) + bytes([alpha(x, y)]) for x in range(n)) for y in range(n))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    (art / name).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
                             + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
png("icon.png", (40, 90, 220)); png("icon-tinted.png", (255, 255, 255), lambda x, y: 255 if abs(x - 256) < 60 else 0)
png("sketch.png", (240, 140, 20)); png("sketch-tinted.png", (255, 255, 255),
                                         lambda x, y: 255 if (x - 256) ** 2 + (y - 256) ** 2 < 140 ** 2 else 0)
manifest = app_dir / "pwa.json"
data = json.loads(manifest.read_text())
# The released CLI can't decode an icon object at all, which would stop the
# control before any row ran; given the plain path it understands, every row
# has to fail on its own.
data["icon"] = "art/icon.png" if released else {"light": "art/icon.png", "tinted": "art/icon-tinted.png"}
data["alternate_icons"] = [{"name": "sketch", "icon": {"light": "art/sketch.png", "tinted": "art/sketch-tinted.png"}}]
manifest.write_text(json.dumps(data, indent=2))
if not released:
    package = app_dir / "Package.swift"
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', package.read_text())
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    package.write_text(text.replace('package: "swift-pwa"', f'package: "{repo.name}"'))
PY

echo "== deploying =="
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a ${DEVICE_FLAG[@]+"${DEVICE_FLAG[@]}"} >"$WORK/deploy.log" 2>&1) \
    || { grep -E "error|Error" "$WORK/deploy.log" | head -20; tail -10 "$WORK/deploy.log"; exit 1; }
grep "app icon" "$WORK/deploy.log" || true

PASS=0
FAIL=0
row() { # row <n> <description> <ok:0|1> [detail]
    if [ "$3" -eq 1 ]; then PASS=$((PASS + 1)); echo "PASS $1. $2"; else FAIL=$((FAIL + 1)); echo "FAIL $1. $2${4:+ — $4}"; fi
}
launcher_entry() {
    "${ADB[@]}" shell cmd package query-activities -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER "$PKG" | sed -n 's/^ *name=//p' | head -1
}
eval_js() { "${CDP[@]}" "$PKG" "$1" 2>&1 | tail -1; }
LIST="(async()=>{try{const r=await __SWIFT_PWA__.invoke('app.icon.list');return 'supported='+r.supported+' current='+r.current+' alternates='+r.alternates.join(',')}catch(e){return e.code}})()"

entry="$(launcher_entry)"
[ "$entry" = "$PKG.LauncherDefault" ] && ok=1 || ok=0
row 1 "the launcher entry is the primary icon's alias" "$ok" "$entry"

res="$APP_DIR/build/android/IconProbe-android/app/src/main/res/mipmap-anydpi-v26"
grep -q "<monochrome" "$res/ic_launcher.xml" 2>/dev/null && grep -q "<monochrome" "$res/ic_launcher_sketch.xml" 2>/dev/null \
    && ok=1 || ok=0
row 2 "both icons have an adaptive icon with a themed layer" "$ok" "$(ls "$res" 2>/dev/null | tr '\n' ' ')"

"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 4
out="$(eval_js "$LIST")"
[[ "$out" == *"supported=true current=null alternates=sketch"* ]] && ok=1 || ok=0
row 3 "app.icon.list lists the alternate with current null" "$ok" "$out"

pid_before="$("${ADB[@]}" shell pidof "$PKG" || true)"
set_out="$(eval_js "(async()=>{try{await __SWIFT_PWA__.invoke('app.icon.set',{name:'sketch'});return 'ok'}catch(e){return e.code}})()")"
sleep 1
out="$set_out; $(eval_js "$LIST")"
pid_after="$("${ADB[@]}" shell pidof "$PKG" || true)"
entry="$(launcher_entry)"
[[ "$out" == *"current=sketch "* ]] && [ "$entry" = "$PKG.LauncherIcon_sketch" ] \
    && [ -n "$pid_before" ] && [ "$pid_before" = "$pid_after" ] && ok=1 || ok=0
row 4 "app.icon.set switches the launcher entry and keeps the process" "$ok" "$out; entry $entry; pid $pid_before → $pid_after"

# The message, not just the code: an unknown *command* is E_NOT_FOUND too.
out="$(eval_js "(async()=>{try{await __SWIFT_PWA__.invoke('app.icon.set',{name:'nope'});return 'resolved'}catch(e){return e.code+': '+e.message}})()")"
[[ "$out" == *"E_NOT_FOUND: app.icon.set: no alternate icon named"* ]] && ok=1 || ok=0
row 5 "an undeclared name fails with E_NOT_FOUND" "$ok" "$out"

out="$(eval_js "(async()=>{try{await __SWIFT_PWA__.invoke('app.icon.set',{name:null});return 'ok'}catch(e){return e.code}})()")"
entry="$(launcher_entry)"
[[ "$out" == *ok* ]] && [ "$entry" = "$PKG.LauncherDefault" ] && ok=1 || ok=0
row 6 "app.icon.set null puts the primary back in the launcher" "$ok" "$out; entry $entry"

NOTE=""
if [ "$RELEASED" -eq 1 ]; then NOTE=" (control: every row should fail)"; fi
echo "== $PASS passed, $FAIL failed$NOTE =="
if [ "$RELEASED" -eq 1 ]; then [ "$PASS" -eq 0 ]; else [ "$FAIL" -eq 0 ]; fi
