#!/usr/bin/env bash
#
# Check that a page and the app's Swift code both get to finish their work when
# a window closes or the app quits (#281), on macOS and Linux (GTK3 or GTK4 —
# whichever the checkout is built for). Windows has the .ps1 beside this.
#
# Each row launches a fresh scaffolded app with a probe (close-flush-probe/)
# that writes a marker line, synchronously, from every place a page or an app
# can hear it's going: `willClose` on `window.subscribe`, `visibilitychange` to
# hidden, `pagehide`, a 300ms-slow invoke posted from `pagehide` (proof the
# runtime waited for it, not just received it), and a Swift `beforeClose`
# handler. The markers are read off disk after the window or process has gone.
#
# The control is navigation, which already worked before #281: the synchronous
# `pagehide` write lands. If it doesn't, the probe is broken and every other row
# means nothing.
#
# Usage:
#   Scripts/verify-close-flush.sh [--app-dir <dir>] [--keep] [--only <row>]
#
#   Rows: navigate | window.close | app.quit | shortcut | last-window (macOS) |
#         sigterm | wm-close (Linux, needs a window manager + xdotool) | hang
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""
KEEP=0
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$(uname -s)" in
    Darwin) PLATFORM=macos; MOD=command; ACTIVATE=(--activate) ;;
    *)      PLATFORM=linux; MOD=control; ACTIVATE=() ;;
esac

