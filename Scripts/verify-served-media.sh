#!/usr/bin/env bash
#
# Drive a real app and check that <video> and <audio> play files the app serves.
#
# Why this exists: on WebKitGTK a served clip never loaded at all (#349). Its
# media player reads http, https and blob only, so the GTK backends serve media
# from a loopback port and bridge.js points the page's media URLs at it. CI
# compiles that, and the WebKit tests on macOS exercise the page half, but
# whether GStreamer accepts the result is behaviour on a Linux box.
#
# Runs on macOS and Linux against whichever backend the box has. Each format is
# checked every way a page can point at it — markup, <source>, the src
# property, setAttribute, innerHTML, new Audio — plus a seek near the end, the
# URLs the page reads back, and a crossorigin frame drawn to a canvas.
#
# The trap it's written around: a box with no decoder for a format fails
# exactly as #349 did (MEDIA_ERR_SRC_NOT_SUPPORTED). So each format starts with
# a CONTROL, the same bytes through a blob: URL, which no serving path touches.
# If the control fails, the format is SKIPped as "no decoder here" rather than
# reported as a serving failure.
#
# Usage:
#   Scripts/verify-served-media.sh [--app-dir <dir>] [--keep]
#   Scripts/verify-served-media.sh --attach <port> --token <token> [--cli <path>]
#
#   --app-dir <dir>  where to build the probe app. Default: a temp dir.
#   --keep           don't delete the probe app afterwards.
#   --attach/--token drive an app that is already running with
#                    Scripts/media-probe/ as its web root, instead of building
#                    one (CI's bundle-smoke jobs, which drive a packaged app).
#   --cli <path>     the swift-pwa CLI to drive with. Default: this checkout's
#                    debug build.
#
# Exit status: 0 when nothing failed (SKIPs included), 1 otherwise, and 1 if no
# format could be checked at all — a box that decodes nothing proves nothing.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""
KEEP=0
PORT=""
TOKEN=""
CLI="$REPO/.build/debug/swift-pwa"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --attach) PORT="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --cli) CLI="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $1 — $2"; SKIP=$((SKIP+1)); }

case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *) echo "::error::macOS and Linux only; Windows is covered by Scripts/bundle-smoke-windows.ps1" >&2; exit 2 ;;
esac

if [[ -z "$PORT" ]]; then
    # --- Probe app ----------------------------------------------------------
    CLEANUP_APP=0
    if [[ -z "$APP_DIR" ]]; then
        APP_DIR="$(mktemp -d)/ServedMediaProbe"
        [[ "$KEEP" == 0 ]] && CLEANUP_APP=1
    fi

    echo "→ building the CLI"
    (cd "$REPO" && swift build --product swift-pwa) >/dev/null 2>&1 || {
        echo "::error::couldn't build swift-pwa"; exit 1; }

    if [[ ! -d "$APP_DIR" ]]; then
        echo "→ scaffolding a probe app in $APP_DIR"
        mkdir -p "$(dirname "$APP_DIR")"
        (cd "$(dirname "$APP_DIR")" && "$CLI" init "$(basename "$APP_DIR")") >/dev/null || {
            echo "::error::swift-pwa init failed"; exit 1; }
    fi

    # `swift-pwa init` pins the released package; point it at this checkout,
    # or every check below measures the shipped backend. A path dependency's
    # identity is its directory's name, so a checkout called anything but
    # swift-pwa needs the product references renamed with it.
    python3 - "$APP_DIR/Package.swift" "$REPO" <<'PY'
import os, re, sys
path, repo = sys.argv[1], sys.argv[2]
source = open(path).read()
patched = re.sub(r'\.package\(url: "[^"]*swift-pwa"[^)]*\)', f'.package(path: "{repo}")', source)
patched = patched.replace('package: "swift-pwa"', f'package: "{os.path.basename(repo)}"')
if patched != source:
    open(path, "w").write(patched)
    print("    repointed Package.swift at the working tree")
