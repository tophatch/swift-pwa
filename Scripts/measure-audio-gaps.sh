#!/usr/bin/env bash
#
# Measure what a page can and can't do with audio, in this box's webview.
#
# Why this exists: the README roadmap proposes a native audio plugin on the
# premise that the webview's own stack is too weak to build on. That premise had
# never been checked. Audio is also the case the "data-shaped → plugin,
# stream-shaped → keep the web API" rule was written about, so the difference
# between a gap and an assumption decides whether the plugin exists at all, and
# what goes in it.
#
# It measures rather than asserts: there is no pass/fail here, only a JSON
# record per engine, because the interesting output is the *shape of the
# difference* between the four engines — which is not something a threshold can
# express.
#
# Usage:
#   Scripts/measure-audio-gaps.sh [--app-dir <dir>] [--keep] [--mic] [--occluded]
#
#   --app-dir <dir>  where to build the probe app. Default: a temp dir.
#   --keep           don't delete the probe app afterwards (for iterating).
#   --mic            also run the capture check. Raises the OS microphone
#                    prompt, so it needs someone at the machine the first time.
#   --occluded       also measure the clocks with the window off screen, which
#                    is the state a read-aloud app spends most of its life in.
#
# Android and iOS aren't reachable from here: run it through
# Scripts/android-cdp-eval.py and `swift-pwa drive --target ios` respectively,
# against the same page (Scripts/audio-probe/index.html).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""; KEEP=0; MIC=0; OCCLUDED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --mic) MIC=1; shift ;;
        --occluded) OCCLUDED=1; shift ;;
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      PLATFORM="windows" ;;
esac

CLI="$REPO/.build/debug/swift-pwa"
echo "→ building the CLI"
(cd "$REPO" && swift build --product swift-pwa) >/dev/null 2>&1 || {
    echo "::error::couldn't build swift-pwa"; exit 1; }

CLEANUP_APP=0
if [[ -z "$APP_DIR" ]]; then
    APP_DIR="$(mktemp -d)/AudioGapProbe"
    [[ "$KEEP" == 0 ]] && CLEANUP_APP=1
fi

if [[ ! -d "$APP_DIR" ]]; then
    echo "→ scaffolding a probe app in $APP_DIR"
    mkdir -p "$(dirname "$APP_DIR")"
    (cd "$(dirname "$APP_DIR")" && "$CLI" init "$(basename "$APP_DIR")") >/dev/null || {
        echo "::error::swift-pwa init failed"; exit 1; }
fi

# `swift-pwa init` pins the app to the last *released* package, so a probe built
# here would measure the shipped backend and ignore every local change.
python3 - "$APP_DIR/Package.swift" "$REPO" <<'PY'
import re, sys
path, repo = sys.argv[1], sys.argv[2]
source = open(path).read()
patched = re.sub(r'\.package\(url: "[^"]*swift-pwa"[^)]*\)', f'.package(path: "{repo}")', source)
if patched != source:
    open(path, "w").write(patched)
    print("    repointed Package.swift at the working tree")
PY

# Nothing is permitted until it's declared (v0.10.0), and an undeclared
# microphone is refused *before* the OS is ever asked — which would read here as
# the engine lacking capture.
python3 - "$APP_DIR/pwa.json" <<'PY'
import json, sys
path = sys.argv[1]
config = json.load(open(path))
web = config.setdefault("permissions", {}).setdefault("web", {})
web.setdefault("microphone", {"reason": "Measure what the webview's capture path reports."})
json.dump(config, open(path, "w"), indent=2)
PY

cp "$REPO/Scripts/audio-probe/index.html" "$APP_DIR/web/index.html"

# The runtime permission ceiling, which is separate from the pwa.json entry
# above: without it the policy refuses the page's own getUserMedia before the OS
# is ever consulted, and the page sees a plain NotAllowedError — indistinguishable
# from a box with no microphone. (Apple hides this: WKWebView never consults the
# embedder for pwa:// content, so only the other backends actually enforce it.)
python3 - "$APP_DIR/Sources/$(basename "$APP_DIR")/App.swift" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()
anchor = "func configure(_ ctx: any AppContext) throws {\n"
if "permissions.declare" not in source and anchor in source:
    open(path, "w").write(source.replace(anchor, anchor + "    ctx.permissions.declare(.microphone)\n\n", 1))
    print("    declared .microphone on the runtime policy")
PY

echo "→ building the probe app"
(cd "$APP_DIR" && swift build) >/dev/null 2>&1 || {
    echo "::error::the probe app didn't build"; (cd "$APP_DIR" && swift build 2>&1 | tail -20); exit 1; }

BINARY="$(find "$APP_DIR/.build" -maxdepth 3 -name "$(basename "$APP_DIR")" -type f -perm -u+x | head -1)"
[[ -x "$BINARY" ]] || { echo "::error::couldn't find the built probe binary"; exit 1; }

