#!/usr/bin/env bash
#
# Check that an Android app finishes what its page and its Swift code start on
# the way out (#281), on a cabled device.
#
# Three rows, each a fresh launch of a scaffolded app carrying the shared probe
# (close-flush-probe/), which writes a marker — to logcat, since Android drops
# stdout — from `willClose`, `visibilitychange` to hidden, `pagehide`, a
# 300ms-slow invoke posted from each of those last two, and a Swift
# `beforeClose` handler:
#
#   backgrounded  Home pressed. A stopped app can be killed without being told,
#                 so `onStop` is where Android flushes: the page's work from
#                 going hidden, and `beforeClose(.backgrounded)`.
#   app.quit      the page calls it; the page gets its real unload first.
#   window.close  the primary window closing, which quits the app.
#   Back (history)  Back with a history entry goes back in the page (its
#                 `popstate`) and leaves the app where it is.
#   Back (root)   Back at the root. Launched the way this harness launches,
#                 Android finishes the Activity but keeps the process; the
#                 runtime has to outlive it (#288). `onStop` flushes, and a
#                 relaunch attaches to the same runtime: one runtime thread,
#                 `configure` run once, and the page back on the route it had.
#
# There is no driver for Android, so the page is told what to do by a file the
# harness drops into the app's data with `run-as` before launch.
#
# The control is the page's own synchronous marker for the row (`hidden` when
# backgrounded, `pagehide` otherwise): if that never lands, the page didn't
# hear it was going and the rest of the row means nothing.
#
# Usage:
#   Scripts/verify-close-flush-android.sh [-s <adb-serial>] [-k] [-n]
#     -s  adb serial (default: the only attached device)
#     -k  keep the scaffolded app directory
#     -n  don't rebuild — reuse the app installed by a previous -k run
#     -r  run only the rows whose name contains this text
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
KEEP=0
BUILD=1
ONLY=""
while getopts "s:knr:" opt; do
    case "$opt" in
        s) SERIAL="$OPTARG" ;;
        k) KEEP=1 ;;
        n) BUILD=0; KEEP=1 ;;
        r) ONLY="$OPTARG" ;;
        *) echo "usage: $0 [-s serial] [-k] [-n]" >&2; exit 2 ;;
    esac
done
ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

WORK="${TMPDIR:-/tmp}/swift-pwa-android-close-flush-check"
APP="CloseFlushCheck"
APP_DIR="$WORK/$APP"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "no device: attach one over USB (wireless adb ports rotate and are flaky)" >&2
    exit 1
fi

if [ "$BUILD" -eq 1 ]; then
    rm -rf "$WORK"; mkdir -p "$WORK"
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa >/dev/null)
    CLI="$REPO/.build/debug/swift-pwa"
    echo "== scaffolding $APP =="
    (cd "$WORK" && "$CLI" init "$APP" >/dev/null)
    python3 - "$APP_DIR" "$REPO" <<'PY'
import pathlib, re, sys
app_dir, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
manifest = app_dir / "Package.swift"
text = manifest.read_text()
text = re.sub(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
              f'.package(path: "{repo}")', text)
text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
manifest.write_text(text)
app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text, count = re.subn(r'(?m)^func configure\(_ ctx: any AppContext\) throws \{\n',
                      'func configure(_ ctx: any AppContext) throws {\n    registerCloseProbe(ctx)\n',
                      app_swift.read_text())
assert count == 1, "the scaffold's configure moved; this patch needs updating"
app_swift.write_text(text)
PY
    cp "$REPO/Scripts/close-flush-probe/Probe.swift" "$APP_DIR/Sources/$APP/Probe.swift"
    cp "$REPO/Scripts/close-flush-probe/index.html" "$REPO/Scripts/close-flush-probe/second.html" "$APP_DIR/web/"
    echo "== building, installing and launching =="
    (cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a)
fi

PKG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["android"]["package_id"])' "$APP_DIR/pwa.json")"
LOG="$WORK/logcat.txt"

# The probe keeps its markers and reads its action beside Foundation's
# Documents directory, wherever that lands inside the app's data.
"${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
sleep 8
MARKERS_DIR="$("${ADB[@]}" shell run-as "$PKG" find . -name close-flush-markers.txt 2>/dev/null | head -1 | tr -d '\r' | xargs dirname)"
[ -n "$MARKERS_DIR" ] || { echo "::error::the probe never wrote its markers file — did the app start?"; exit 1; }

