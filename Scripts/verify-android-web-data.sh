#!/usr/bin/env bash
#
# SWIFT_PWA_WEB_DATA=ephemeral and the other SWIFT_PWA_* launch variables on
# Android, where a launch passes them as intent extras: Android starts an app
# with none of its caller's environment, so a debug build copies the launch's
# `SWIFT_PWA_*` string extras into its own before the runtime starts.
#
# Every launch is a cold one (`am start -S`), since the variables apply only
# when the process starts. The page reads and writes a localStorage key, an
# IndexedDB record and a cookie, and reports all three. Rows:
#
#   1. CONTROL, must hold: a value written by one persistent launch is read by
#      the next. Proves the instrument reads storage across launches, so an
#      empty read below means an empty store rather than a broken probe.
#   2. An ephemeral launch starts empty.
#   3. A second ephemeral launch doesn't see what the first one wrote.
#   4. The app's real store is untouched: a persistent launch after them reads
#      what row 1 wrote, and nothing the ephemeral launches wrote.
#   5. What ephemeral launches leave on disk is gone after the next launch.
#   6. SWIFT_PWA_INITIAL_ROUTE passed the same way opens the app on that route.
#   7. A misspelled value is reported in logcat, and the launch is persistent.
#
# With --released, the same app is built by the last release's CLI: the control
# for the change, where rows 2, 3, 4, 6 and 7 have to fail (row 5 holds there
# because there is nothing to delete). The CLI, not just the
# package, because the extras are read by the Kotlin the CLI generates.
#
# Usage:
#   Scripts/verify-android-web-data.sh [-s <adb-serial>] [--released] [-k]
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
if [ -n "$SERIAL" ]; then
    ADB=(adb -s "$SERIAL")
    CDP+=(-s "$SERIAL")
fi

WORK="${TMPDIR:-/tmp}/swift-pwa-android-web-data"
APP="WebDataCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.webdatacheck"

cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "no device: attach one over USB (wireless adb ports rotate and are flaky)" >&2
    exit 1
fi
# A Samsung with its screen off freezes the app, and a CDP call then hangs.
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP

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
if [ "$RELEASED" -eq 1 ]; then
    echo "== scaffolded by $("$CLI" --version), against the released package =="
else
    echo "== scaffolded against this checkout =="
    python3 - "$APP_DIR/Package.swift" "$REPO" <<'PY'
import pathlib, re, sys
manifest, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
text = manifest.read_text()
text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                      f'.package(path: "{repo}")', text)
assert count == 1, "the scaffold's package pin moved; this would test the released package"
text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
manifest.write_text(text)
PY
fi

# `report()` answers with one token per store, `-` for an empty one.
cat > "$APP_DIR/web/probe.js" <<'JS'
const db = () => new Promise((resolve, reject) => {
  const open = indexedDB.open('probe', 1);
  open.onupgradeneeded = () => open.result.createObjectStore('s');
  open.onsuccess = () => resolve(open.result);
  open.onerror = () => reject(open.error);
});
const idb = async (mode, fn) => {
  const d = await db();
  return new Promise((resolve, reject) => {
    const req = fn(d.transaction('s', mode).objectStore('s'));
    req.onsuccess = () => { d.close(); resolve(req.result); };
    req.onerror = () => reject(req.error);
  });
};
window.write = async (tag) => {
  localStorage.setItem('k', tag);
  await idb('readwrite', (s) => s.put(tag, 'k'));
  document.cookie = `k=${tag}; max-age=86400; path=/; secure`;
  return 'written';
};
window.report = async () => {
  const cookie = (document.cookie.match(/(?:^|; )k=([^;]*)/) || [])[1];
  const record = await idb('readonly', (s) => s.get('k'));
  return `ls=${localStorage.getItem('k') || '-'} idb=${record || '-'} cookie=${cookie || '-'}`;
};
JS
for page in index page2; do
    cat > "$APP_DIR/web/$page.html" <<HTML
<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$page</title>
<p style="font:32px system-ui">$page</p>
<script src="probe.js"></script>
HTML
done

