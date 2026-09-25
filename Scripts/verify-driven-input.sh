#!/usr/bin/env bash
#
# Drive a real app and check that keyboard, editing and drag actually work.
#
# Why this exists: the keyboard and editing fixes in #163 were each verified by
# hand on real hardware, and CI only *compiles* the backends — so all of them
# could regress silently (#164). A menu is a data structure you can assert on
# without running anything (`MainMenuTests` does), but "does this keystroke edit
# this field" is behaviour, and behaviour needs a driven app.
#
# It runs against whichever backend the box it runs on has, and reports what
# that backend can and can't do rather than assuming. `drive info` is consulted
# first: where synthetic input is unavailable (iOS, or a Wayland session on
# GTK4) the input checks are SKIPped, not silently passed.
#
# Usage:
#   Scripts/verify-driven-input.sh [--app-dir <dir>] [--keep] [--only <name>]
#                                  [--background]
#
#   --app-dir <dir>  where to build the probe app. Default: a temp dir.
#   --keep           don't delete the probe app afterwards (for iterating).
#   --only <name>    run one check: control | editing | undo | preventdefault |
#                    focus | drag | wheel
#   --background     launch with SWIFT_PWA_DRIVE_BACKGROUND=1 — the parked,
#                    never-activated window an e2e suite runs in (#208). Input
#                    has to reach it too, and wheel once didn't (#264).
#
# Two traps this is written around, both of which produce a green run that
# proves nothing (see #164):
#
#   1. The obvious editing sequence round-trips. Select-all, copy, paste, cut,
#      undo returns the field to exactly what it started as — which is equally
#      consistent with everything working and with only select-all working. Every
#      step below leaves a *distinct* value.
#
#   2. A quiet environment is not a passing test. A locked macOS screen has no
#      key window, and a Windows SSH session has no interactive desktop; in both,
#      every shortcut fails in a way indistinguishable from a broken fix. So the
#      first check is a CONTROL that must land, and the run aborts if it doesn't
#      rather than reporting the rest as failures.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""
KEEP=0
ONLY=""
BACKGROUND=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --background) BACKGROUND=1; shift ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $1 — $2"; SKIP=$((SKIP+1)); }
wanted() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

# --- Platform differences ---------------------------------------------------
# Not a detail: on macOS the editing shortcuts are *main-menu key equivalents*,
# dispatched to the key window, which an inactive app doesn't have — so they do
# nothing at all without --activate. Elsewhere they're page/embedder bindings
# and work backgrounded.
case "$(uname -s)" in
    Darwin) MOD="command"; ACTIVATE="--activate"; PLATFORM="macos" ;;
    Linux)  MOD="control"; ACTIVATE="";           PLATFORM="linux" ;;
    *)      MOD="control"; ACTIVATE="";           PLATFORM="windows" ;;
esac

# --- Probe app --------------------------------------------------------------
CLEANUP_APP=0
if [[ -z "$APP_DIR" ]]; then
    APP_DIR="$(mktemp -d)/DrivenInputProbe"
    [[ "$KEEP" == 0 ]] && CLEANUP_APP=1
fi
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

# `swift-pwa init` pins the app to the last *released* package, so an app
# scaffolded here would test the shipped backend and quietly ignore every local
# change. Point it at this checkout instead. (Measured the hard way: a whole
# round of drag measurements turned out to be of the released binary.)
python3 - "$APP_DIR/Package.swift" "$REPO" <<'PY'
import re, sys
path, repo = sys.argv[1], sys.argv[2]
source = open(path).read()
patched = re.sub(
    r'\.package\(url: "[^"]*swift-pwa"[^)]*\)',
    f'.package(path: "{repo}")',
    source,
)
if patched != source:
    open(path, "w").write(patched)
    print("    repointed Package.swift at the working tree")
PY

cp "$REPO/Scripts/driver-probe/index.html" "$APP_DIR/web/index.html"

echo "→ building the probe app"
(cd "$APP_DIR" && swift build) >/dev/null 2>&1 || {
    echo "::error::the probe app didn't build"; (cd "$APP_DIR" && swift build 2>&1 | tail -20); exit 1; }

