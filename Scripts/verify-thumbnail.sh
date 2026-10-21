#!/usr/bin/env bash
#
# Whether `fs.thumbnail` gives the platform's thumbnail of a file, and gives a
# cloud file's without downloading it (#320). macOS and Linux on this machine,
# or an iOS device over USB with --target ios. Android has its own script
# (Scripts/verify-android-thumbnail.sh), which counts received bytes; Windows
# runs the same page through Scripts/verify-thumbnail-windows.ps1.
#
# The rows are the probe page's (Scripts/thumbnail-probe/index.html): a PDF, a
# PNG and a file of an unknown type written to the app's cache, a missing path,
# and — given a cloud folder — every file in it that isn't local, which has to
# still not be local afterwards (SF_DATALESS / not downloaded, as the probe
# app's `probe.cloudState` reads it without touching the file).
#
# The cloud folder: --folder <path> on a desktop (a Google Drive for desktop
# folder on macOS, a GVFS mount on Linux). On macOS the script makes its own
# cloud files there: a PDF, a PNG and an unknown type in a fresh subfolder,
# uploaded by the provider and then evicted until they're dataless, removed
# afterwards. On iOS a folder outside the app has
# to come from the picker, so run once with --pick and choose an iCloud Drive
# (or Drive) folder whose files aren't on the device; the bookmark is kept in
# the app's storage for later runs.
#
# With --released, the app is built by the last release's CLI and package: the
# control, where every row has to fail (there is no fs.thumbnail).
#
# Usage:
#   Scripts/verify-thumbnail.sh [--folder <path>] [--released] [-k]
#   Scripts/verify-thumbnail.sh --target ios --team <team-id> [--device <name|udid>] [--pick] [--released]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET=""
TEAM=""
DEVICE=""
FOLDER=""
PICK=0
RELEASED=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --team) TEAM="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --folder) FOLDER="$2"; shift 2 ;;
        --pick) PICK=1; shift ;;
        --released) RELEASED=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ "$TARGET" = ios ] && [ -z "$TEAM" ]; then
    echo "an iOS device needs --team <apple-team-id>" >&2
    exit 2
fi

WORK="${TMPDIR:-/tmp}/swift-pwa-thumbnail${TARGET:+-$TARGET}"
APP_DIR="$WORK/ThumbProbe"
CLOUD=""
cleanup() {
    [ -z "$CLOUD" ] || rm -rf "$CLOUD"
    [ "$KEEP" -eq 1 ] || rm -rf "$WORK"
}
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
(cd "$WORK" && "$CLI" init ThumbProbe >/dev/null)
python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import pathlib, re, shutil, sys
app_dir, repo, released = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "1"
if not released:
    manifest = app_dir / "Package.swift"
    text = manifest.read_text()
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', text)
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    text = text.replace('package: "swift-pwa"', f'package: "{repo.name}"')
    manifest.write_text(text)
shutil.copy(repo / "Scripts/thumbnail-probe/Probe.swift", app_dir / "Sources" / app_dir.name / "Probe.swift")
shutil.copy(repo / "Scripts/thumbnail-probe/index.html", app_dir / "web" / "index.html")
app = app_dir / "Sources" / app_dir.name / "App.swift"
text = app.read_text()
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    registerProbes(ctx)\n\n    _ = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app.write_text(text)
PY

if [ -n "$FOLDER" ] && [ "$(uname -s)" = Darwin ] && [ -z "$TARGET" ]; then
    CLOUD="$FOLDER/thumbprobe-$(date +%H%M%S)"
    mkdir -p "$CLOUD"
    python3 - "$CLOUD" <<'PY'
import os, struct, sys, zlib
folder = sys.argv[1]
content = b"1 0 0 rg 72 400 468 300 re f 0 0 1 rg 72 100 200 200 re f BT /F1 48 Tf 0 0 0 rg 90 740 Td (THUMB PROBE) Tj ET"
objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
out = bytearray(b"%PDF-1.4\n"); offs = []
for i, o in enumerate(objs, 1):
    offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
