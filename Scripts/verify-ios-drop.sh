#!/usr/bin/env bash
#
# What a drag from Photos delivers to a page on iOS / iPadOS (#300). Needs a
# person to do the dragging: nothing can start a drag session between two apps.
#
# The report was a Photos drop reaching the page as `types: ["Files"]` with no
# files. Measured with this: on an iPhone the drop arrives with its file, from
# WebKit (`trusted=true`); on iPadOS 27.0 it arrives empty in Safari too, and
# Notes can't take it either — Photos itself fails to provide the item. So run
# two controls beside the app:
#
#   - the same page in Safari, served from this Mac: what WebKit does alone;
#   - the same photo dragged into Notes: whether Photos can provide it at all.
#
# Drag from Photos (one photo, then several), from Files, and some text onto
# the dashed box. The page lists, for each drop, what it saw at dragenter and
# at drop and whether each File's bytes could be read.
#
# Usage:
#   Scripts/verify-ios-drop.sh --team <apple-team-id> [--device <name|udid>]
#   Scripts/verify-ios-drop.sh --simulator [--device <udid>]
#     --port <n>   port to serve the Safari copy on (default 8765)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM=""
DEVICE=""
SIMULATOR=0
PORT=8765
while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --simulator) SIMULATOR=1; shift ;;
        --port) PORT="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ "$SIMULATOR" -eq 0 ] && [ -z "$TEAM" ]; then
    echo "a device install needs --team <apple-team-id> (or pass --simulator)" >&2
    exit 2
fi

WORK="${TMPDIR:-/tmp}/swift-pwa-drop-probe"
APP_DIR="$WORK/DropProbe"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "== building the CLI =="
(cd "$REPO" && swift build --product swift-pwa >/dev/null)
CLI="$REPO/.build/debug/swift-pwa"

echo "== scaffolding against this checkout =="
(cd "$WORK" && "$CLI" init DropProbe >/dev/null)
python3 - "$APP_DIR/Package.swift" "$REPO" <<'PY'
import pathlib, re, sys
manifest, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
text = manifest.read_text()
text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                      f'.package(path: "{repo}")', text)
assert count == 1, "the scaffold's package pin moved; this would test the released package"
text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
manifest.write_text(text)
PY
cp "$REPO/Scripts/drop-probe/index.html" "$APP_DIR/web/index.html"

if [ "$SIMULATOR" -eq 1 ]; then
    echo "== installing on the Simulator =="
    (cd "$APP_DIR" && "$CLI" drive eval --simulator ${DEVICE:+--device "$DEVICE"} "location.href" >/dev/null)
else
    echo "== installing on the device =="
    # A free personal team needs its profile minted against the device.
    (cd "$APP_DIR" && "$CLI" deploy --target ios --team "$TEAM" --allow-provisioning-registration \
        ${DEVICE:+--device "$DEVICE"})
fi

# The Safari copy, from this Mac. Plain HTTP is fine: drag and drop doesn't
# need a secure context.
ADDRESS=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo localhost)
echo
echo "The app is installed as DropProbe. For the control, open this in Safari on the same device:"
echo
echo "    http://$ADDRESS:$PORT/"
echo
echo "Drag from Photos (one photo, then several) and from Files onto the box in each."
echo "Ctrl-C stops the server when you're done."
cd "$REPO/Scripts/drop-probe" && exec python3 -m http.server "$PORT" --bind 0.0.0.0