# --- Launch and attach ------------------------------------------------------
# One long-lived app for every check: `drive` owns the app's lifecycle by
# default, which would mean a fresh window (and a fresh page) per assertion.
# Ask SwiftPM where it put the binary: the layout moved under Swift 6.4's
# build engine (`.build/out/Products/Debug`, behind a `debug` symlink), and a
# search written for the old one finds nothing.
BINARY="$(cd "$APP_DIR" && swift build --show-bin-path)/$(basename "$APP_DIR")"
[[ -x "$BINARY" ]] || { echo "::error::couldn't find the built probe binary"; exit 1; }

LOG="$(mktemp)"
LAUNCH=("$BINARY")
# Under Xvfb where there's no display: GTK4's input goes through XTEST, which
# is an X server extension, so it needs *a* display even though it needs no
# input device.
if [[ "$PLATFORM" == "linux" && -z "${DISPLAY:-}" ]]; then
    LAUNCH=(xvfb-run -a "$BINARY")
fi

# `setsid` so the whole launch is its own process group, and teardown can kill
# the group rather than just the process we started. Under `xvfb-run` that is
# the difference between cleaning up and not: `$!` is xvfb-run's pid, so
# signalling it alone leaves the app *and* its Xvfb running — and those inherit
# the caller's stdout, so an orphaned Xvfb holds the pipe open and hangs
# whatever invoked this script, long after the checks have finished.
# macOS has no `setsid`, and doesn't need it: nothing wraps the binary there,
# so the pid we get is the app's own.
SETSID=()
command -v setsid >/dev/null 2>&1 && SETSID=(setsid)

# The `[@]+` form because macOS ships bash 3.2, where expanding an empty array
# under `set -u` is an unbound-variable error.
${SETSID[@]+"${SETSID[@]}"} env SWIFT_PWA_WEB_ROOT="$APP_DIR/web" SWIFT_PWA_DRIVE=0 \
    SWIFT_PWA_DRIVE_BACKGROUND="$BACKGROUND" "${LAUNCH[@]}" >"$LOG" 2>&1 &
APP_PID=$!
# Off the job table, so tearing it down doesn't print bash's own
# "Terminated: 15" line over the results.
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

# stdout only. `drive` warns on stderr whenever the target window isn't on
# screen — true for every backgrounded run, which is the normal case here — and
# folding that into stdout turns each JSON reply into unparseable text.
drive() { "$CLI" drive "$@" --attach "$PORT" --token "$TOKEN"; }
# `drive eval` prints a JSON document; strip the quotes off a bare string.
evaljs() { drive eval "$1" | sed 's/^"//; s/"$//'; }

echo "→ driving $(basename "$BINARY") on $PLATFORM (port $PORT)$([[ $BACKGROUND == 1 ]] && echo ', backgrounded')"

# --- What can this backend actually do? -------------------------------------
CAPS="$(drive info)"
HAS_KEY="$(python3 -c "
import json,sys
caps = json.loads(sys.stdin.read())
i = caps.get('input') or {}
print('1' if i.get('key') else '0')
" <<<"$CAPS" 2>/dev/null || echo 0)"
HAS_POINTER="$(python3 -c "
import json,sys
caps = json.loads(sys.stdin.read())
i = caps.get('input') or {}
print('1' if i.get('pointer') else '0')
" <<<"$CAPS" 2>/dev/null || echo 0)"
DELIVERY="$(python3 -c "
import json,sys
caps = json.loads(sys.stdin.read())
print((caps.get('input') or {}).get('delivery','?'))
" <<<"$CAPS" 2>/dev/null || echo '?')"
echo "   input: key=$HAS_KEY pointer=$HAS_POINTER delivery=$DELIVERY"

# XTEST delivers to whatever holds input focus, so the window has to be raised
# before anything is driven. Harmless where input goes into the app's own queue.
if [[ "$DELIVERY" == "displayServer" ]]; then
    drive eval "window.focus()" >/dev/null
