#!/usr/bin/env bash
#
# App icon appearances and alternate icons (#314), end to end on a fresh
# `swift-pwa init` app: macOS or Linux on this machine, or the iOS Simulator
# with --simulator. Android has its own script
# (Scripts/verify-android-app-icons.sh); Windows runs
# Scripts/verify-app-icons-windows.ps1.
#
# The app declares a light/dark/tinted icon and one alternate ("sketch") with
# its own three. Rows:
#
#   macOS
#     1. Assets.car holds the icon's Aqua, DarkAqua and tintable stacks, and
#        Info.plist names it (CFBundleIconName) — the generated Icon Composer
#        document took. (An .appiconset would compile to one rendition.)
#     2. app.icon.list says supported: false with no alternates, and
#        app.icon.set fails with E_UNIMPLEMENTED: macOS has no way to make a
#        choice stick.
#   Linux
#     2. as macOS.
#   iOS Simulator
#     1. Assets.car holds light, dark and tintable stacks for both icons, and
#        Info.plist registers the alternate for iPhone and iPad.
#     2. app.icon.list lists the alternate, with current null.
#     3. app.icon.set to the alternate, then a relaunch: current is "sketch".
#        (`set` itself settles only once someone taps the system's alert, so
#        it's sent without waiting; the switch lands regardless.)
#     4. An undeclared name fails with E_NOT_FOUND.
#     5. app.icon.set null, relaunch: current is null again.
#
# How each appearance *looks* was measured by eye and by rendering on devices;
# see docs/proposals/app-icon-appearances.md. These rows check the build and
# the commands.
#
# With --released, the app is built by the last release's CLI and package: the
# control, where every row has to fail.
#
# Usage:
#   Scripts/verify-app-icons.sh [--simulator] [--released] [-k]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR=0
RELEASED=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --simulator) SIMULATOR=1; shift ;;
        --released) RELEASED=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 [--simulator] [--released] [-k]" >&2; exit 2 ;;
    esac
done

SUFFIX=""
if [ "$SIMULATOR" -eq 1 ]; then SUFFIX="-sim"; fi
WORK="${TMPDIR:-/tmp}/swift-pwa-app-icons$SUFFIX"
APP_DIR="$WORK/IconProbe"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
rm -rf "$WORK"; mkdir -p "$WORK"

if [ "$RELEASED" -eq 1 ]; then
    echo "== downloading the last release's CLI =="
    case "$(uname -s)" in
        Darwin) asset="swift-pwa-macos-$(uname -m)" ;;
        Linux) asset="swift-pwa-linux-$(uname -m)" ;;
    esac
    gh release download --repo tophatch/swift-pwa --pattern "$asset" --dir "$WORK"
    CLI="$WORK/$asset"
    chmod +x "$CLI"
else
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa >"$WORK/cli-build.log" 2>&1) \
        || { grep -E "error:" "$WORK/cli-build.log" | head -20; tail -5 "$WORK/cli-build.log"; exit 1; }
    CLI="$REPO/.build/debug/swift-pwa"
fi
(cd "$WORK" && "$CLI" init IconProbe >/dev/null)

# Art, a manifest that declares it, and — unless this is the control — the
# local package instead of the released one the scaffold pins.
python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import json, pathlib, re, struct, sys, zlib
app_dir, repo, released = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "1"
art = app_dir / "art"
art.mkdir()
def png(name, rgb, alpha=lambda x, y: 255):
    n = 1024
    rows = b"".join(b"\x00" + b"".join(bytes(rgb) + bytes([alpha(x, y)]) for x in range(0, n, 1)) for y in range(n))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    (art / name).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
                             + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
bar = lambda x, y: 255 if abs(x - 512) < 120 else 0
disc = lambda x, y: 255 if (x - 512) ** 2 + (y - 512) ** 2 < 280 ** 2 else 0
png("icon.png", (40, 90, 220)); png("icon-dark.png", (20, 110, 60)); png("icon-tinted.png", (255, 255, 255), bar)
png("sketch.png", (240, 140, 20)); png("sketch-dark.png", (120, 40, 160)); png("sketch-tinted.png", (255, 255, 255), disc)
manifest = app_dir / "pwa.json"
data = json.loads(manifest.read_text())
# The released CLI can't decode an icon object at all, which would stop the
# control before any row ran; given the plain path it understands, every row
# has to fail on its own.
data["icon"] = "art/icon.png" if released else {
    "light": "art/icon.png", "dark": "art/icon-dark.png", "tinted": "art/icon-tinted.png"}
data["alternate_icons"] = [{"name": "sketch", "icon": {"light": "art/sketch.png", "dark": "art/sketch-dark.png",
                                                       "tinted": "art/sketch-tinted.png"}}]
manifest.write_text(json.dumps(data, indent=2))
if not released:
    package = app_dir / "Package.swift"
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', package.read_text())
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    package.write_text(text.replace('package: "swift-pwa"', f'package: "{repo.name}"'))
PY

