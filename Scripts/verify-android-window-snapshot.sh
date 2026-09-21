#!/usr/bin/env bash
#
# `window.snapshot` on a real Android device (#255).
#
# Android is the one backend that had no snapshot at all before this: the other
# four already rendered their webview's pixels for the driver's `screenshot`
# verb. Here the Kotlin bridge draws the `WebView` into a `Bitmap`, so this is
# new code on the platform whose WebView is hardware-accelerated — and
# `View.draw` into a *software* canvas is exactly the case where an accelerated
# view can hand back a blank or black frame instead of its contents.
#
# So the checks read the pixels back rather than trusting that a PNG arrived:
#
#   1. `window.canSnapshot` says yes.
#   2. The picture is the webview's size in device pixels, and the PNG's own
#      header agrees with the decoded image.
#   3. A pixel inside a known rectangle is that rectangle's colour, and one
#      outside it is the background's. A blank, black or transparent capture
#      fails this and nothing else.
#   4. A frame of `crypto.getRandomValues` noise carries the same per-pixel
#      detail the page's own canvas holds — an accelerated layer that came
#      back smoothed, or a canvas that never composited into the view's draw
#      pass, shows up here and only here.
#
# There is no `swift-pwa drive` for Android, so the page runs the checks itself
# and reports through `RuntimeDiagnostics` into logcat. That caps what can be
# reported: a logcat line is truncated around 4 KB, so the PNG never goes to
# the log — only the numbers read out of it.
#
# Usage:
#   Scripts/verify-android-window-snapshot.sh [-s <adb-serial>] [-k]
#     -s  adb serial to target (default: the only attached device)
#     -k  keep the scaffolded app directory for debugging
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
KEEP=0
while getopts "s:k" opt; do
    case "$opt" in
        s) SERIAL="$OPTARG" ;;
        k) KEEP=1 ;;
        *) echo "usage: $0 [-s serial] [-k]" >&2; exit 2 ;;
    esac
done

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

WORK="${TMPDIR:-/tmp}/swift-pwa-android-snapshot"
APP="SnapshotCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.snapshotcheck"

cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "no device: attach one over USB (wireless adb ports rotate and are flaky)" >&2
    exit 1
fi

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

# The only thing the app adds is a way to say what it found. `window.*` is
# built in on every backend, so the capability under test needs no registration.
probe = '''import Foundation
import SwiftPWA

struct ProbeReport: Codable, Sendable { let line: String }
struct ProbeAck: Encodable, Sendable { let ok: Bool }

@MainActor
func registerProbes(_ ctx: any AppContext) {
    ctx.registry.register("probe.record", typed: { (args: ProbeReport, _) -> ProbeAck in
        RuntimeDiagnostics.emit("SNAPPROBE " + args.line)
        return ProbeAck(ok: true)
    })
}
'''
(app_dir / "Sources" / app_dir.name / "Probe.swift").write_text(probe)

app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text = app_swift.read_text()
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    registerProbes(ctx)\n\n    _ = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app_swift.write_text(text)
PY

cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>snapshot check</title>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>
  html, body { margin: 0; height: 100%; background: #0000ff; overflow: hidden;
               font: 16px/1.5 serif; }
  #mark  { position: absolute; left: 0; top: 0; width: 50%; height: 50%; background: #ff0000; }
  #text  { position: absolute; inset: 0; background: #fffdf8; color: #1a1a1a; padding: 24px;
           display: none; }
  #noise { position: absolute; left: 0; top: 0; display: none; }
