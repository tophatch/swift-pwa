#!/usr/bin/env bash
#
# What Back does on Android when the page holds a close watcher (#294).
#
# Back goes to the newest close watcher the page holds (a `CloseWatcher`, a
# modal <dialog>), as in Chrome, before it walks history; with neither, the
# app stands aside and Back leaves as it always did. Real Back presses through
# `adb shell input keyevent KEYCODE_BACK`. Rows:
#
#   1. CONTROL, must leave: no watcher, no history. Proves a Back press here
#      is a real one, so the rows that stay are staying for the right reason.
#   2. A watcher and no history: Back closes the watcher, the app stays.
#   3. Then, with it gone, Back leaves.
#   4. A modal <dialog>: Back closes it, the app stays.
#   5. History and a watcher: Back closes the watcher first, then walks back.
#   6. A hung page holding a watcher can't trap Back: the third press leaves.
#
# The page keeps its log in localStorage, so a row can read what happened even
# after the app has gone. With --released, the same app is built by the last
# release's CLI: the control for the fix, where rows 2, 4 and 5 have to fail.
# The CLI, not just the package, because on Android Back lives in the Kotlin
# the CLI generates; a control built by this checkout's CLI passes every row.
#
# Usage:
#   Scripts/verify-android-back.sh [-s <adb-serial>] [--released] [-k]
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

WORK="${TMPDIR:-/tmp}/swift-pwa-android-back"
APP="BackCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.backcheck"

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

# The top half of every page is a link to the next one, so a real tap makes a
# history entry Back can walk (one made without a gesture doesn't count).
for page in index page2; do
    next=$([ "$page" = index ] && echo page2.html || echo index.html)
    cat > "$APP_DIR/web/$page.html" <<HTML
<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$page</title>
<a href="$next" style="display:block;height:50vh;font:32px system-ui;background:#eef">$page: go to $next</a>
<dialog id="d">a dialog</dialog>
<script>
const log = (m) => {
  const all = JSON.parse(localStorage.getItem('log') || '[]');
  all.push('$page ' + m);
  localStorage.setItem('log', JSON.stringify(all));
};
window.watch = () => {
  const w = new CloseWatcher();
  w.onclose = () => log('watcher closed');
  log('watcher open');
};
document.getElementById('d').addEventListener('close', () => log('dialog closed'));
</script>
HTML
done

"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
echo "== deploying ($ABI) =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis "$ABI" >"$WORK/deploy.log" 2>&1) \
    || { tail -30 "$WORK/deploy.log"; exit 1; }

in_front() { "${ADB[@]}" shell dumpsys activity activities | grep -q "topResumedActivity=.*$PKG/"; }
js() { "${CDP[@]}" "$PKG" "$1" 2>/dev/null; }
back() { "${ADB[@]}" shell input keyevent KEYCODE_BACK; sleep 1.5; }
# A fresh launch with an empty log, on the entry page.
fresh() {
    "${ADB[@]}" shell am force-stop "$PKG"
    "${ADB[@]}" shell am start -W -n "$PKG/.MainActivity" >/dev/null
    for _ in $(seq 1 30); do [ "$(js "typeof window.watch")" = '"function"' ] && break; sleep 0.5; done
    js "localStorage.setItem('log', '[]'); 1" >/dev/null
}
logged() { js "localStorage.getItem('log')"; }

FAILED=0
row() { # <name> <0|1 passed> <detail>
    if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1 ($3)"; FAILED=1; fi
}

fresh
back
in_front && r=0 || r=1
row "1. control: no watcher, no history, Back leaves" "$r" "the app stayed in front"

fresh
js "watch(); 1" >/dev/null
back
in_front && [[ "$(logged)" == *"watcher closed"* ]] && r=1 || r=0
row "2. a watcher and no history: Back closes it and the app stays" "$r" "log $(logged 2>/dev/null || echo gone)"
back
in_front && r=0 || r=1
row "3. with it gone, Back leaves" "$r" "the app stayed in front"

fresh
js "document.getElementById('d').showModal(); 1" >/dev/null
sleep 0.5
back
in_front && [ "$(js "document.getElementById('d').open")" = "false" ] && r=1 || r=0
row "4. a modal dialog: Back closes it and the app stays" "$r" "log $(logged 2>/dev/null || echo gone)"

fresh
size=$("${ADB[@]}" shell wm size | tail -1 | sed 's/.*: //' | tr -d '\r')
"${ADB[@]}" shell input tap "$(( ${size%x*} / 2 ))" "$(( ${size#*x} / 4 ))"
for _ in $(seq 1 20); do [ "$(js "location.pathname")" = '"/page2.html"' ] && break; sleep 0.5; done
for _ in $(seq 1 30); do [ "$(js "typeof window.watch")" = '"function"' ] && break; sleep 0.5; done
js "watch(); 1" >/dev/null
back
first=$(js "location.pathname")
back
second=$(js "location.pathname")
[ "$first" = '"/page2.html"' ] && [ "$second" = '"/index.html"' ] && in_front && r=1 || r=0
row "5. history and a watcher: Back closes the watcher, then walks back" "$r" "after one Back $first, after two $second"

fresh
js "watch(); setTimeout(() => { const end = Date.now() + 20000; while (Date.now() < end); }, 200); 1" >/dev/null
sleep 1
for _ in 1 2 3; do "${ADB[@]}" shell input keyevent KEYCODE_BACK; sleep 1; done
sleep 1
in_front && r=0 || r=1
row "6. a hung page holding a watcher can't trap Back" "$r" "the app was still in front after three Backs"
"${ADB[@]}" shell am force-stop "$PKG"

echo
if [ "$FAILED" -eq 0 ]; then echo "PASS: every row held."; else echo "FAIL: see above."; fi
exit "$FAILED"