PASS=0; FAIL=0
wanted() { [ -z "$ONLY" ] || [[ "$1" == *"$ONLY"* ]]; }
run_row() { # row action control expected...
    local row="$1" action="$2" control="$3"; shift 3
    wanted "$row" || return 0
    "${ADB[@]}" shell am force-stop "$PKG"
    "${ADB[@]}" shell run-as "$PKG" sh -c "'echo $action > $MARKERS_DIR/close-probe-action.txt'"
    "${ADB[@]}" logcat -c
    "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
    local ready=0
    for _ in $(seq 1 30); do
        "${ADB[@]}" logcat -d -s swift-pwa 2>/dev/null | grep -q "CLOSEPROBE ready" && { ready=1; break; }
        sleep 1
    done
    if [ "$ready" -eq 0 ]; then
        echo "  FAIL  $row — the app never became ready"; FAIL=$((FAIL+1)); return
    fi
    [ "$action" = background ] && "${ADB[@]}" shell input keyevent KEYCODE_HOME
    sleep 8
    "${ADB[@]}" logcat -d -s swift-pwa 2>/dev/null > "$LOG"
    local got missing=()
    got="$(sed -n 's/.*CLOSEPROBE \(.*\)$/\1/p' "$LOG" | tr -d '\r' | tr '\n' ' ')"
    for m in "$@"; do grep -q "CLOSEPROBE $m\$" <(tr -d '\r' < "$LOG") || missing+=("$m"); done
    if ! grep -q "CLOSEPROBE $control\$" <(tr -d '\r' < "$LOG"); then
        echo "  FAIL  $row — control: the page never heard it was going [$got]"; FAIL=$((FAIL+1))
    elif [ ${#missing[@]} -eq 0 ]; then
        echo "  PASS  $row — [$got]"; PASS=$((PASS+1))
    else
        echo "  FAIL  $row — missing [${missing[*]}]; got [$got]"; FAIL=$((FAIL+1))
    fi
}

# Launch with `action` written for the page and wait for it to be ready.
launch_ready() {
    "${ADB[@]}" shell am force-stop "$PKG"
    "${ADB[@]}" shell run-as "$PKG" sh -c "'echo $1 > $MARKERS_DIR/close-probe-action.txt'"
    "${ADB[@]}" logcat -c
    "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
    wait_marker ready
}
wait_marker() { # marker [seconds]
    for _ in $(seq 1 "${2:-30}"); do
        "${ADB[@]}" logcat -d -s swift-pwa 2>/dev/null | grep -q "CLOSEPROBE $1" && return 0
        sleep 1
    done
    return 1
}
markers() { "${ADB[@]}" logcat -d -s swift-pwa 2>/dev/null | sed -n 's/.*CLOSEPROBE \(.*\)$/\1/p' | tr -d '\r'; }
pid_of() { "${ADB[@]}" shell pidof "$PKG" | tr -d '\r' || true; }
runtime_threads() { "${ADB[@]}" shell "cat /proc/$1/task/*/comm" 2>/dev/null | grep -c swift-pwa-runti || true; }
our_activity_resumed() {
    "${ADB[@]}" shell dumpsys activity activities | grep -m1 topResumedActivity | grep -q "$PKG/.MainActivity"
}
verdict() { # row, failure or empty
    local got; got="$(markers | tr '\n' ' ')"
    if [ -z "$2" ]; then echo "  PASS  $1 — [$got]"; PASS=$((PASS+1))
    else echo "  FAIL  $1 — $2 [$got]"; FAIL=$((FAIL+1)); fi
}

back_history_row() {
    wanted "Back (history)" || return 0
    launch_ready push-history || { verdict "Back (history)" "the app never became ready"; return; }
    sleep 1
    # A tap, so the page's push carries a user gesture (see the probe).
    local size; size="$("${ADB[@]}" shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)"
    "${ADB[@]}" shell input tap $((${size% *} / 2)) $((${size#* } / 2))
    wait_marker pushed 5 || { verdict "Back (history)" "control: the tap never pushed a history entry"; return; }
    sleep 1
    "${ADB[@]}" shell input keyevent KEYCODE_BACK
    if ! wait_marker popstate 6; then verdict "Back (history)" "no popstate: Back didn't go back in the page"
    elif ! our_activity_resumed; then verdict "Back (history)" "the app left the screen"
    else verdict "Back (history)" ""; fi
}

back_root_row() {
    wanted "Back (root)" || return 0
    launch_ready replace-route || { verdict "Back (root)" "the app never became ready"; return; }
    sleep 2
    local pid; pid="$(pid_of)"
    "${ADB[@]}" shell input keyevent KEYCODE_BACK
    sleep 6
    local after; after="$(pid_of)"
    if [ "$after" != "$pid" ]; then verdict "Back (root)" "the process went (pid $pid → ${after:-none})"; return; fi
    if ! markers | grep -qx swift:backgrounded; then verdict "Back (root)" "control: no onStop flush"; return; fi
    if "${ADB[@]}" shell dumpsys activity activities | grep -q "$PKG/.MainActivity t"; then
        echo "        (Back kept the Activity this time, so the relaunch below resumes it)"
    fi
    "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
    sleep 6
    local threads configures
    threads="$(runtime_threads "$(pid_of)")"
    configures="$(markers | grep -cx configure || true)"
    if [ "$(pid_of)" != "$pid" ]; then verdict "Back (root)" "the relaunch was a new process"
    elif [ "$threads" -ne 1 ]; then verdict "Back (root)" "$threads runtime threads after the relaunch"
    elif [ "$configures" -ne 1 ]; then verdict "Back (root)" "configure ran $configures times"
    elif ! markers | grep -qx restored; then verdict "Back (root)" "the page didn't come back on its route"
    else verdict "Back (root)" ""; fi
}

run_row "backgrounded (Home)" background hidden hidden hidden-slow swift:backgrounded
run_row "app.quit" quit pagehide willClose pagehide pagehide-slow swift:quit
run_row "window.close (primary)" close pagehide willClose pagehide pagehide-slow swift:window swift:quit
back_history_row
back_root_row

"${ADB[@]}" shell run-as "$PKG" rm -f "$MARKERS_DIR/close-probe-action.txt" || true
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