fi

# --- 1. Control: a keystroke that MUST land ---------------------------------
# Trap 2. Without this, every failure below is ambiguous between "the fix is
# broken" and "this environment can't deliver a keystroke at all".
if [[ "$HAS_KEY" == 1 ]]; then
    evaljs "__setField('')" >/dev/null
    drive type "x" --selector "#field" >/dev/null
    CONTROL="$(evaljs "__field()")"
    if [[ "$CONTROL" == "x" ]]; then
        wanted control && pass "control: a plain keystroke reaches a focused field"
    else
        fail "control: a plain keystroke reaches a focused field" \
             "typed 'x', field holds '$CONTROL' — every check below would be meaningless, stopping here"
        echo; echo "Result: $PASS passed, $FAIL failed, $SKIP skipped"
        exit 1
    fi
else
    skip "control" "this backend can't synthesize key events"
fi

# --- 1b. Control: can the app become active? --------------------------------
# macOS only, and the other half of trap 2. The editing shortcuts there are
# main-menu *key equivalents*, dispatched with a nil target through
# `NSApp.keyWindow` — which an app that isn't active doesn't have. So they fail
# identically whether the fix is broken or the session simply has no window
# server to become active in (a locked screen, or an SSH/CI shell with no GUI
# login). Typing still works in both, so the control above can't tell them
# apart; `document.hasFocus()` after an --activate keystroke can.
CAN_ACTIVATE=1
# Only for the checks that need it: activating takes over the screen, which a
# `--only wheel` or `--background` run exists to avoid.
if [[ "$PLATFORM" == "macos" && "$HAS_KEY" == 1 ]] && { wanted editing || wanted undo || wanted preventdefault; }; then
    drive type --key a --modifiers command --activate >/dev/null
    if [[ "$(drive eval "document.hasFocus()")" != "true" ]]; then
        CAN_ACTIVATE=0
        echo "   note: the app can't become active in this session — menu key equivalents"
        echo "         can't dispatch at all here. Run this from a logged-in desktop."
    fi
fi

MENU_REASON="the app can't become active in this session (locked screen, or a shell with no GUI login)"

# --- 2. Editing shortcuts, each step leaving a distinct value ---------------
UNDO_OK=0
if wanted editing; then
    if [[ "$HAS_KEY" == 1 && "$CAN_ACTIVATE" == 1 ]]; then
        evaljs "__setField('alpha')" >/dev/null
        drive type --key a --modifiers "$MOD" $ACTIVATE >/dev/null   # select all
        drive type --key x --modifiers "$MOD" $ACTIVATE >/dev/null   # cut
        AFTER_CUT="$(evaljs "__field()")"
        drive type "beta" >/dev/null
        AFTER_TYPE="$(evaljs "__field()")"
        if [[ "$AFTER_CUT" == "" && "$AFTER_TYPE" == "beta" ]]; then
            pass "editing: select-all, cut and typing each leave a distinct value"
        else
            fail "editing: select-all, cut and typing each leave a distinct value" \
                 "cut→'$AFTER_CUT' (want ''), type→'$AFTER_TYPE' (want 'beta')"
        fi

        # Paste is its own check: on Windows the *driver* can't reach the system
        # clipboard (see verify-driven-input.ps1), so asserting it in the same
        # step would make one platform's driver limitation look like an editing
        # regression on all of them.
        drive type --key v --modifiers "$MOD" $ACTIVATE >/dev/null
        AFTER_PASTE="$(evaljs "__field()")"
        if [[ "$AFTER_PASTE" == "betaalpha" ]]; then
            pass "clipboard: cut and paste round-trip through the system clipboard"
        else
            fail "clipboard: cut and paste round-trip through the system clipboard" \
                 "after paste the field holds '$AFTER_PASTE' (want 'betaalpha')"
        fi
    elif [[ "$CAN_ACTIVATE" == 0 ]]; then
        skip "editing" "$MENU_REASON"
    else
        skip "editing" "this backend can't synthesize key events"
    fi