PY
    cp "$REPO"/Scripts/media-probe/* "$APP_DIR/web/"

    echo "→ building the probe app"
    (cd "$APP_DIR" && swift build) >/dev/null 2>&1 || {
        echo "::error::the probe app didn't build"; (cd "$APP_DIR" && swift build 2>&1 | tail -20); exit 1; }
    BINARY="$(cd "$APP_DIR" && swift build --show-bin-path)/$(basename "$APP_DIR")"
    [[ -x "$BINARY" ]] || { echo "::error::couldn't find the built probe binary"; exit 1; }

    # --- Launch and attach --------------------------------------------------
    LOG="$(mktemp)"
    LAUNCH=("$BINARY")
    [[ "$PLATFORM" == "linux" && -z "${DISPLAY:-}" ]] && LAUNCH=(xvfb-run -a "$BINARY")
    # Its own process group, so teardown takes xvfb-run's Xvfb with it (see
    # Scripts/verify-driven-input.sh for what an orphaned one does).
    SETSID=()
    command -v setsid >/dev/null 2>&1 && SETSID=(setsid)
    ${SETSID[@]+"${SETSID[@]}"} env SWIFT_PWA_WEB_ROOT="$APP_DIR/web" SWIFT_PWA_DRIVE=0 \
        SWIFT_PWA_DRIVE_BACKGROUND=1 "${LAUNCH[@]}" >"$LOG" 2>&1 &
    APP_PID=$!
    disown "$APP_PID" 2>/dev/null || true
    cleanup() {
        kill -- -"$APP_PID" 2>/dev/null || kill "$APP_PID" 2>/dev/null
        rm -f "$LOG"
        [[ "$CLEANUP_APP" == 1 ]] && rm -rf "$(dirname "$APP_DIR")"
        return 0
    }
    trap cleanup EXIT

    for _ in $(seq 1 120); do
        line="$(grep -m1 'driver listening' "$LOG" 2>/dev/null)"
        if [[ -n "$line" ]]; then
            PORT="$(sed -n 's/.*port=\([0-9]*\).*/\1/p' <<<"$line")"
            TOKEN="$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' <<<"$line")"
            break
        fi
        kill -0 "$APP_PID" 2>/dev/null || { echo "::error::the probe app exited:"; cat "$LOG"; exit 1; }
        sleep 0.5
    done
    [[ -n "$PORT" && -n "$TOKEN" ]] || { echo "::error::the app never printed its driver port"; cat "$LOG"; exit 1; }
fi

drive() { "$CLI" drive "$@" --attach "$PORT" --token "$TOKEN" --timeout 120; }

echo "→ driving the app on $PLATFORM (port $PORT)"
drive eval "location.href" --wait "typeof probeFormat === 'function'" >/dev/null || {
    echo "::error::the media probe page never loaded — is Scripts/media-probe/ the web root?"; exit 1; }

CHECKED=0
for format in "webm video/webm" "mp4 video/mp4"; do
    set -- $format
    ext="$1"; type="$2"
    # `drive eval` answers a JSON document whose value is the JSON string the
    # page built — decode both layers rather than pattern-match escaped text.
    if ! RESULT="$(drive eval "probeFormat('$ext', '$type').then(JSON.stringify)")"; then
        fail "$ext: the probe threw" "$RESULT"
        continue
    fi
    # Bash 3.2 on macOS has no mapfile; one "name<TAB>value" line per field.
    FIELDS="$(python3 -c '
import json, sys
r = json.loads(json.loads(sys.stdin.read()))
for k, v in r.items():
    print(f"{k}\t{v}")
' <<<"$RESULT")" || { fail "$ext: unreadable result" "$RESULT"; continue; }
    get() { awk -F '\t' -v k="$1" '$1 == k { print $2 }' <<<"$FIELDS"; }

    if [[ "$(get blob)" != "canplay" ]]; then
        skip "$ext" "the blob: control didn't play ($(get blob)), so this box has no decoder for it"
        continue
    fi
    CHECKED=$((CHECKED+1))
    pass "$ext: control — the same bytes through a blob: URL"
    for how in markup source property setAttribute innerHTML audio; do
        value="$(get "$how")"
        if [[ "$value" == "canplay" ]]; then pass "$ext: $how"; else fail "$ext: $how" "$value"; fi
    done
    value="$(get seek)"
    if [[ "$value" == "18.0" ]]; then pass "$ext: seek to 18 s"; else fail "$ext: seek to 18 s" "landed at: $value"; fi
    if [[ "$(get reads)" == "$(get expectedReads)" ]]; then
        pass "$ext: src, currentSrc and getAttribute read the app's own URL"
    else
        fail "$ext: src, currentSrc and getAttribute read the app's own URL" "got: $(get reads)"
    fi
    value="$(get canvas)"
    if [[ "$value" == "readable" ]]; then pass "$ext: a crossorigin frame stays readable"; else fail "$ext: a crossorigin frame stays readable" "$value"; fi
done

echo
echo "Result: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$CHECKED" == 0 ]]; then
    echo "::error::no format could be checked — this box decodes neither clip"
    exit 1
fi
[[ "$FAIL" == 0 ]]
