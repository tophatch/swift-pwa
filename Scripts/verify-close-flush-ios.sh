#!/usr/bin/env bash
#
# Check that a backgrounded iOS app finishes what its page and its Swift code
# start on the way out (#281), on a cabled device.
#
# iOS has no quit: an app that goes to the background is suspended, and a
# suspended app can be killed without being told. So the moment to flush is
# backgrounding, and the runtime holds a background task for it. The probe
# (close-flush-probe/, the same one the desktop scripts use) writes a marker
# from the page's `visibilitychange` to hidden, a 300ms-slow invoke posted from
# that same handler, and a Swift `beforeClose` handler (reason `backgrounded`).
#
# The app is backgrounded by launching another one, which is what a user does,
# and the markers are lifted from the app's Documents with `devicectl` after
# it has been in the background for a few seconds — long after a suspended app
# would have stopped running anything.
#
# The control is the page's own synchronous `hidden` marker: if that never
# lands, the page didn't hear it was going and nothing else here means much.
#
# Usage:
#   Scripts/verify-close-flush-ios.sh --team <apple-team-id> [--device <name|udid>]
#                                     [--runs <n>] [--keep] [--no-build]
#                                     [--bundle-id <id>] [--multi-window]
#                                     [--expect-one-window] [--simulator <udid>]
#
# --simulator runs on a booted simulator instead of a device (no --team): the
# same rows, quicker to iterate on, but a simulator is not a device — confirm
# on one before trusting a result.
#
# --multi-window runs the iPad multi-window rows instead (#287), on an app
# built with `ios.multiple_windows`:
#   second-window   the app opens a window (`ctx.createWindow`) and the right
#                   page lands in a scene of its own; its page closes itself
#                   and gets the full teardown, and the first window is never
#                   told it was closing (2 scenes, then 1)
#   system-close    the same window, but the system takes its scene away, as
#                   closing it from the system UI does: still the full teardown
#   system-window   a scene nobody asked for, as "New Window" in the Dock
#                   opens: it gets the app's main page
#   restore         the window in front comes back showing its own page after
#                   the app is killed and relaunched
# With --expect-one-window (an iPhone, which shows one scene at a time) the
# second-window row instead expects `ctx.createWindow` to be refused.
#
# --bundle-id reuses an App ID the team already has: a free team can only
# register a handful of new ones a week, and each probe would otherwise take one.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM="${SWIFT_PWA_IOS_TEAM:-}"
DEVICE=""
RUNS=3
KEEP=0
BUILD=1
BUNDLE_ID_ARG=""
MULTI_WINDOW=0
ONE_WINDOW=0
SIM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --no-build) BUILD=0; KEEP=1; shift ;;
        --bundle-id) BUNDLE_ID_ARG="$2"; shift 2 ;;
        --multi-window) MULTI_WINDOW=1; shift ;;
        --expect-one-window) MULTI_WINDOW=1; ONE_WINDOW=1; shift ;;
        --simulator) SIM="$2"; shift 2 ;;
        *) echo "usage: $0 --team <id> [--device <name|udid>] [--runs <n>] [--keep] [--no-build]" >&2; exit 2 ;;
    esac
done
[ -n "$TEAM" ] || [ -n "$SIM" ] || { echo "--team (or \$SWIFT_PWA_IOS_TEAM) is required — a free personal team is fine" >&2; exit 2; }

WORK="${TMPDIR:-/tmp}/swift-pwa-ios-close-flush-check"
APP="CloseFlushCheck"
APP_DIR="$WORK/$APP"
BUNDLE_ID="${BUNDLE_ID_ARG:-com.example.closeflushcheck}"
DEV=(${DEVICE:+--device "$DEVICE"})

cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

if [ "$BUILD" -eq 1 ]; then
    rm -rf "$WORK"; mkdir -p "$WORK"
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa >/dev/null)
    CLI="$REPO/.build/debug/swift-pwa"

    echo "== scaffolding $APP =="
    (cd "$WORK" && "$CLI" init "$APP" >/dev/null)
    python3 - "$APP_DIR" "$REPO" "$BUNDLE_ID" <<'PY'