fi

# --- 3. Undo and redo -------------------------------------------------------
if wanted undo; then
    if [[ "$HAS_KEY" == 1 && "$CAN_ACTIVATE" == 1 ]]; then
        evaljs "__setField('')" >/dev/null
        drive type "abc" --selector "#field" >/dev/null
        drive type --key z --modifiers "$MOD" $ACTIVATE >/dev/null
        AFTER_UNDO="$(evaljs "__field()")"
        drive type --key z --modifiers "$MOD,shift" $ACTIVATE >/dev/null
        AFTER_REDO="$(evaljs "__field()")"
        # Undo granularity differs per engine (typed runs may or may not
        # coalesce), so assert that undo *changed* something and redo put it
        # back — both true only if the whole path works.
        if [[ "$AFTER_UNDO" != "abc" && "$AFTER_REDO" == "abc" ]]; then
            UNDO_OK=1
            pass "undo: type, undo, redo round-trips through the embedder"
        else
            fail "undo: type, undo, redo round-trips through the embedder" \
                 "typed 'abc', undo→'$AFTER_UNDO' (want anything else), redo→'$AFTER_REDO' (want 'abc')"
        fi
    elif [[ "$CAN_ACTIVATE" == 0 ]]; then
        skip "undo" "$MENU_REASON"
    else
        skip "undo" "this backend can't synthesize key events"
    fi
fi

# --- 4. The page keeps the undo key when it claims it -----------------------
# The regression the Linux binding was designed around: bind undo as an
# accelerator and it fires *before* the page, taking Ctrl+Z away from any app
# that implements its own undo (a drawing app, an editor).
if wanted preventdefault; then
    # Only meaningful once undo is known to work: "the field didn't change" is
    # equally true of a page that kept the key and of an undo that never fired,
    # so running this against a broken undo would pass by not testing anything.
    if [[ "$HAS_KEY" == 1 && "$UNDO_OK" == 1 ]]; then
        evaljs "__setField('')" >/dev/null
        drive type "xyz" --selector "#field" >/dev/null
        evaljs "__probe.swallowUndo = true, 'on'" >/dev/null
        drive type --key z --modifiers "$MOD" $ACTIVATE >/dev/null
        SWALLOWED="$(evaljs "__field()")"
        SAW="$(drive eval "__probe.sawUndoKey")"
        evaljs "__probe.swallowUndo = false, 'off'" >/dev/null
        if [[ "$SWALLOWED" == "xyz" && "$SAW" != "0" ]]; then
            pass "preventDefault: a page that claims the undo key keeps it"
        else
            fail "preventDefault: a page that claims the undo key keeps it" \
                 "page saw the key $SAW time(s) and field is '$SWALLOWED' (want 'xyz' — unchanged)"
        fi
    elif [[ "$HAS_KEY" == 1 ]]; then
        skip "preventDefault" "undo didn't work here, so 'the page kept the key' would prove nothing"
    else
        skip "preventDefault" "this backend can't synthesize key events"
    fi
fi

# --- 5. A fresh window takes typing with no click first ---------------------
# Windows needed WM_SETFOCUS → MoveFocus for this: activating the host window
# doesn't focus the web content, so every keystroke went nowhere until the user
# clicked inside it.
if wanted focus; then
    if [[ "$HAS_KEY" == 1 ]]; then
        evaljs "__setField('')" >/dev/null
        # focus() from the page, then type with no pointer event at all.
        evaljs "document.getElementById('field').focus(), 'ok'" >/dev/null
        drive type "k" >/dev/null
        FOCUSED="$(evaljs "__field()")"
        if [[ "$FOCUSED" == "k" ]]; then
            pass "focus: typing lands without a click first"
        else
            fail "focus: typing lands without a click first" \
                 "typed 'k' into a focused field, got '$FOCUSED'"
        fi
    else
        skip "focus" "this backend can't synthesize key events"
    fi
fi

