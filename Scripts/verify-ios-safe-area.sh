#!/usr/bin/env bash
#
# Check that a document reached by a navigation soon after load still gets its
# safe-area insets on iOS (#282).
#
# Every document starts with its insets at zero and gets them a few tens of
# milliseconds later. A navigation landing inside that window used to lose the
# update: the next document came up full-screen with every inset at 0 and kept
# them there, so an `env(safe-area-inset-top)` header sat under the Dynamic
# Island for good.
#
# One install, many launches: the probe page (safe-area-probe/) replaces itself
# with a second document after a delay that steps through 0–70ms across
# launches, and logs every document's insets through a `probe.log` command into
# the app's Documents. The app is relaunched with `--terminate-existing` between
# runs and the log lifted with `devicectl device copy from` at the end.
#
# The control is the launch that doesn't navigate: if that document never gets
# insets either, the device has none to give (or the probe is broken) and a
# "stuck" second document means nothing. Needs a device with a non-zero inset —
# any Face ID iPhone; an iPad's top inset is 0 in portrait on some models.
#
# **It doesn't reproduce the bug yet.** On an iPhone 17 Pro and an iPad Pro
# (iOS 27): 0 of 238 navigated documents stuck, across delays 0–70ms and
# navigations by replace, push, a second document whose head blocks 150ms, the
# app's main thread held as it navigates, the reporting app's apple-mobile-web-
# app / theme-color metas, five render-blocking stylesheets, and a coloured
# launch screen. The reporting app sticks in about two launches of three, and
# its log has a shape this probe reproduces everywhere except the outcome: the
# first document navigates while still at 402×778, the second loads, goes to
# 402×874 — and in theirs never gets an inset. Here it gets them 25–60ms later.
# Until a variant here sticks, a PASS is not evidence a fix works.
#
# Usage:
#   Scripts/verify-ios-safe-area.sh --team <apple-team-id> [--device <name|udid>]
#                                   [--launches <n>] [--keep] [--no-build]
#                                   [--launch-color]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM="${SWIFT_PWA_IOS_TEAM:-}"
DEVICE=""
LAUNCHES=42
KEEP=0
BUILD=1
LAUNCH_COLOR=0
while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --launches) LAUNCHES="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --no-build) BUILD=0; KEEP=1; shift ;;
        --launch-color) LAUNCH_COLOR=1; shift ;;
        *) echo "usage: $0 --team <id> [--device <name|udid>] [--launches <n>] [--keep] [--no-build]" >&2; exit 2 ;;
    esac
done
[ -n "$TEAM" ] || { echo "--team (or \$SWIFT_PWA_IOS_TEAM) is required — a free personal team is fine" >&2; exit 2; }

WORK="${TMPDIR:-/tmp}/swift-pwa-ios-safe-area-check"
APP="SafeAreaCheck"
APP_DIR="$WORK/$APP"
BUNDLE_ID="com.example.safeareacheck"
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

    python3 - "$APP_DIR" "$REPO" <<'PY'
import pathlib, re, sys
app_dir, repo = pathlib.Path(sys.argv[1]), sys.argv[2]

manifest = app_dir / "Package.swift"
text = manifest.read_text()
text = re.sub(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
              f'.package(path: "{repo}")', text)
text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
manifest.write_text(text)

# A file in the app's own Documents rather than anything read back over the
# driver: the measurement spans relaunches, and `devicectl device copy from`
# lifts it afterwards with nothing running.
(app_dir / "Sources" / app_dir.name / "Probe.swift").write_text('''import Foundation
import SwiftPWA

struct ProbeLine: Codable, Sendable { let line: String }

@MainActor
func registerProbe(_ ctx: any AppContext) {
    ctx.registry.register("probe.log", typed: { (args: ProbeLine, _) -> Bool in
        await MainActor.run {
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return false }
            let url = dir.appendingPathComponent("safe-area-log.txt")
            let data = Data((args.line + "\\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            return true
        }
    })
    // Holds the main thread, which is where the scheme handler serves the next
    // document from.
    struct Stall: Codable, Sendable { let ms: Int }
    ctx.registry.register("probe.stall", typed: { (args: Stall, _) -> Bool in
        await MainActor.run { Thread.sleep(forTimeInterval: Double(args.ms) / 1000) }
        return true
    })
}
''')