import json, pathlib, re, sys
app_dir, repo, bundle_id = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
pwa = app_dir / "pwa.json"
manifest_json = json.loads(pwa.read_text())
manifest_json["ios"]["bundle_identifier"] = bundle_id
manifest_json["ios"]["multiple_windows"] = True
pwa.write_text(json.dumps(manifest_json, indent=2))
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
    # The second window's page: the same probe, with its markers prefixed.
    sed 's/<body /<body data-prefix="w2-" /' "$REPO/Scripts/close-flush-probe/index.html" > "$APP_DIR/web/window2.html"
    cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"

    echo "== building, signing and installing on the device =="
    if [ -n "$SIM" ]; then
        (cd "$APP_DIR" && "$CLI" build --target ios --simulator >/dev/null)
        xcrun simctl boot "$SIM" 2>/dev/null || true
        # A fresh install, so no window an earlier run left behind comes back.
        xcrun simctl uninstall "$SIM" "$BUNDLE_ID" 2>/dev/null || true
        xcrun simctl install "$SIM" "$APP_DIR/build/ios-simulator/$APP.app"
    else
        (cd "$APP_DIR" && "$CLI" deploy --target ios --team "$TEAM" \
            --allow-provisioning-registration ${DEVICE:+--device "$DEVICE"})
    fi
fi

mkdir -p "$WORK"
EMPTY="$WORK/empty.txt"; : > "$EMPTY"
MARKERS="$WORK/markers.txt"
PASS=0; FAIL=0

# The app's Documents, and launching it, on a device or a simulator.
put_doc() { # local source, name in Documents
    if [ -n "$SIM" ]; then cp "$1" "$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)/Documents/$2"
    else xcrun devicectl device copy to "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "$1" --destination "Documents/$2" >/dev/null; fi
}
get_doc() { # name in Documents, local destination
    if [ -n "$SIM" ]; then cp "$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)/Documents/$1" "$2"
    else xcrun devicectl device copy from "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "Documents/$1" --destination "$2" >/dev/null; fi
}
activate_app() { # bring the running probe app forward without relaunching it
    if [ -n "$SIM" ]; then xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
    else xcrun devicectl device process launch "${DEV[@]}" "$BUNDLE_ID" >/dev/null 2>&1 ||
        { sleep 2; xcrun devicectl device process launch "${DEV[@]}" "$BUNDLE_ID" >/dev/null; }; fi
}
launch_app() { # bundle id; the probe app is relaunched, anything else just opened
    if [ -n "$SIM" ]; then
        if [ "$1" = "$BUNDLE_ID" ]; then xcrun simctl launch --terminate-running-process "$SIM" "$1" >/dev/null
        else xcrun simctl launch "$SIM" "$1" >/dev/null; fi
    else
        local flags=()
        [ "$1" = "$BUNDLE_ID" ] && flags=(--terminate-existing)
        # devicectl now and then fails to report the new pid (CoreDeviceError
        # 10004) though the app came up; one retry.
        xcrun devicectl device process launch "${DEV[@]}" ${flags[@]+"${flags[@]}"} "$1" >/dev/null 2>&1 ||
            { sleep 2; xcrun devicectl device process launch "${DEV[@]}" ${flags[@]+"${flags[@]}"} "$1" >/dev/null; }
    fi
}

ACTION="$WORK/close-probe-action.txt"
put_action() {
    printf '%s' "$1" > "$ACTION"
    put_doc "$ACTION" close-probe-action.txt
}