</style>
<body>
<div id="mark"></div>
<div id="text"></div>
<canvas id="noise"></canvas>
<script>
(function () {
  function report(line) { return __SWIFT_PWA__.invoke('probe.record', { line: line }); }

  var words = ('the quick brown fox jumps over a lazy dog while seventeen ' +
    'careful typographers argue about hyphenation and the margins of a page ' +
    'that nobody will ever print but everybody will scroll past in a hurry ').split(' ');
  var prose = '';
  for (var w = 0; w < 900; w++) prose += words[w % words.length] + ' ';
  document.getElementById('text').textContent = prose;

  var noise = document.getElementById('noise');
  function paintNoise() {
    noise.width = Math.floor(innerWidth * devicePixelRatio);
    noise.height = Math.floor(innerHeight * devicePixelRatio);
    noise.style.width = innerWidth + 'px';
    noise.style.height = innerHeight + 'px';
    var ctx = noise.getContext('2d');
    var img = ctx.createImageData(noise.width, noise.height);
    // Real randomness: the low bits of a hand-rolled LCG are periodic, which
    // compresses and would read as a backend difference that isn't there.
    var chunk = new Uint8Array(65536);
    for (var i = 0; i < img.data.length; i += chunk.length) {
      crypto.getRandomValues(chunk);
      img.data.set(chunk.subarray(0, Math.min(chunk.length, img.data.length - i)), i);
    }
    for (var j = 3; j < img.data.length; j += 4) img.data[j] = 255;
    ctx.putImageData(img, 0, 0);
  }

  function draw(source, w, h) {
    var canvas = document.createElement('canvas');
    canvas.width = w; canvas.height = h;
    canvas.getContext('2d').drawImage(source, 0, 0);
    return canvas.getContext('2d');
  }
  function hexAt(ctx, x, y) {
    var d = ctx.getImageData(x, y, 1, 1).data;
    return '#' + [d[0], d[1], d[2]].map(function (v) {
      return v.toString(16).padStart(2, '0');
    }).join('');
  }
  // Distinct colours in a 32x32 patch. True noise fills it; anything smoothed,
  // downscaled or never composited collapses it.
  function patchDetail(source, w, h) {
    var canvas = document.createElement('canvas');
    canvas.width = 32; canvas.height = 32;
    var ctx = canvas.getContext('2d');
    ctx.drawImage(source, Math.floor(w * 0.5), Math.floor(h * 0.6), 32, 32, 0, 0, 32, 32);
    var px = ctx.getImageData(0, 0, 32, 32).data;
    var seen = {};
    var n = 0;
    for (var i = 0; i < px.length; i += 4) {
      var key = (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
      if (!seen[key]) { seen[key] = 1; n++; }
    }
    return n;
  }

  function snapshot() {
    var t0 = performance.now();
    return __SWIFT_PWA__.invoke('window.snapshot').then(function (shot) {
      var bridgeMs = performance.now() - t0;
      return fetch('data:image/png;base64,' + shot.pngBase64)
        .then(function (r) { return r.blob(); })
        .then(createImageBitmap)
        .then(function (bitmap) {
          return {
            shot: shot, bitmap: bitmap,
            ms: Math.round(performance.now() - t0),
            bridgeMs: Math.round(bridgeMs)
          };
        });
    });
  }

  __SWIFT_PWA__.invoke('window.canSnapshot').then(function (can) {
    return report('can ' + can.value).then(function () {
      if (!can.value) throw new Error('canSnapshot is false');
    });
  }).then(function () {
    // One thrown away: the first call of a run pays a one-off cost, and
    // reporting that as the cost of an animation would mislead.
    return snapshot().then(function (m) { m.bitmap.close(); });
  }).then(function () {
    return snapshot();
  }).then(function (m) {
    var ctx = draw(m.bitmap, m.bitmap.width, m.bitmap.height);
    return report('flat size=' + m.shot.width + 'x' + m.shot.height +
                  ' decoded=' + m.bitmap.width + 'x' + m.bitmap.height +
                  ' expected=' + Math.round(innerWidth * devicePixelRatio) +
                  'x' + Math.round(innerHeight * devicePixelRatio) +
                  ' inside=' + hexAt(ctx, Math.floor(m.bitmap.width * 0.25),
                                     Math.floor(m.bitmap.height * 0.25)) +
                  ' outside=' + hexAt(ctx, Math.floor(m.bitmap.width * 0.75),
                                      Math.floor(m.bitmap.height * 0.75)) +
                  ' ms=' + m.ms + ' bridgeMs=' + m.bridgeMs +
                  ' kib=' + Math.round(m.shot.bytes / 1024))
      .then(function () { m.bitmap.close(); });
  }).then(function () {
    // The case this was asked for, and the one to design against: a page of
    // body text, which is neither a flat colour nor incompressible noise.
    document.getElementById('text').style.display = 'block';
    return new Promise(function (r) { setTimeout(r, 300); });
  }).then(function () {
    return snapshot();
  }).then(function (m) {
    m.bitmap.close();
    return report('text ms=' + m.ms + ' bridgeMs=' + m.bridgeMs +
                  ' kib=' + Math.round(m.shot.bytes / 1024));
  }).then(function () {
    document.getElementById('text').style.display = 'none';
    noise.style.display = 'block';
    paintNoise();
    return new Promise(function (r) { setTimeout(r, 300); });
  }).then(function () {
    return snapshot();
  }).then(function (m) {
    var detail = patchDetail(m.bitmap, m.shot.width, m.shot.height);
    var canvasDetail = patchDetail(noise, noise.width, noise.height);
    m.bitmap.close();
    return report('noise detail=' + detail + ' canvasDetail=' + canvasDetail +
                  ' ms=' + m.ms + ' bridgeMs=' + m.bridgeMs +
                  ' kib=' + Math.round(m.shot.bytes / 1024));
  }).then(function () {
    document.body.textContent = 'done';
    return report('finished');
  }, function (e) {
    return report('THREW ' + e);
  });
})();
</script>
HTML

cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"
rm -rf "$APP_DIR/.build"

echo "== resolving dependencies =="
if ! (cd "$APP_DIR" && swift package resolve >/dev/null 2>"$WORK/resolve.err"); then
    tail -5 "$WORK/resolve.err" >&2
    exit 1
fi

echo "== cross-compiling, installing and launching on the device =="
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a)