LOG="$(mktemp)"
LAUNCH=("$BINARY")
# Xvfb only when there is no session at all. A Wayland seat has no DISPLAY, so
# testing DISPLAY alone sends a perfectly good desktop into a virtual X server
# — which has no sound device either, and a silent null sink measures as a
# stopped audio clock rather than as a missing prerequisite.
if [[ "$PLATFORM" == "linux" && -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "    (no DISPLAY and no WAYLAND_DISPLAY — falling back to Xvfb; audio results from here are not trustworthy)"
    LAUNCH=(xvfb-run -a "$BINARY")
fi
SETSID=(); command -v setsid >/dev/null 2>&1 && SETSID=(setsid)

${SETSID[@]+"${SETSID[@]}"} env SWIFT_PWA_WEB_ROOT="$APP_DIR/web" SWIFT_PWA_DRIVE=0 "${LAUNCH[@]}" >"$LOG" 2>&1 &
APP_PID=$!
disown "$APP_PID" 2>/dev/null || true

cleanup() {
    kill -- -"$APP_PID" 2>/dev/null || kill "$APP_PID" 2>/dev/null
    rm -f "$LOG"
    [[ "$CLEANUP_APP" == 1 ]] && rm -rf "$(dirname "$APP_DIR")"
    return 0
}
trap cleanup EXIT

PORT=""; TOKEN=""
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

drive() { "$CLI" drive "$@" --attach "$PORT" --token "$TOKEN"; }

# `drive eval` does not await a Promise (it is the engine's plain
# evaluate-JavaScript call), and an un-awaited async check answers `null` —
# which reads exactly like a missing capability. Async checks are therefore
# started by one eval and collected by a later one.
pretty() {
    python3 -c 'import json,sys
raw = sys.stdin.read().strip()
try:
    value = json.loads(raw)
    print(json.dumps(json.loads(value) if isinstance(value, str) else value, indent=2))
except Exception:
    print(raw or "(no reply)")'
}

emit() {  # emit <label> <js-expression>
    echo
    echo "### $1"
    drive eval "$2" 2>/dev/null | pretty
}

emit_async() {  # emit_async <label> <method> [args-js] [timeout-s]
    local label="$1" method="$2" args="${3:-}" budget="${4:-20}"
    echo
    echo "### $label"
    drive eval "__audio.go('$method'${args:+, $args})" >/dev/null 2>&1
    for _ in $(seq 1 "$budget"); do
        local raw
        raw="$(drive eval "__audio.get('$method')" 2>/dev/null)"
        # `drive eval` answers a JSON *document*, so the reply is a quoted
        # string with the payload's own quotes escaped — matching on `"pending"`
        # never fires and every check reports as unfinished.
        if ! grep -q 'pending' <<<"$raw"; then
            printf '%s' "$raw" | pretty
            return
        fi
        sleep 1
    done
    echo "(still pending after ${budget}s)"
}

echo "→ measuring on $PLATFORM"
emit "surface" 'JSON.stringify(__audio.surface())'
emit "audioSession" 'JSON.stringify(__audio.audioSession())'
emit "mediaSource" 'JSON.stringify(__audio.mediaSourceSupport())'
emit_async "mediaSession" mediaSessionLive
emit_async "devices" devices
emit_async "routing" routing
emit_async "clocks (window on screen)" clocks 3000 15
emit_async "scheduleAhead (window on screen)" scheduleAhead 2000 15

# Transport controls: start real playback, post a real hardware media key, read
# back. Only macOS has a poster here; elsewhere the round trip is unmeasured
# rather than reported as absent.
emit_async "transport (playback started)" transport "" 20
if [[ "$PLATFORM" == "macos" ]]; then
    sleep 1
    swift "$REPO/Scripts/audio-probe/press-media-key.swift" play >/dev/null 2>&1 \
        || echo "    (couldn't post a media key — needs Accessibility permission for this terminal)"
    sleep 1
    emit "transport (after a real play key)" '__audio.transportHits()'
else
    echo
    echo "### transport (after a real play key)"
    echo "(no media-key poster on $PLATFORM — unmeasured)"
fi

if [[ "$OCCLUDED" == 1 ]]; then
    # Deliberately *minimised*, not the driver's --background park: on macOS
    # background mode switches WebKit's occlusion detection off, which is the
    # very thing being measured here.
    case "$PLATFORM" in
        macos)   osascript -e 'tell application "System Events" to set visible of (first process whose unix id is '"$APP_PID"') to false' >/dev/null 2>&1 \
                    || echo "    (couldn't hide the window — needs Automation permission for this terminal)" ;;
        linux)   command -v xdotool >/dev/null && xdotool search --pid "$APP_PID" windowminimize %@ >/dev/null 2>&1 \
                    || echo "    (no xdotool — skipping the hide)" ;;
        *)       echo "    (no hide implemented on this platform)" ;;
    esac
    sleep 1
    emit_async "clocks (window hidden)" clocks 5000 20
    emit_async "scheduleAhead (window hidden)" scheduleAhead 2000 20
fi

if [[ "$MIC" == 1 ]]; then
    echo
    echo "  (answer the microphone prompt if one appears)"
    emit_async "capture" capture "" 60
fi

echo
echo "→ done"