app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text, count = re.subn(r'(?m)^func configure\(_ ctx: any AppContext\) throws \{\n',
                      'func configure(_ ctx: any AppContext) throws {\n    registerProbe(ctx)\n',
                      app_swift.read_text())
assert count == 1, "the scaffold's configure moved; this patch needs updating"
app_swift.write_text(text)
PY

    if [ "$LAUNCH_COLOR" -eq 1 ]; then
        # A `window.background_color` colours the UILaunchScreen, the way the
        # reporting app's does.
        python3 - "$APP_DIR/pwa.json" <<'PY2'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path))
manifest["window"]["background_color"] = {"light": "#ffffff", "dark": "#131313"}
json.dump(manifest, open(path, "w"), indent=2)
PY2
    fi
    cp "$REPO/Scripts/safe-area-probe/"* "$APP_DIR/web/"
    cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"

    echo "== building, signing and installing on the device =="
    (cd "$APP_DIR" && "$CLI" deploy --target ios --team "$TEAM" \
        --allow-provisioning-registration ${DEVICE:+--device "$DEVICE"})
fi

echo "== clearing the previous log =="
# Relaunching first gives the app a Documents directory to remove the file from.
LOGFILE="$WORK/safe-area-log.txt"
mkdir -p "$WORK"
EMPTY="$WORK/empty.txt"; : > "$EMPTY"
xcrun devicectl device copy to "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$EMPTY" --destination Documents/safe-area-log.txt >/dev/null

echo "== launching $LAUNCHES times =="
for i in $(seq 1 "$LAUNCHES"); do
    # A relaunch occasionally fails to report the new pid (CoreDeviceError
    # 10004) though the app came up; one retry, and a miss only costs a sample.
    if xcrun devicectl device process launch "${DEV[@]}" --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1 ||
        { sleep 2; xcrun devicectl device process launch "${DEV[@]}" --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1; }; then
        printf '.'
    else
        printf 'x'
    fi
    sleep 3.5
done
echo

echo "== reading what the app recorded =="
rm -f "$LOGFILE"
xcrun devicectl device copy from "${DEV[@]}" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/safe-area-log.txt --destination "$LOGFILE" >/dev/null

python3 - "$LOGFILE" <<'PY'
import collections, sys
# line: launch doc delay ms event top,right,bottom,left WxH screenWxH
last = {}
for raw in open(sys.argv[1]):
    parts = raw.split()
    if len(parts) != 8:
        continue
    launch, doc, delay, _ms, event, insets, viewport, _screen = parts
    if doc == ("first" if delay == "none:none" else "second"):
        last[launch] = (delay, event, [int(v) for v in insets.split(",")], viewport)

by_delay = collections.defaultdict(lambda: [0, 0])
for delay, event, insets, viewport in last.values():
    by_delay[delay][0] += 1
    by_delay[delay][1] += int(not any(insets))

def key(d):
    variant, ms = d.split(":")
    return ("" if variant == "none" else variant, -1 if ms == "none" else int(ms))
print(f"{'navigation':>20}  launches  insets stuck at 0")
for delay in sorted(by_delay, key=key):
    total, stuck = by_delay[delay]
    label = "never (control)" if delay == "none:none" else f"{delay.replace(':', ' after ')}ms"
    print(f"{label:>20}  {total:>8}  {stuck:>17}")

control = by_delay.get("none:none", [0, 0])
swept = [v for d, v in by_delay.items() if d != "none:none"]
if control[0] == 0:
    sys.exit("FAIL  no control launch was recorded — the probe never logged")
if control[1] == control[0]:
    sys.exit("FAIL  the control never got insets either: this device has none, or the probe is broken")
if not swept:
    sys.exit("FAIL  no navigating launch was recorded")
stuck = sum(s for _, s in swept)
if stuck:
    sys.exit(f"FAIL  {stuck} of {sum(t for t, _ in swept)} navigated documents kept insets of 0")
print(f"PASS  every navigated document got its insets ({sum(t for t, _ in swept)} launches)")
PY