x = len(out); out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for o in offs: out += b"%010d 00000 n \n" % o
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
open(os.path.join(folder, "cover.pdf"), "wb").write(out)
raw = b"".join(b"\x00" + bytes([40, 160, 60]) * 1200 for _ in range(800))
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(os.path.join(folder, "photo.png"), "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1200, 800, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
open(os.path.join(folder, "blob.swiftpwa-unknown"), "wb").write(os.urandom(4096))
PY
    # Evicting fails until the provider has uploaded the file, so keep asking.
    cat > "$WORK/evict.swift" <<'SWIFT'
import Foundation
for path in CommandLine.arguments.dropFirst() {
    try? FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
}
SWIFT
    echo "== waiting for the provider to upload, then evicting =="
    for _ in $(seq 1 90); do
        swift "$WORK/evict.swift" "$CLOUD"/* 2>/dev/null || true
        [ "$(ls -lO "$CLOUD" | grep -c dataless)" -eq 3 ] && break
        sleep 2
    done
    [ "$(ls -lO "$CLOUD" | grep -c dataless)" -eq 3 ] || { ls -lO "$CLOUD"; echo "the files never went dataless" >&2; exit 1; }
    FOLDER="$CLOUD"
fi

DRIVE=(--timeout 600)
if [ "$TARGET" = ios ]; then
    DRIVE+=(--target ios --team "$TEAM" --allow-provisioning-registration ${DEVICE:+--device "$DEVICE"})
fi
query="run=1"
[ -n "$FOLDER" ] && query="$query&folder=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$FOLDER")"
if [ "$PICK" -eq 1 ]; then
    query="pick=1"
    echo "Pick the cloud folder in the picker on the device."
fi

echo "== running the probe page =="
(cd "$APP_DIR" && "$CLI" drive eval "${DRIVE[@]}" --route "/index.html?$query" --wait 'window.__done' \
    "document.getElementById('state').textContent + '\n' + document.getElementById('rows').textContent" \
    >"$WORK/rows.json" 2>"$WORK/drive.log") || { tail -30 "$WORK/drive.log"; exit 1; }
python3 -c 'import json, sys; print(json.loads(open(sys.argv[1]).read().strip().splitlines()[-1]))' "$WORK/rows.json" \
    | tee "$WORK/rows.txt"
[ "$PICK" -eq 1 ] && exit 0

(cd "$APP_DIR" && "$CLI" drive shot "${DRIVE[@]}" --route "/index.html?$query" --wait 'window.__done' \
    "$WORK/shelf.png" >/dev/null 2>>"$WORK/drive.log") && echo "   screenshot: $WORK/shelf.png"

# On Linux the thumbnail is also the file manager's: stored in the shared
# cache, tagged so that GIO's own check accepts it.
if [ "$(uname -s)" = Linux ] && [ "$RELEASED" -eq 0 ]; then
    probe_dir=$(sed -n 's/.*fs\.thumbnail: \(.*\)\/absent\.pdf.*/\1/p' "$WORK/rows.txt")
    valid=$(gio info -a thumbnail::is-valid-large "$probe_dir/probe.pdf" 2>/dev/null | sed -n 's/.*is-valid-large: //p')
    if [ "$valid" = TRUE ]; then
        echo "PASS the PDF's thumbnail is in the shared cache, valid by GIO's own check" | tee -a "$WORK/rows.txt"
    else
        echo "FAIL the PDF's thumbnail isn't in the shared cache as GIO reads it (is-valid-large: ${valid:-absent})" \
            | tee -a "$WORK/rows.txt"
    fi
fi

echo
if grep -q '^PASS' "$WORK/rows.txt" && ! grep -q '^FAIL' "$WORK/rows.txt"; then
    echo "PASS: every row held."
else
    echo "FAIL: see above."
    exit 1
fi