PASS=0
FAIL=0
row() { # row <n> <description> <ok:0|1> [detail]
    if [ "$3" -eq 1 ]; then PASS=$((PASS + 1)); echo "PASS $1. $2"; else FAIL=$((FAIL + 1)); echo "FAIL $1. $2${4:+ — $4}"; fi
}
eval_js() { # eval_js <js> — one drive eval; prints the result line, or the error
    local flags=()
    [ "$SIMULATOR" -eq 1 ] && flags+=(--simulator)
    [ "$SIMULATOR" -eq 0 ] && [ "$(uname -s)" = Darwin ] && flags+=(--background)
    (cd "$APP_DIR" && "$CLI" drive eval ${flags[@]+"${flags[@]}"} "$1" 2>&1 | tail -1) || true
}
car_stacks() { # car_stacks <Assets.car> — "<name> <appearance>" per icon stack
    xcrun assetutil --info "$1" 2>/dev/null | python3 -c '
import json, sys
for a in json.load(sys.stdin)[1:]:
    if "Stack" in str(a.get("AssetType")): print(a.get("Name"), a.get("Appearance"))' | sort -u
}
# A flat string rather than JSON: drive prints the result JSON-encoded, so a
# JSON reply would arrive with its quotes escaped.
LIST='__SWIFT_PWA__.invoke("app.icon.list").then(r => "supported=" + r.supported + " current=" + r.current + " alternates=" + r.alternates.join(","), e => e.code)'

if [ "$SIMULATOR" -eq 1 ]; then
    echo "== building for the iOS Simulator =="
    (cd "$APP_DIR" && "$CLI" build --target ios --simulator >"$WORK/build.log" 2>&1) \
        || { tail -20 "$WORK/build.log"; exit 1; }
    grep "app icon" "$WORK/build.log" || true
    APP="$APP_DIR/build/ios-simulator/IconProbe.app"
    stacks="$(car_stacks "$APP/Assets.car")"
    want=$'AppIcon ISAppearanceTintable\nAppIcon UIAppearanceDark\nAppIcon UIAppearanceLight\nsketch ISAppearanceTintable\nsketch UIAppearanceDark\nsketch UIAppearanceLight'
    registered="$(plutil -extract 'CFBundleIcons~ipad.CFBundleAlternateIcons.sketch.CFBundleIconName' raw "$APP/Info.plist" 2>/dev/null || true)"
    [ "$stacks" = "$want" ] && [ "$registered" = sketch ] && ok=1 || ok=0
    row 1 "both icons carry light, dark and tinted, and the alternate is registered" "$ok" "stacks: $(echo $stacks); ipad alternate: ${registered:-none}"

    out="$(eval_js "$LIST")"
    [[ "$out" == *"supported=true current=null alternates=sketch"* ]] && ok=1 || ok=0
    row 2 "app.icon.list lists the alternate with current null" "$ok" "$out"

    eval_js '(__SWIFT_PWA__.invoke("app.icon.set", { name: "sketch" }), "sent")' >/dev/null
    sleep 3
    out="$(eval_js "$LIST")"
    [[ "$out" == *"current=sketch "* ]] && ok=1 || ok=0
    row 3 "after app.icon.set and a relaunch, current is the alternate" "$ok" "$out"

    # The message, not just the code: an unknown *command* is E_NOT_FOUND too.
    out="$(eval_js '__SWIFT_PWA__.invoke("app.icon.set", { name: "nope" }).then(() => "resolved", e => e.code + ": " + e.message)')"
    [[ "$out" == *"E_NOT_FOUND: app.icon.set: no alternate icon named"* ]] && ok=1 || ok=0
    row 4 "an undeclared name fails with E_NOT_FOUND" "$ok" "$out"

    eval_js '(__SWIFT_PWA__.invoke("app.icon.set", { name: null }), "sent")' >/dev/null
    sleep 3
    out="$(eval_js "$LIST")"
    [[ "$out" == *"current=null "* ]] && ok=1 || ok=0
    row 5 "app.icon.set null switches back to the primary" "$ok" "$out"
else
    if [ "$(uname -s)" = Darwin ]; then
        echo "== building for macOS =="
        (cd "$APP_DIR" && "$CLI" build --target macos >"$WORK/build.log" 2>&1) \
            || { tail -20 "$WORK/build.log"; exit 1; }
        grep "app icon" "$WORK/build.log" || true
        APP="$APP_DIR/build/macos/IconProbe.app"
        stacks="$(car_stacks "$APP/Contents/Resources/Assets.car" 2>/dev/null || true)"
        want=$'AppIcon ISAppearanceTintable\nAppIcon NSAppearanceNameAqua\nAppIcon NSAppearanceNameDarkAqua'
        name="$(plutil -extract CFBundleIconName raw "$APP/Contents/Info.plist" 2>/dev/null || true)"
        [ "$stacks" = "$want" ] && [ "$name" = AppIcon ] && ok=1 || ok=0
        row 1 "the icon carries light, dark and tinted, named by CFBundleIconName" "$ok" "stacks: $(echo $stacks); name: ${name:-none}"
    fi
    out="$(eval_js "$LIST")"
    [[ "$out" == *"supported=false current=null alternates="\"* ]] && ok=1 || ok=0
    row 2 "app.icon.list says unsupported" "$ok" "$out"
    out="$(eval_js '__SWIFT_PWA__.invoke("app.icon.set", { name: "sketch" }).then(() => "resolved", e => e.code)')"
    [[ "$out" == *E_UNIMPLEMENTED* ]] && ok=1 || ok=0
    row 2b "app.icon.set fails with E_UNIMPLEMENTED" "$ok" "$out"
fi

NOTE=""
if [ "$RELEASED" -eq 1 ]; then NOTE=" (control: every row should fail)"; fi
echo "== $PASS passed, $FAIL failed$NOTE =="
if [ "$RELEASED" -eq 1 ]; then [ "$PASS" -eq 0 ]; else [ "$FAIL" -eq 0 ]; fi
