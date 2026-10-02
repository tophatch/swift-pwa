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
#                                     [--bundle-id <id>] [--second-window]
#
# --second-window runs the iPad multi-window row instead: the first window
# opens a second scene (the probe asks for one — the runtime opens none for a
# window made after launch), the second window's page closes itself, and the
# run checks that its teardown and `beforeClose(.window)` landed, that the
# scene went (2 scenes, then 1), and that the first window was never told it
# was closing. Needs an iPad: an iPhone shows one scene at a time.
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
SECOND_WINDOW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --no-build) BUILD=0; KEEP=1; shift ;;
        --bundle-id) BUNDLE_ID_ARG="$2"; shift 2 ;;
        --second-window) SECOND_WINDOW=1; shift ;;
        *) echo "usage: $0 --team <id> [--device <name|udid>] [--runs <n>] [--keep] [--no-build]" >&2; exit 2 ;;
    esac
done
[ -n "$TEAM" ] || { echo "--team (or \$SWIFT_PWA_IOS_TEAM) is required — a free personal team is fine" >&2; exit 2; }

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
    (cd "$APP_DIR" && "$CLI" deploy --target ios --team "$TEAM" \
        --allow-provisioning-registration ${DEVICE:+--device "$DEVICE"})
fi

mkdir -p "$WORK"
EMPTY="$WORK/empty.txt"; : > "$EMPTY"
MARKERS="$WORK/markers.txt"
PASS=0; FAIL=0

ACTION="$WORK/close-probe-action.txt"
put_action() {
    printf '%s' "$1" > "$ACTION"
    xcrun devicectl device copy to "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "$ACTION" --destination Documents/close-probe-action.txt >/dev/null
}

if [ "$SECOND_WINDOW" -eq 1 ]; then
    for run in $(seq 1 "$RUNS"); do
        put_action second-window
        xcrun devicectl device copy to "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source "$EMPTY" --destination Documents/close-flush-markers.txt >/dev/null
        xcrun devicectl device process launch "${DEV[@]}" --terminate-existing "$BUNDLE_ID" >/dev/null
        sleep 14
        rm -f "$MARKERS"
        xcrun devicectl device copy from "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source Documents/close-flush-markers.txt --destination "$MARKERS" >/dev/null
        GOT="$(tr '\n' ' ' < "$MARKERS")"
        missing=()
        for m in w2-ready w2-willClose w2-pagehide w2-pagehide-slow swift:window scenes-2 scenes-1; do
            grep -q "^$m" "$MARKERS" || missing+=("$m")
        done
        if ! grep -q '^w2-ready' "$MARKERS"; then
            echo "  FAIL  run $run: control — the second window never loaded [$GOT]"; FAIL=$((FAIL+1))
        elif grep -q '^willClose$' "$MARKERS"; then
            echo "  FAIL  run $run: the first window was told it was closing [$GOT]"; FAIL=$((FAIL+1))
        elif [ ${#missing[@]} -eq 0 ]; then
            echo "  PASS  run $run: second window closed — [$GOT]"; PASS=$((PASS+1))
        else
            echo "  FAIL  run $run: missing [${missing[*]}]; got [$GOT]"; FAIL=$((FAIL+1))
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
    xcrun devicectl device copy to "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "$EMPTY" --destination Documents/close-flush-markers.txt >/dev/null
    xcrun devicectl device process launch "${DEV[@]}" --terminate-existing "$BUNDLE_ID" >/dev/null
    sleep 6
    # Backgrounded the way a user does it: by opening another app.
    xcrun devicectl device process launch "${DEV[@]}" com.apple.Preferences >/dev/null
    sleep 8
    rm -f "$MARKERS"
    xcrun devicectl device copy from "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source Documents/close-flush-markers.txt --destination "$MARKERS" >/dev/null
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
