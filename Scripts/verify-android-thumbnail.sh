#!/usr/bin/env bash
#
# Whether `fs.thumbnail` on Android gives the platform's thumbnail of a file,
# and, for a Google Drive document, gives it without downloading the document
# (#320).
#
# Drive's provider downloads a document whole the first time any of it is read
# (#320 measured 49 MB received for 64 KB from the tail of a 47 MB PDF). Its
# thumbnails come from Drive's own server-side renders instead, through
# `FLAG_SUPPORTS_THUMBNAIL` / `openDocumentThumbnail`.
#
# Rows:
#   1. A PDF in the app's files: page one (the red block where the page has it,
#      the blue one below), within maxSize.
#   2. A PNG in the app's files: a thumbnail.
#   3. A file of a type with no thumbnailer: null, not an error.
#   4. A path that doesn't exist: an error.
#   5. A 40 MB PDF just added to the picked Drive folder from this Mac, never
#      opened on the device: a thumbnail or null, and device-wide wlan0
#      received bytes well under the file's size.
#   6. A Drive file of a type with no thumbnailer: null.
#   7. The control for row 5: a 64 KB range of the same PDF through a served
#      mount has to cost about the whole file, or the byte count can't see a
#      download and row 5 proves nothing.
#
# Rows 5–7 need --folder: the same app and Drive grant as
# Scripts/verify-android-saf-drive.sh, so pick the folder once with that
# script's --pick. Without --folder only rows 1–4 run. With --released, the app is built
# by the last release's CLI and package: the control, where rows 1–3 and 5–6
# have to fail (there is no fs.thumbnail).
#
# Usage:
#   Scripts/verify-android-thumbnail.sh [--folder <local Drive path>] [-s <adb-serial>] [--released] [-k]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
FOLDER=""
RELEASED=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERIAL="$2"; shift 2 ;;
        --folder) FOLDER="$2"; shift 2 ;;
        --released) RELEASED=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 [--folder <path>] [-s serial] [--released] [-k]" >&2; exit 2 ;;
    esac
done
[ -z "$FOLDER" ] || [ -d "$FOLDER" ] \
    || { echo "--folder must be the picked Drive folder as Drive for desktop syncs it here" >&2; exit 2; }

ADB=(adb)
CDP=("$REPO/Scripts/android-cdp-eval.py")
if [ -n "$SERIAL" ]; then
    ADB=(adb -s "$SERIAL")
    CDP+=(-s "$SERIAL")
    export ANDROID_SERIAL="$SERIAL"
fi