"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
echo "== deploying ($ABI) =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis "$ABI" >"$WORK/deploy.log" 2>&1) \
    || { tail -30 "$WORK/deploy.log"; exit 1; }

js() { "${CDP[@]}" "$PKG" "$1" 2>/dev/null; }
# A cold launch, passing each argument as a string extra.
launch() {
    local extras=()
    for kv in "$@"; do extras+=(--es "${kv%%=*}" "${kv#*=}"); done
    "${ADB[@]}" logcat -c
    "${ADB[@]}" shell am start -S -W -n "$PKG/.MainActivity" ${extras[@]+"${extras[@]}"} >/dev/null
    for _ in $(seq 1 40); do [ "$(js "typeof window.report")" = '"function"' ] && return; sleep 0.5; done
    echo "the page never loaded" >&2
    return 1
}
report() { js "report()"; }
# Write, then wait out WebView's commits before the next `am start -S` kills the
# process: localStorage lands within 2 s, but cookies only on CookieManager's
# 30 s flush. A write that never reached disk fails the control and lets rows
# 3 and 4 pass for the wrong reason.
write() { js "write('$1')" >/dev/null; sleep 35; }
# The app's data and cache directories, which hold WebView's stores.
webview_dirs() {
    "${ADB[@]}" shell run-as "$PKG" sh -c "'ls -d /data/data/$PKG/app_webview* /data/data/$PKG/cache/* 2>/dev/null'" \
        | tr -d '\r' | sed "s|/data/data/$PKG/||" | tr '\n' ' '
}

FAILED=0
row() { # <name> <0|1 passed> <detail>
    if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1 ($3)"; FAILED=1; fi
}

launch
write persist
launch
got=$(report)
[ "$got" = '"ls=persist idb=persist cookie=persist"' ] && r=1 || r=0
row "1. control: a persistent launch reads what the last one wrote" "$r" "read $got"

launch SWIFT_PWA_WEB_DATA=ephemeral
got=$(report)
echo "   on disk during an ephemeral launch: $(webview_dirs)"
[ "$got" = '"ls=- idb=- cookie=-"' ] && r=1 || r=0
row "2. an ephemeral launch starts empty" "$r" "read $got"
write ephemeral

launch SWIFT_PWA_WEB_DATA=ephemeral
got=$(report)
[ "$got" = '"ls=- idb=- cookie=-"' ] && r=1 || r=0
row "3. a second ephemeral launch doesn't see the first one's writes" "$r" "read $got"
write ephemeral

launch
got=$(report)
[ "$got" = '"ls=persist idb=persist cookie=persist"' ] && r=1 || r=0
row "4. the real store is untouched by ephemeral launches" "$r" "read $got"

sleep 2
left=$(webview_dirs)
echo "   on disk after a persistent launch: $left"
[[ "$left" != *ephemeral* ]] && r=1 || r=0
row "5. what ephemeral launches left is gone after the next launch" "$r" "found $left"

launch SWIFT_PWA_INITIAL_ROUTE=/page2.html
got=$(js "location.pathname")
[ "$got" = '"/page2.html"' ] && r=1 || r=0
row "6. SWIFT_PWA_INITIAL_ROUTE as an extra opens the route" "$r" "landed on $got"

launch SWIFT_PWA_WEB_DATA=ephmeral
got=$(report)
warned=$("${ADB[@]}" logcat -d -s swift-pwa:W | grep -c "SWIFT_PWA_WEB_DATA=ephmeral isn't a setting" || true)
[ "$got" = '"ls=persist idb=persist cookie=persist"' ] && [ "$warned" -ge 1 ] && r=1 || r=0
row "7. a misspelled value is reported and the launch stays persistent" "$r" "read $got, warnings $warned"

"${ADB[@]}" shell am force-stop "$PKG"
[ "$KEEP" -eq 1 ] || "${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true

echo
if [ "$FAILED" -eq 0 ]; then echo "PASS: every row held."; else echo "FAIL: see above."; fi
exit "$FAILED"
