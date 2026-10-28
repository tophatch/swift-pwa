#!/usr/bin/env bash
#
# Whether a macOS window shows `window.background_color` before the page's
# first paint (#327), rather than WKWebView's own white or gray fill.
#
# A fresh `swift-pwa init` app gets a dark background colour (#0a0e17) and a
# page whose first paint is held for two seconds by a blocking script, after
# which it paints red. The app is launched off screen (without taking focus),
# and its window is captured by window id twice:
#
#   1. During the hold: the pixel has to be the configured colour, not lighter.
#   2. After the paint: the pixel has to be the page's red. This is the
#      instrument's own control — a capture that can't see web content would
#      pass row 1 for the wrong reason.
#
# Windowed only: full screen would take over a display. The fix is the same
# property either way, and #327's own probe measured full screen.
#
# The window is put on the main display *behind* everything else, without
# activating the app, so a run doesn't take the focus from whoever is at the
# machine: `screencapture -l` reads a covered window, but not one parked off
# screen the way a backgrounded driven run parks it. With --released, the app
# is built against the last release: the control, where row 1 has to fail.
#
# Needs a logged-on session whose terminal may record the screen (macOS asks
# once; `screencapture` is what reads the window).
#
# Usage:
#   Scripts/verify-mac-background-before-paint.sh [--released] [-k]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASED=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --released) RELEASED=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 [--released] [-k]" >&2; exit 2 ;;
    esac
done

WORK="${TMPDIR:-/tmp}/swift-pwa-first-paint"
APP_DIR="$WORK/PaintProbe"
APP_PID=""
cleanup() {
    [ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true
    [ "$KEEP" -eq 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
rm -rf "$WORK"; mkdir -p "$WORK"

echo "== building the CLI =="
(cd "$REPO" && swift build --product swift-pwa >"$WORK/cli-build.log" 2>&1) \
    || { grep -E "error:" "$WORK/cli-build.log" | head -20; exit 1; }
CLI="$REPO/.build/debug/swift-pwa"
(cd "$WORK" && "$CLI" init PaintProbe >/dev/null)

python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import pathlib, re, sys
app_dir, repo, released = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "1"
if not released:
    package = app_dir / "Package.swift"
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', package.read_text())
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    package.write_text(text.replace('package: "swift-pwa"', f'package: "{repo.name}"'))
app = app_dir / "Sources" / app_dir.name / "App.swift"
text = app.read_text()
text, count = re.subn(r"content: content,", 'content: content,\n        backgroundColor: "#0a0e17",', text)
assert count == 1, "the scaffold's WindowConfig moved; this patch needs updating"
# Onto the main display, behind everything, without activating: a backgrounded
# run parks the window off screen, where screencapture can't read it.
text = text.replace("import SwiftPWA\n", "import SwiftPWA\n#if os(macOS)\n    import AppKit\n#endif\n", 1)
text, count = re.subn(r"(?s)(    _ = try ctx\.createWindow\(.*?\)\)\n)", lambda m: m.group(1) + """    #if os(macOS)
        // nil when the build runs the app headless to read its permissions.
        if let app = NSApp {
            for window in app.windows {
                window.setFrameOrigin(NSPoint(x: 120, y: 120))
                window.orderBack(nil)
            }
        }
    #endif
""", text, count=1)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app.write_text(text)
# Hold the first paint: a blocking script in <head> keeps the page from
# painting anything until it returns, then the body is red.
(app_dir / "web" / "index.html").write_text("""<!doctype html>
<html><head><meta charset="utf-8"><title>PaintProbe</title>
<script>const end = Date.now() + 2000; while (Date.now() < end) {}</script>
<style>html, body { margin: 0; height: 100%; background: #d00000; }</style>
</head><body></body></html>
""")
PY

echo "== building the app =="
(cd "$APP_DIR" && "$CLI" build --target macos --configuration debug >"$WORK/build.log" 2>&1) \
    || { tail -20 "$WORK/build.log"; exit 1; }
BIN="$APP_DIR/build/macos/PaintProbe.app/Contents/MacOS/PaintProbe"

# The window's id, by owner pid — listing windows needs no permission.
cat > "$WORK/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let id = w[kCGWindowNumber as String] as? Int { print(id); break }
}
SWIFT
cat > "$WORK/pixel.swift" <<'SWIFT'
import AppKit
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
print(Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
SWIFT
swiftc -O -o "$WORK/winid" "$WORK/winid.swift" 2>/dev/null
swiftc -O -o "$WORK/pixel" "$WORK/pixel.swift" 2>/dev/null

echo "== launching behind the other windows, without taking focus =="
SWIFT_PWA_DRIVE=0 SWIFT_PWA_DRIVE_BACKGROUND=1 "$BIN" >"$WORK/app.log" 2>&1 &
APP_PID=$!
WID=""
for _ in $(seq 1 100); do
    WID="$("$WORK/winid" "$APP_PID")"
    [ -n "$WID" ] && break
    sleep 0.05
done
[ -n "$WID" ] || { echo "the app never showed a window"; cat "$WORK/app.log"; exit 1; }
sleep 0.5
screencapture -x -o -l "$WID" "$WORK/during.png"
sleep 3
screencapture -x -o -l "$WID" "$WORK/after.png"
during="$("$WORK/pixel" "$WORK/during.png")"
after="$("$WORK/pixel" "$WORK/after.png")"

PASS=0
FAIL=0
row() { if [ "$3" -eq 1 ]; then PASS=$((PASS + 1)); echo "PASS $1. $2"; else FAIL=$((FAIL + 1)); echo "FAIL $1. $2"; fi; }
read -r r g b <<<"$during"
# The configured colour is (10, 14, 23); anything brighter than ~twice that is
# WebKit's own fill (#191919 gray or #fdfdfd white).
[ "$r" -lt 30 ] && [ "$g" -lt 34 ] && [ "$b" -lt 44 ] && ok=1 || ok=0
row 1 "before the page paints, the window shows the configured colour (got $during, want ~10 14 23)" "$ok"
read -r r g b <<<"$after"
# The capture is colour-managed (the page's #d00000 reads back near
# 204 60 34), so red means clearly red, not the exact value.
[ "$r" -gt 150 ] && [ "$g" -lt 100 ] && [ "$b" -lt 100 ] && ok=1 || ok=0
row 2 "after it paints, the capture shows the page's red (got $after) — the instrument sees web content" "$ok"

NOTE=""
if [ "$RELEASED" -eq 1 ]; then NOTE=" (control: row 1 should fail, row 2 pass)"; fi
echo "== $PASS passed, $FAIL failed$NOTE =="
if [ "$RELEASED" -eq 1 ]; then [ "$PASS" -eq 1 ]; else [ "$FAIL" -eq 0 ]; fi