WORK="$(mktemp -d)"
cleanup() { [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null; [[ "$KEEP" == 1 ]] || rm -rf "$WORK"; }
trap cleanup EXIT
[[ -n "$APP_DIR" ]] || APP_DIR="$WORK/CloseFlushProbe"
CLI="$REPO/.build/debug/swift-pwa"

echo "→ building the CLI"
(cd "$REPO" && swift build --product swift-pwa) >/dev/null 2>&1 || {
    echo "::error::couldn't build swift-pwa"; exit 1; }

if [[ ! -d "$APP_DIR" ]]; then
    echo "→ scaffolding a probe app in $APP_DIR"
    mkdir -p "$(dirname "$APP_DIR")"
    (cd "$(dirname "$APP_DIR")" && "$CLI" init "$(basename "$APP_DIR")") >/dev/null || {
        echo "::error::swift-pwa init failed"; exit 1; }
fi

# Repoint the scaffold at this checkout (it pins the released package), and
# rename the dependency's package to the checkout's directory name, which is
# what SwiftPM calls a path dependency.
python3 - "$APP_DIR" "$REPO" <<'PY'
import pathlib, re, sys
app_dir, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
manifest = app_dir / "Package.swift"
text = manifest.read_text()
text = re.sub(r'\.package\(url: "[^"]*swift-pwa"[^)]*\)', f'.package(path: "{repo}")', text)
text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
manifest.write_text(text)

app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text = app_swift.read_text()
if "registerCloseProbe(ctx)" not in text:
    text, count = re.subn(r'(?m)^func configure\(_ ctx: any AppContext\) throws \{\n',
                          'func configure(_ ctx: any AppContext) throws {\n    registerCloseProbe(ctx)\n', text)
    assert count == 1, "the scaffold's configure moved; this patch needs updating"
    app_swift.write_text(text)
PY
cp "$REPO/Scripts/close-flush-probe/Probe.swift" "$APP_DIR/Sources/$(basename "$APP_DIR")/Probe.swift"
cp "$REPO/Scripts/close-flush-probe/index.html" "$REPO/Scripts/close-flush-probe/second.html" "$APP_DIR/web/"

echo "→ building the probe app"
(cd "$APP_DIR" && swift build) >/dev/null 2>&1 || {
    echo "::error::the probe app didn't build"; (cd "$APP_DIR" && swift build 2>&1 | grep -E "error" | head -20); exit 1; }
BINARY="$(cd "$APP_DIR" && swift build --show-bin-path)/$(basename "$APP_DIR")"

PASS=0; FAIL=0
PORT=47900

# launch <log> [background 0|1] [hang 0|1] — starts the app, waits for `ready`.
launch() {
    local log="$1" background="${2:-1}" hang="${3:-0}" out="$WORK/app.out"
    : > "$log"; : > "$out"
    PORT=$((PORT + 1))
    local env=(SWIFT_PWA_DRIVE="$PORT" SWIFT_PWA_WEB_ROOT="$APP_DIR/web" CLOSE_PROBE_LOG="$log")
    [[ "$background" == 1 ]] && env+=(SWIFT_PWA_DRIVE_BACKGROUND=1)
    [[ "$hang" == 1 ]] && env+=(CLOSE_PROBE_HANG=1)
    env "${env[@]}" "$BINARY" >"$out" 2>&1 &
    APP_PID=$!
    # 30s: a cold WebKit under software rendering on a headless box is slow to
    # its first `load`.
    for i in $(seq 1 300); do
        TOKEN="$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' "$out" | head -1)"
        grep -q '^ready' "$log" 2>/dev/null && [[ -n "$TOKEN" ]] && return 0
        # On GTK4 under a headless display, what the page posts can sit in the
        # web process until the app sends the page something. Nudge it with a
        # no-op eval once a second until it's ready. Only here, before the
        # measurement: during a close the runtime's own traffic to the page
        # (the `willClose` delivery, the departing navigation) does the same.
        (( i % 10 == 0 )) && [[ -n "$TOKEN" ]] && drive eval "1"
        sleep 0.1
    done
    echo "  FAIL  the app never became ready: $(tr '\n' ' ' < "$out" | cut -c1-300)"
    FAIL=$((FAIL+1))
    # Left running, it would write into the next row's markers.
    kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
    return 1
}

drive() { "$CLI" drive "$@" --attach "$PORT" --token "$TOKEN" >/dev/null 2>&1; }

# Wait up to $1 seconds for the app to exit; prints how long it took, or "running".
wait_exit() {
    local start; start=$(python3 -c 'import time; print(time.time())')
    for _ in $(seq 1 $(( $1 * 20 ))); do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            python3 -c "import time; print(f'{time.time() - $start:.1f}s')"
            APP_PID=""
            return 0
        fi
        sleep 0.05
    done
    echo running
}

# check <row> <log> <exit-state> <want-exit: exits|stays|any> <markers…>
check() {
    local row="$1" log="$2" state="$3" want="$4"; shift 4
    local got missing=()
    got="$(tr '\n' ' ' < "$log")"
    for m in "$@"; do grep -qx "$m" "$log" || missing+=("$m"); done
    local exit_ok=1
    [[ "$want" == exits && "$state" == running ]] && exit_ok=0
    [[ "$want" == stays && "$state" != running ]] && exit_ok=0
    if [[ ${#missing[@]} == 0 && $exit_ok == 1 ]]; then
        echo "  PASS  $row — [$got] process: $state"; PASS=$((PASS+1))
    else
        echo "  FAIL  $row — missing: [${missing[*]}] process: $state (wanted $want); got [$got]"; FAIL=$((FAIL+1))
    fi
    if [[ -n "${APP_PID:-}" ]]; then kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""; fi
}

wanted() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
PAGE=(willClose pagehide pagehide-slow)
LOG="$WORK/markers.txt"

echo "→ running on $PLATFORM"

if wanted navigate && launch "$LOG"; then
    drive eval "location.href = 'second.html'; 1"
    sleep 1.5
    # Not `pagehide-slow`: an ordinary navigation cancels the old document's
    # in-flight invokes once the next one arrives, by design. Only a closing
    # window waits for them.
    check "navigate (control)" "$LOG" "$(wait_exit 0)" stays pagehide second
    if [[ $FAIL -gt 0 ]]; then
        echo "::error::the control failed — the probe can't see a page's teardown, so no other row means anything"
        exit 1
    fi
fi

if wanted window.close && launch "$LOG"; then
    drive eval "__SWIFT_PWA__.invoke('window.close'); 1"
    STATE="$(wait_exit 5)"
    # Closing the only window quits the app on Linux, and leaves it running on
    # macOS (the `reopen` policy).
    if [[ $PLATFORM == macos ]]; then
        check "window.close" "$LOG" "$STATE" stays "${PAGE[@]}" swift:window
    else
        check "window.close" "$LOG" "$STATE" exits "${PAGE[@]}" swift:window swift:quit
    fi
fi

if wanted app.quit && launch "$LOG"; then
    drive eval "setTimeout(() => __SWIFT_PWA__.invoke('app.quit', {}), 50); 1"
    check "app.quit" "$LOG" "$(wait_exit 6)" exits "${PAGE[@]}" swift:quit
fi

if wanted shortcut && launch "$LOG" 0; then
    SHORTCUT="$([[ $MOD == command ]] && echo ⌘Q || echo Ctrl+Q)"
    drive type --key q --modifiers "$MOD" "${ACTIVATE[@]}"
    STATE="$(wait_exit 6)"
    if [[ "$STATE" == running ]] && ! grep -qv '^ready' "$LOG"; then
        # Nothing happened at all: the keystroke never reached the app. GTK4's
        # synthetic input goes through XTEST, which needs a focused window
        # under a window manager — bare Xvfb has none.
        echo "  SKIP  $SHORTCUT — the keystroke didn't reach the app (no focus to deliver it to?)"
        kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
    else
        check "$SHORTCUT" "$LOG" "$STATE" exits "${PAGE[@]}" swift:quit
    fi
fi

if [[ $PLATFORM == macos ]] && wanted last-window && launch "$LOG"; then
    drive eval "__SWIFT_PWA__.invoke('app.lastWindowClosed', { value: 'quit' }).then(() => __SWIFT_PWA__.invoke('window.close')); 1"
    check "last window closed, policy quit" "$LOG" "$(wait_exit 6)" exits "${PAGE[@]}" swift:window swift:quit
fi

if wanted sigterm && launch "$LOG"; then
    kill -TERM "$APP_PID"
    check "SIGTERM" "$LOG" "$(wait_exit 6)" exits "${PAGE[@]}" swift:system
fi

# The window manager's own close (WM_DELETE_WINDOW → `delete-event` /
# `close-request`), which is what the title-bar button and Alt+F4 send. Needs a
# window manager on the display and xdotool to ask it.
if [[ $PLATFORM == linux ]] && wanted wm-close; then
    if ! command -v xdotool >/dev/null; then
        echo "  SKIP  window-manager close — no xdotool on this box"
    elif launch "$LOG" 0; then
        WID="$(xdotool search --sync --onlyvisible --pid "$APP_PID" 2>/dev/null | head -1)"
        xdotool windowactivate --sync "$WID" key --clearmodifiers alt+F4 2>/dev/null
        check "window-manager close (Alt+F4)" "$LOG" "$(wait_exit 6)" exits "${PAGE[@]}" swift:window swift:quit
    fi
fi

if wanted hang && launch "$LOG" 1 1; then
    drive eval "setTimeout(() => __SWIFT_PWA__.invoke('app.quit', {}), 50); 1"
    # The quit budget is 3s; a hung handler mustn't stretch it much past that.
    check "app.quit with a beforeClose handler that never returns" "$LOG" "$(wait_exit 5)" exits "${PAGE[@]}" swift:quit
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