# --- 6. Drag ----------------------------------------------------------------
if wanted drag; then
    if [[ "$HAS_POINTER" == 1 ]]; then
        evaljs "__reset()" >/dev/null
        drive drag --from 70,150 --to 400,150 --to 400,320 --duration 400 >/dev/null
        REPORT="$(drive eval "JSON.stringify({
            moves: __probe.moves.length,
            trusted: __probe.trusted,
            corner: __probe.moves.some(m => m.x === 400 && m.y === 150),
            speed: __probe.endSpeed,
            left: document.getElementById('box').style.left
        })")"
        OK="$(python3 -c "
import json,sys
raw = sys.stdin.read().strip()
# drive prints the JSON string; unwrap it, then parse the object inside.
r = json.loads(json.loads(raw)) if raw.startswith('\"') else json.loads(raw)
problems = []
if not r.get('trusted'): problems.append('events were not trusted')
if r.get('moves', 0) < 5: problems.append(f\"only {r.get('moves')} move(s) reached the page\")
if not r.get('corner'): problems.append('the path did not pass through its corner')
if not r.get('speed'): problems.append('no end-of-gesture velocity — the moves had no spacing')
if not r.get('left'): problems.append('the page did not move anything')
print('; '.join(problems))
" <<<"$REPORT" 2>/dev/null)"
        if [[ -z "$OK" ]]; then
            pass "drag: a multi-segment gesture delivers a real, paced path"
        else
            fail "drag: a multi-segment gesture delivers a real, paced path" "$OK ($REPORT)"
        fi
    else
        skip "drag" "this backend can't synthesize pointer events"
    fi
fi

# --- 7. Wheel ---------------------------------------------------------------
# Two facts, checked separately: the event reached the page, trusted, and it
# scrolled the element under it. A wheel that returns success and delivers
# nothing (#264) reads as a scroll-chaining bug in whatever test used it.
if wanted wheel; then
    HAS_WHEEL="$(python3 -c "
import json,sys
print('1' if (json.loads(sys.stdin.read()).get('input') or {}).get('wheel') else '0')
" <<<"$CAPS" 2>/dev/null || echo 0)"
    if [[ "$HAS_WHEEL" == 1 ]]; then
        evaljs "__reset()" >/dev/null
        drive scroll 120 --selector "#scroller" >/dev/null
        REPORT="$(drive eval "JSON.stringify({ wheels: __probe.wheels, top: document.getElementById('scroller').scrollTop })")"
        OK="$(python3 -c "
import json,sys
raw = sys.stdin.read().strip()
r = json.loads(json.loads(raw)) if raw.startswith('\"') else json.loads(raw)
w = r.get('wheels') or []
problems = []
if not w: problems.append('no wheel event reached the page')
elif not all(e[2] for e in w): problems.append('wheel events were not trusted')
elif not any(e[1] == 'scroller' for e in w): problems.append('no wheel event targeted #scroller')
if not r.get('top'): problems.append('#scroller did not scroll')
print('; '.join(problems))
" <<<"$REPORT" 2>/dev/null)"
        if [[ -z "$OK" ]]; then
            pass "wheel: a scroll reaches the page trusted and scrolls the element under it"
        else
            fail "wheel: a scroll reaches the page trusted and scrolls the element under it" "$OK ($REPORT)"
        fi
    elif [[ "$BACKGROUND" == 1 ]]; then
        # A backend that can't reach a parked window must say so when asked,
        # not return success for a scroll that never happened (#264).
        if OUT="$("$CLI" drive scroll 120 --selector "#scroller" --attach "$PORT" --token "$TOKEN" 2>&1)"; then
            fail "wheel: refused, not dropped, in a backgrounded run" \
                 "drive info reports no wheel, yet drive scroll succeeded: $OUT"
        elif grep -q "background" <<<"$OUT"; then
            pass "wheel: refused, not dropped, in a backgrounded run"
        else
            fail "wheel: refused, not dropped, in a backgrounded run" "failed without naming --background: $OUT"
        fi
    else
        skip "wheel" "this backend can't synthesize wheel events"
    fi
fi

echo
echo "Result: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" == 0 ]]