"${ADB[@]}" logcat -c || true
"${ADB[@]}" shell am force-stop "$PKG" || true
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
"${ADB[@]}" shell sleep 25 >/dev/null 2>&1 || true

LOG="$WORK/logcat.txt"
"${ADB[@]}" logcat -d -s swift-pwa > "$LOG" 2>/dev/null || true

echo
echo "-- what the page saw --"
grep -o 'SNAPPROBE .*' "$LOG" | sed 's/^/   /' || echo "   (nothing)"
echo

failed=0
expect() { # label pattern
    local label="$1" pattern="$2"
    if grep -qE "$pattern" "$LOG"; then
        echo "PASS  $label"
    else
        echo "FAIL  $label"
        failed=1
    fi
}

expect "the page reported at all (control)" 'SNAPPROBE '
expect "window.canSnapshot says yes" 'SNAPPROBE can true'
expect "the PNG header agrees with the decoded image" \
    'SNAPPROBE flat size=([0-9]+)x([0-9]+) decoded=\1x\2'
expect "a pixel inside the mark is the mark's colour" 'SNAPPROBE flat .*inside=#ff0000'
expect "a pixel outside it is the page behind" 'SNAPPROBE flat .*outside=#0000ff'
expect "the page ran to the end" 'SNAPPROBE finished'

# The size and detail checks need the numbers compared, not matched.
# `|| python_status=$?` rather than reading `$?` after: under `set -e` a
# non-zero exit would end the script before the assignment ran, and the device
# would be left with the probe app installed.
python_status=0
python3 - "$LOG" <<'PY' || python_status=$?
import re, sys
log = open(sys.argv[1], encoding="utf-8", errors="replace").read()

def field(line_prefix, name, cast=int):
    m = re.search(r"SNAPPROBE %s .*?\b%s=(\S+)" % (line_prefix, name), log)
    return cast(m.group(1)) if m else None

failed = 0
def check(label, ok, detail):
    global failed
    print(("PASS  " if ok else "FAIL  ") + label.ljust(48) + detail)
    if not ok:
        failed = 1

m = re.search(r"SNAPPROBE flat size=(\d+)x(\d+) .*?expected=(\d+)x(\d+)", log)
if not m:
    print("FAIL  the picture is the webview at its backing scale   (no report)")
    sys.exit(1)
w, h, ew, eh = (int(g) for g in m.groups())
# Android draws the whole view, and a page that is not full-bleed has a layout
# viewport inset by the system bars — the same gap iOS has. Within a few pixels
# means the two agree; a large difference is worth seeing rather than hiding.
check("the picture is the webview at its backing scale",
      abs(w - ew) <= 2 and abs(h - eh) <= 2,
      "got=%dx%d expected~%dx%d" % (w, h, ew, eh))

detail = field("noise", "detail")
canvas_detail = field("noise", "canvasDetail")
# The check this script exists for: an accelerated WebView drawn into a
# software canvas is exactly where a blank or smoothed frame comes back, and
# every other check passes regardless.
check("the noise frame carries the canvas's own detail",
      detail is not None and canvas_detail and detail >= canvas_detail * 0.5,
      "%s distinct colours in a 32x32 patch against %s in the page's own canvas"
      % (detail, canvas_detail))

print()
print("      round trip, page to page — snapshot, encode, bridge, decode, at %dx%d:" % (w, h))
print("      " + "content".ljust(12) + "total".rjust(8) + "bridge".rjust(9) + "PNG".rjust(11))
for name, label in (("flat", "flat"), ("text", "body text"), ("noise", "noise")):
    ms, bridge, kib = field(name, "ms"), field(name, "bridgeMs"), field(name, "kib")
    if ms is None:
        continue
    print("      " + label.ljust(12) + ("%d ms" % ms).rjust(8)
          + ("%d ms" % bridge).rjust(9) + ("%d KiB" % kib).rjust(11))
print()
sys.exit(failed)
PY

"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true

[ "$failed" -eq 0 ] && [ "$python_status" -eq 0 ] || exit 1
echo "A page on Android gets a picture of itself, and it is really its own pixels."