WORK="${TMPDIR:-/tmp}/swift-pwa-android-thumbnail${SERIAL:+-$SERIAL}"
APP="SafDriveCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.safdrivecheck"
FILES="/data/user/0/$PKG/files/thumbprobe"
STAMP=$(date +%H%M%S)
DRIVE_PDF="thumb-$STAMP.pdf"
DRIVE_OTHER="thumb-$STAMP.swiftpwa-unknown"
cleanup() {
    [ -z "$FOLDER" ] || rm -f "$FOLDER/$DRIVE_PDF" "$FOLDER/$DRIVE_OTHER"
    [ "$KEEP" -eq 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device" >&2; exit 1; }
# A Samsung with its screen off freezes the app, and a CDP call then hangs.
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP

rm -rf "$WORK"; mkdir -p "$WORK"
if [ "$RELEASED" -eq 1 ]; then
    echo "== downloading the last release's CLI =="
    gh release download --repo tophatch/swift-pwa --pattern "swift-pwa-macos-$(uname -m)" --dir "$WORK"
    CLI="$WORK/swift-pwa-macos-$(uname -m)"
    chmod +x "$CLI"
else
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa >/dev/null)
    CLI="$REPO/.build/debug/swift-pwa"
fi
(cd "$WORK" && "$CLI" init "$APP" >/dev/null)
python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import pathlib, re, sys
app_dir, repo, released = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
if not released:
    manifest = app_dir / "Package.swift"
    text = manifest.read_text()
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', text)
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
    manifest.write_text(text)
(app_dir / "Sources" / app_dir.name / "Probe.swift").write_text('''import Foundation
import SwiftPWA

struct ServeArgs: Decodable, Sendable { let tree: String }
struct ServeAck: Encodable, Sendable { let ok: Bool }

@MainActor
func registerProbes(_ ctx: any AppContext) {
    ctx.use(DialogPlugin(SystemDialog()))
    ctx.use(FsPlugin(SystemFs()))
    // The control's way to read a range of a Drive document, as #320 did.
    ctx.registry.register("probe.serveTree", typed: { (args: ServeArgs, _) async -> ServeAck in
        guard let tree = URL(string: args.tree) else { return ServeAck(ok: false) }
        await MainThread.run { ctx.serveDirectory(tree, at: "/library") }
        return ServeAck(ok: true)
    })
}
''')
app = app_dir / "Sources" / app_dir.name / "App.swift"
text = app.read_text()
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    registerProbes(ctx)\n\n    _ = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app.write_text(text)
PY
# The picked tree lives in localStorage, which a reinstall keeps.
cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Thumbnail check</title>
<body style="font:14px system-ui;padding:24px"><p>Thumbnail check</p><div id="shelf"></div>
<script>
// Where the probe PDF has its blocks: red across the upper half, blue below
// on the left. A thumbnail of the page has both; an icon has neither.
function colour(d) {
  if (d[0] > 180 && d[1] < 90 && d[2] < 90) return 'red';
  if (d[2] > 180 && d[0] < 90 && d[1] < 90) return 'blue';
  if (d[0] > 200 && d[1] > 200 && d[2] > 200) return 'white';
  return 'rgb(' + d[0] + ',' + d[1] + ',' + d[2] + ')';
}
window.thumb = async (path, maxSize) => {
  try {
    const { image } = await __SWIFT_PWA__.invoke('fs.thumbnail', { path, maxSize });
    if (!image) return 'null';
    const img = new Image();
    img.src = 'data:' + image.mimeType + ';base64,' + image.dataBase64;
    await img.decode();
    img.title = path; img.style.margin = '4px'; img.style.border = '1px solid #ccc';
    document.getElementById('shelf').appendChild(img);
    const c = document.createElement('canvas');
    c.width = img.naturalWidth; c.height = img.naturalHeight;
    const g = c.getContext('2d'); g.drawImage(img, 0, 0);
    const at = (x, y) => colour(g.getImageData(Math.floor(x * c.width), Math.floor(y * c.height), 1, 1).data);
    return image.width + 'x' + image.height + ' top=' + at(0.5, 0.3) + ' low=' + at(0.28, 0.75);
  } catch (e) { return 'THREW ' + (e.code || '') + ' ' + e.message; }
};
window.list = async () => {
  try {
    const r = await __SWIFT_PWA__.invoke('fs.readDir', { path: localStorage.getItem('tree') });
    return r.entries.map((e) => e.name + '=' + e.path).join('\n');
  } catch (e) { return 'THREW ' + (e.code || '') + ' ' + e.message; }
};
window.serve = async () => {
  await __SWIFT_PWA__.invoke('probe.serveTree', { tree: localStorage.getItem('tree') });
  return 'served';
};
window.tail = async (name) => {
  const start = performance.now();
  const r = await fetch('/library/' + encodeURIComponent(name), { headers: { Range: 'bytes=-65536' } });
  const n = (await r.arrayBuffer()).byteLength;
  return r.status + ' ' + n + ' bytes in ' + Math.round(performance.now() - start) + ' ms';
};
</script>
HTML

echo "== deploying =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a >"$WORK/deploy.log" 2>&1) \
    || { tail -30 "$WORK/deploy.log"; exit 1; }
# An OEM "auto freeze" (Boox) disables a freshly installed app as it first
# launches. Enabled by hand, it stays enabled.
if "${ADB[@]}" shell pm list packages -d | grep -qx "package:$PKG"; then
    "${ADB[@]}" shell pm enable "$PKG" >/dev/null
    "${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
fi
js() { "${CDP[@]}" "$PKG" "$1" 2>/dev/null; }
for _ in $(seq 1 30); do [ "$(js "typeof window.thumb")" = '"function"' ] && break; sleep 1; done
if [ -n "$FOLDER" ]; then
    tree=$(js "localStorage.getItem('tree')")
    case "$tree" in
        *content://*) ;;
        *) echo "no folder granted: run Scripts/verify-android-saf-drive.sh --pick first" >&2; exit 1 ;;
    esac
fi

# The probe files: the one-page PDF the unit tests use, a PNG, and a file of a
# type nothing thumbnails. The Drive PDF carries 40 MB of incompressible
# padding in an object nothing references, so its page is the same and a
# download of it can't hide in background traffic.
python3 - "$WORK" "${FOLDER:+$FOLDER/$DRIVE_PDF}" "${FOLDER:+$FOLDER/$DRIVE_OTHER}" <<'PY'
import os, struct, sys, zlib
work, drive_pdf, drive_other = sys.argv[1:4]
def pdf(padding=0):
    content = b"1 0 0 rg 72 400 468 300 re f 0 0 1 rg 72 100 200 200 re f BT /F1 48 Tf 0 0 0 rg 90 740 Td (THUMB PROBE) Tj ET"
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    if padding:
        objs.append(b"<< /Length %d >>\nstream\n" % padding + os.urandom(padding) + b"\nendstream")
    out = bytearray(b"%PDF-1.4\n"); offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out); out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for o in offs: out += b"%010d 00000 n \n" % o
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
    return bytes(out)
