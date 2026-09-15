#!/usr/bin/env bash
#
# Check that `WindowEvent.didFocus` / `.didBlur` follow the scene lifecycle on
# iOS (#214).
#
# iOS emitted either event only from an explicit `Window.focus()` call — the app
# talking to itself. It matters more here than on a desktop: a backgrounded iOS
# app is a *suspended* app, so anything it was watching stopped being watched,
# and becoming active again is the moment to re-read it.
#
# The app is sent to the background by launching a different one, which is what
# a user does, and the events are read back from the page afterwards — the app
# has to be frontmost to be driven at all, which is exactly the state this
# restores.
#
# Usage:
#   Scripts/verify-ios-window-focus.sh --team <apple-team-id> [--device <name|udid>]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM="${SWIFT_PWA_IOS_TEAM:-}"
DEVICE=""
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "usage: $0 --team <id> [--device <name|udid>] [--keep]" >&2; exit 2 ;;
    esac
done
[ -n "$TEAM" ] || { echo "--team (or \$SWIFT_PWA_IOS_TEAM) is required — a free personal team is fine" >&2; exit 2; }

WORK="${TMPDIR:-/tmp}/swift-pwa-ios-focus-check"
APP="FocusCheck"
APP_DIR="$WORK/$APP"
BUNDLE_ID="com.example.focuscheck"

cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

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

# The events are accumulated in Swift and read back from JS, because the only
# moment the app can be driven is after it has returned to the foreground —
# which is the second half of what's being measured.
(app_dir / "Sources" / app_dir.name / "Probe.swift").write_text('''import Foundation
import SwiftPWA

/// Appended to on every focus event, in the app's own Documents directory.
///
/// A file rather than a bridge command read back by `swift-pwa drive`: the
/// driver rebuilds and re-signs the app rather than attaching to the installed
/// one, and the app is *suspended* while backgrounded — which is precisely the
/// window being measured. `devicectl device copy from` lifts the file
/// afterwards, with nothing running.
@MainActor
func appendFocusEvent(_ name: String) {
    guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = dir.appendingPathComponent("focus-log.txt")
    let line = Data((name + "\\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    } else {
        try? line.write(to: url)
    }
}

@MainActor
func watchFocus(_ window: any Window) {
    let events = window.eventStream()
    Task.detached {
        for await event in events {
            await MainActor.run {
                switch event {
                case .didFocus: appendFocusEvent("didFocus")
                case .didBlur: appendFocusEvent("didBlur")
                default: break
                }
            }
        }
    }
}
''')

app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    let focusWindow = try ctx.createWindow(',
                      app_swift.read_text())
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
text = text.rstrip()
closing = text.rfind("\n}")
app_swift.write_text(text[:closing] + "\n    watchFocus(focusWindow)" + text[closing:] + "\n")
PY

cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>ios focus check</title>
<body style="font:17px system-ui;padding:32px">
Focus check running. Leave this in the foreground; the script backgrounds it.
</body>
HTML

cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"

DEVICE_ARGS=()
[ -n "$DEVICE" ] && DEVICE_ARGS=(--device "$DEVICE")

echo "== building, signing, installing and launching on the device =="
# `--configuration debug` is load-bearing: the driver's control socket is
# compiled into debug builds only, and reading the app's own record of what it
# saw is the whole measurement. A release build installs and runs fine and then
# answers nothing, which looks exactly like the events never arriving.
(cd "$APP_DIR" && "$CLI" deploy --target ios --configuration debug --team "$TEAM" \
    --allow-provisioning-registration "${DEVICE_ARGS[@]}")

sleep 8

echo "== backgrounding the app by launching another one =="
# Launching a different app is what a user does, and it is the only way to
# background this one without touching the device.
xcrun devicectl device process launch ${DEVICE:+--device "$DEVICE"} --terminate-existing com.apple.Preferences >/dev/null 2>&1 || true
sleep 5

echo "== bringing it back to the foreground =="
xcrun devicectl device process launch ${DEVICE:+--device "$DEVICE"} "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 8

echo "== reading what the app recorded =="
LOGFILE="$WORK/focus-log.txt"
rm -f "$LOGFILE"
xcrun devicectl device copy from ${DEVICE:+--device "$DEVICE"} \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/focus-log.txt --destination "$LOGFILE" >/dev/null 2>&1 || true
LOG=$(tr '\n' ',' < "$LOGFILE" 2>/dev/null || echo "")
echo "   focus-log.txt = [$LOG]"
echo

failed=0
expect() { # pattern label
    case "$LOG" in
        *"$1"*) echo "PASS  $2" ;;
        *) echo "FAIL  $2"; failed=1 ;;
    esac
}
# The control: an empty file means the app never recorded anything, which says
# nothing about the events themselves.
expect "didFocus" "the app recorded focus events at all"
expect "didBlur" "leaving the foreground reaches Swift as didBlur"
# The return path, and the discriminator: a didFocus *after* a didBlur can only
# come from the scene becoming active again.
case "$LOG" in
    *didBlur*didFocus*) echo "PASS  and coming back reaches it as didFocus" ;;
    *) echo "FAIL  and coming back reaches it as didFocus"; failed=1 ;;
esac

[ "$failed" -eq 0 ] || exit 1
echo
echo "Scene lifecycle changes reach WindowEvent on iOS."