# One launch with `action` written for the page, then what it recorded.
launch_and_read() {
    local action="$1" wait="$2" clear="${3:-1}" activate="${4:-}"
    put_action "$action"
    if [ "$clear" -eq 1 ]; then
        put_doc "$EMPTY" close-flush-markers.txt
    fi
    launch_app "$BUNDLE_ID"
    sleep "$wait"
    if [ -n "$activate" ]; then activate_app; sleep 3; fi
    rm -f "$MARKERS"
    get_doc close-flush-markers.txt "$MARKERS"
    GOT="$(tr '\n' ' ' < "$MARKERS")"
}
has() { grep -q "^$1" "$MARKERS"; }
count() { grep -c "^$1" "$MARKERS" || true; }
verdict() { # name, failure reason or empty
    if [ -z "$2" ]; then echo "  PASS  $1 — [$GOT]"; PASS=$((PASS+1))
    else echo "  FAIL  $1: $2 [$GOT]"; FAIL=$((FAIL+1)); fi
}
missing_of() {
    local m out=()
    for m in "$@"; do has "$m" || out+=("$m"); done
    [ ${#out[@]} -eq 0 ] || echo "missing ${out[*]}"
}

if [ "$MULTI_WINDOW" -eq 1 ]; then
    for run in $(seq 1 "$RUNS"); do
        if [ "$ONE_WINDOW" -eq 1 ]; then
            launch_and_read second-window 14
            if ! has ready; then verdict "one-window $run" "control — the first window never loaded"
            elif has w2-ready; then verdict "one-window $run" "a second window opened"
            else verdict "one-window $run" "$(missing_of create-refused scenes-1)"; fi
            continue
        fi
        for row in second-window system-close; do
            # The second window opens in front of the first, and when it goes
            # iPadOS may leave the app in the background, where the first
            # page's last count waits; bringing the app back lets it land.
            launch_and_read "$row" 14 1 activate
            if ! has w2-ready; then verdict "$row $run" "control — the second window never loaded"
            elif grep -q '^willClose$' "$MARKERS"; then verdict "$row $run" "the first window was told it was closing"
            else verdict "$row $run" "$(missing_of w2-willClose w2-pagehide w2-pagehide-slow swift:window scenes-2 scenes-1)"; fi
        done

        launch_and_read system-window 14
        if ! has ready; then verdict "system-window $run" "control — the first window never loaded"
        elif has system-scene-error; then verdict "system-window $run" "the system scene was refused"
        elif [ "$(count ready)" -lt 2 ]; then verdict "system-window $run" "the system's window never showed the main page"
        else verdict "system-window $run" "$(missing_of scenes-2)"; fi

        launch_and_read keep-second 10
        KEPT="$GOT"
        if ! has w2-ready || ! has scenes-2; then
            verdict "restore $run" "control — the window to bring back never opened"
        else
            echo "        before the relaunch: [$KEPT]"
            # To the background first, the way the system ends an app: one
            # killed while in front never gets its new windows saved, and
            # iPadOS forgets them.
            launch_app com.apple.Preferences
            sleep 3
            # Killed and relaunched with the second window in front: the
            # scene iPadOS brings back has to show that window's page, not
            # the app's entry. (Whether the window behind it reconnects too
            # is iPadOS's call — a hidden window waits for the user.)
            launch_and_read count 12
            verdict "restore $run" "$(missing_of w2-ready)"
        fi
    done
    put_action ""
    echo
    echo "$PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
    exit
fi

put_action ""
for run in $(seq 1 "$RUNS"); do
    put_doc "$EMPTY" close-flush-markers.txt
    launch_app "$BUNDLE_ID"
    sleep 6
    # Backgrounded the way a user does it: by opening another app.
    launch_app com.apple.Preferences
    sleep 8
    rm -f "$MARKERS"
    get_doc close-flush-markers.txt "$MARKERS"
    GOT="$(tr '\n' ' ' < "$MARKERS")"
    missing=()
    for m in ready hidden hidden-slow swift:backgrounded; do
        grep -q "^$m" "$MARKERS" || missing+=("$m")
    done
    if ! grep -q '^hidden$' "$MARKERS"; then
        echo "  FAIL  run $run: control — the page never heard it was going hidden [$GOT]"; FAIL=$((FAIL+1))
    elif [ ${#missing[@]} -eq 0 ]; then
        echo "  PASS  run $run: backgrounded — [$GOT]"; PASS=$((PASS+1))
    else
        echo "  FAIL  run $run: backgrounded — missing [${missing[*]}]; got [$GOT]"; FAIL=$((FAIL+1))
    fi
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