def png(w, h):
    raw = b"".join(b"\x00" + bytes([40, 160, 60]) * w for _ in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(os.path.join(work, "probe.pdf"), "wb").write(pdf())
open(os.path.join(work, "probe.png"), "wb").write(png(1200, 800))
open(os.path.join(work, "probe.swiftpwa-unknown"), "wb").write(os.urandom(4096))
if drive_pdf:
    open(drive_pdf, "wb").write(pdf(40 << 20))
    open(drive_other, "wb").write(os.urandom(4096))
PY
"${ADB[@]}" shell "run-as $PKG mkdir -p files/thumbprobe" || true
for f in probe.pdf probe.png probe.swiftpwa-unknown; do
    "${ADB[@]}" push "$WORK/$f" "/data/local/tmp/$f" >/dev/null
    "${ADB[@]}" shell "cat /data/local/tmp/$f | run-as $PKG sh -c 'cat > files/thumbprobe/$f'; rm /data/local/tmp/$f"
done

FAILED=0
row() { # <name> <0|1 passed> <detail>
    if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1 ($3)"; FAILED=1; fi
}
rx() { "${ADB[@]}" shell cat /proc/net/dev | awk '/wlan0:/ { print $2 }'; }

echo "== local files =="
got=$(js "thumb('$FILES/probe.pdf', 256)"); echo "   pdf: $got"
[[ "$got" == *"top=red low=blue"* ]] && r=1 || r=0
row "1. a local PDF gives page one" "$r" "$got"
got=$(js "thumb('$FILES/probe.png', 256)"); echo "   png: $got"
[[ "$got" == '"256x'* ]] && r=1 || r=0
row "2. a local PNG gives a thumbnail, 256 on its longer side" "$r" "$got"
got=$(js "thumb('$FILES/probe.swiftpwa-unknown', 256)"); echo "   unknown type: $got"
[ "$got" = '"null"' ] && r=1 || r=0
row "3. a type with no thumbnailer gives null" "$r" "$got"
got=$(js "thumb('$FILES/absent.pdf', 256)"); echo "   missing: $got"
[[ "$got" == *THREW*"no such file"* ]] && r=1 || r=0
row "4. a missing path is an error" "$r" "$got"

if [ -n "$FOLDER" ]; then
    echo "== waiting for Drive for desktop to upload $DRIVE_PDF (40 MB) =="
    for _ in $(seq 1 150); do
        xattr -p "com.google.drivefs.item-id#S" "$FOLDER/$DRIVE_PDF" >/dev/null 2>&1 \
            && xattr -p "com.google.drivefs.item-id#S" "$FOLDER/$DRIVE_OTHER" >/dev/null 2>&1 && break
        sleep 2
    done
    xattr -p "com.google.drivefs.item-id#S" "$FOLDER/$DRIVE_PDF" >/dev/null 2>&1 \
        || { echo "Drive for desktop never uploaded $DRIVE_PDF" >&2; exit 1; }
    # fs.readDir is current (#316), so the files' document URIs come from it.
    pdf_uri=""; other_uri=""
    for _ in $(seq 1 12); do
        listing=$(js "list()" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()))')
        pdf_uri=$(echo "$listing" | sed -n "s/^$DRIVE_PDF=//p")
        other_uri=$(echo "$listing" | sed -n "s/^$DRIVE_OTHER=//p")
        [ -n "$pdf_uri" ] && [ -n "$other_uri" ] && break
        sleep 5
    done
    [ -n "$pdf_uri" ] || { echo "the device never listed $DRIVE_PDF" >&2; exit 1; }
    size=$(stat -f %z "$FOLDER/$DRIVE_PDF")

    echo "== Drive =="
    before=$(rx); start=$(date +%s)
    got=$(js "thumb('$pdf_uri', 256)")
    after=$(rx)
    received=$((after - before))
    echo "   pdf ($size bytes, never opened here): $got; received $received bytes in $(($(date +%s) - start)) s"
    [[ "$got" != *THREW* ]] && [ "$received" -lt $((size / 10)) ] && r=1 || r=0
    row "5. a Drive PDF never opened gives its thumbnail or null without a download" "$r" "$got, $received bytes"
    got=$(js "thumb('$other_uri', 256)"); echo "   unknown type: $got"
    [ "$got" = '"null"' ] && r=1 || r=0
    row "6. a Drive file with no thumbnail gives null" "$r" "$got"

    js "serve()" >/dev/null
    before=$(rx)
    got=$(js "tail('$DRIVE_PDF')")
    after=$(rx)
    received=$((after - before))
    echo "   control, 64 KB from the tail of the same PDF: $got; received $received bytes"
    [ "$received" -gt $((size * 8 / 10)) ] && r=1 || r=0
    row "7. control: reading 64 KB of it downloads the whole file, which the count sees" "$r" "$received bytes"
fi

# A Fold has two displays, and screencap then wants one named.
display=$("${ADB[@]}" shell dumpsys SurfaceFlinger --display-id 2>/dev/null | awk 'NR == 1 { print $2 }')
"${ADB[@]}" exec-out screencap ${display:+-d "$display"} -p > "$WORK/shelf.png" 2>/dev/null || true
echo "   screenshot: $WORK/shelf.png"
[ "$KEEP" -eq 1 ] || "${ADB[@]}" shell "run-as $PKG rm -rf files/thumbprobe" || true
echo
if [ "$FAILED" -eq 0 ]; then echo "PASS: every row held."; else echo "FAIL: see above."; fi
exit "$FAILED"
