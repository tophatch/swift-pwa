#!/usr/bin/env bash
#
# `window.snapshot`: does the page get a picture of *itself*, and is it fast
# enough to animate with (#255)?
#
# The instrument is the thing to distrust here. A snapshot that comes back
# blank, black, or the wrong size still decodes, still draws, and still reports
# a plausible width — so this doesn't check that a PNG arrived. It paints the
# page a known colour with a known rectangle in it and reads the pixels back
# out of the returned image:
#
#   size      the picture is the window's CSS size times devicePixelRatio,
#             which is what a page needs to size a canvas
#   content   a pixel sampled inside the rectangle is the rectangle's colour,
#             and one outside it is the background's. A blank capture fails
#             both; a capture of the wrong window fails the second.
#   absent    `window.canSnapshot` agrees with whether `window.snapshot` works,
#             so an app can ask once instead of catching an error per call.
#
# Then it times the round trip — page to page: snapshot, encode, bridge, decode
# to an `ImageBitmap` — over three kinds of content, because what a snapshot
# costs is almost entirely how well the picture compresses, and one page would
# give one number that reads as "the" number.
#
# Usage: verify-window-snapshot.sh [--repo <dir>] [--simulator] [--keep] [--dump <dir>]
#   --simulator  drive an iOS Simulator build instead of the host app
#   --dump <dir> also write each variant's PNG there, to look at by eye — the
#                check that no automated one replaces
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
DUMP=""
DRIVE_TARGET=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --simulator) DRIVE_TARGET=(--simulator); shift ;;
        --dump) DUMP="$2"; mkdir -p "$DUMP"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

WORK="${TMPDIR:-/tmp}/swift-pwa-window-snapshot"
APP_NAME="SnapshotProbe"
APP="$WORK/$APP_NAME"
CLI="$REPO/.build/debug/swift-pwa"

cleanup() { [[ "$KEEP" -eq 1 ]] || rm -rf "$WORK"; }
trap cleanup EXIT

HEADLESS=()
if [[ "$(uname)" != "Darwin" && -z "${DISPLAY:-}" ]] && command -v xvfb-run >/dev/null; then
    HEADLESS=(xvfb-run -a)
fi

echo "== building the CLI =="
(cd "$REPO" && swift build --product swift-pwa >/dev/null)

echo "== scaffolding $APP_NAME =="
rm -rf "$WORK"; mkdir -p "$WORK"
(cd "$WORK" && "$CLI" init "$APP_NAME" >/dev/null)
cd "$APP"
sed -i.bak -e 's|\.package(url: "https://github.com/tophatch/swift-pwa", from: "[^"]*")|.package(path: "'"$REPO"'")|' Package.swift
rm -f Package.swift.bak
cp "$REPO/Package.resolved" Package.resolved 2>/dev/null || true

# Three renderings, switched from the page:
#
#   flat    a solid background and a hard-edged block. Also what the pixel
#           checks read: any resampling on the way through shows up as a pixel
#           that is neither colour. Best case, and representative of nothing.
#   text    a wall of body text — what the reader this was asked for actually
#           shows. The number to design against.
#   noise   incompressible by construction. The ceiling.
cat > web/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>snapshot probe</title>
<!-- Not decoration, and both halves earn their place on iOS. Without
     `width=device-width` the page lays out in a 980 CSS-pixel viewport, so
     `innerWidth * devicePixelRatio` is nearly three times the webview's real
     pixel size. Without `viewport-fit=cover` the layout viewport is inset by
     the status bar and home indicator while the webview still covers the whole
     screen, so the snapshot is ~96pt taller than the page thinks it is. Both
     made the size check fail against a snapshot that was right all along —
     and the second is worth knowing for any app placing one: a page that is
     not full-bleed has to account for that offset itself. -->
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>
  html, body { margin: 0; height: 100%; background: #0000ff; overflow: hidden;
               font: 16px/1.5 Georgia, serif; }
  #mark  { position: absolute; left: 0; top: 0; width: 50%; height: 50%; background: #ff0000; }
  #text  { position: absolute; inset: 0; background: #fffdf8; color: #1a1a1a; padding: 24px;
           column-count: 2; column-gap: 32px; display: none; }
  /* Explicit, not `inset: 0`: a canvas is a *replaced* element, so with
     left/right at 0 and width auto its box comes from its intrinsic size —
     which two WebKit versions resolved differently, and a canvas covering
     part of the window rather than all of it silently changed what was being
     measured. */
  #noise { position: absolute; left: 0; top: 0; display: none; }
</style>
<body>
<div id="mark"></div>
<div id="text"></div>
<canvas id="noise"></canvas>
<script>
  const words = ("the quick brown fox jumps over a lazy dog while seventeen " +
    "careful typographers argue about hyphenation and the margins of a page " +
    "that nobody will ever print but everybody will scroll past in a hurry ").split(" ");
  let prose = "";
  for (let i = 0; i < 900; i++) prose += words[i % words.length] + " ";
  document.getElementById("text").textContent = prose;

  const noise = document.getElementById("noise");
  function paintNoise() {
    // Backing store in device pixels, CSS box in CSS pixels, both stated: the
    // canvas then covers the window exactly and nothing is resampled.
    noise.width = Math.floor(innerWidth * devicePixelRatio);
    noise.height = Math.floor(innerHeight * devicePixelRatio);
    noise.style.width = innerWidth + "px";
    noise.style.height = innerHeight + "px";
    const ctx = noise.getContext("2d");
    const img = ctx.createImageData(noise.width, noise.height);
    // `crypto.getRandomValues`, not a hand-rolled LCG: the low bits of a linear
    // congruential generator are periodic — the first attempt here repeated
    // every 256 pixels, which PNG compressed to a thirtieth of the size of the
    // same picture on another engine, and read as a backend difference that
    // was not there. Filled in 64 KiB chunks, which is the API's limit.
    const chunk = new Uint8Array(65536);
    for (let i = 0; i < img.data.length; i += chunk.length) {
      crypto.getRandomValues(chunk);
      img.data.set(chunk.subarray(0, Math.min(chunk.length, img.data.length - i)), i);
    }
    // Opaque: a random alpha would make the checks read through to whatever is
    // behind the canvas.
    for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255;
    ctx.putImageData(img, 0, 0);
  }

  window.__showVariant = function (name) {
    document.getElementById("text").style.display = name === "text" ? "block" : "none";
    noise.style.display = name === "noise" ? "block" : "none";
    if (name === "noise") paintNoise();
    // A timer, not requestAnimationFrame: the driven window is behind whatever
    // launched it, and WebKit on macOS is the one engine that stops servicing
    // rAF for an occluded window — so the obvious "wait two frames" spelling
    // hangs forever here. The snapshot itself is unaffected: it renders through
    // the compositor rather than reading the screen, which is the whole reason
    // it can picture a window nobody can see.
    return new Promise(function (r) { setTimeout(r, 150); });
  };
</script>
HTML

if [[ ${#DRIVE_TARGET[@]} -eq 0 ]]; then
    echo "== building the app =="
    swift build >/dev/null 2>"$WORK/build.err" || { tail -20 "$WORK/build.err" >&2; exit 1; }
fi
# `drive --simulator` bundles and installs the app itself, so there is nothing
# useful to pre-build for that path.

# One eval does everything: it is the *page's* round trip being measured, and
# splitting it across driver calls would measure the driver instead.
read -r -d '' PROBE_JS <<'JS' || true
(async () => {
  const out = { variants: {} };
  const dump = __DUMP__;
  let shotBase64Length = 0;
  let shotPngBase64 = '';
  const can = await __SWIFT_PWA__.invoke('window.canSnapshot');
  out.canSnapshot = can.value;
  if (!can.value) return JSON.stringify(out);

  const measure = async () => {
    const t0 = performance.now();
    const shot = await __SWIFT_PWA__.invoke('window.snapshot');
    const bridgeMs = performance.now() - t0;
    shotBase64Length = shot.pngBase64.length;
    shotPngBase64 = shot.pngBase64;
    const blob = await (await fetch('data:image/png;base64,' + shot.pngBase64)).blob();
    const bitmap = await createImageBitmap(blob);
    return { shot, bitmap, ms: Math.round(performance.now() - t0), bridgeMs: Math.round(bridgeMs) };
  };

  // One snapshot thrown away first. The first call of the run pays a one-off
  // cost — on iOS it measured 134 ms against 53 ms for the *larger* frame right
  // after it — and reporting that as the cost of a page curl would be wrong in
  // the direction that matters.
  await window.__showVariant('flat');
  (await measure()).bitmap.close();

  // How many distinct colours a 32x32 patch holds. True noise fills it;
  // anything that resampled, blurred or averaged on the way through collapses
  // it — which a single sampled pixel and a plausible byte count both miss.
  const patchDetail = (source, w, h) => {
    const canvas = document.createElement('canvas');
    canvas.width = 32;
    canvas.height = 32;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(source, Math.floor(w * 0.5), Math.floor(h * 0.6), 32, 32, 0, 0, 32, 32);
    const px = ctx.getImageData(0, 0, 32, 32).data;
    const seen = new Set();
    for (let i = 0; i < px.length; i += 4) seen.add((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]);
    return seen.size;
  };

  const sample = (bitmap, fx, fy) => {
    const canvas = document.createElement('canvas');
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(bitmap, 0, 0);
    const px = ctx.getImageData(
      Math.floor(bitmap.width * fx), Math.floor(bitmap.height * fy), 1, 1
    ).data;
    return '#' + [px[0], px[1], px[2]].map(v => v.toString(16).padStart(2, '0')).join('');
  };

  for (const name of ['flat', 'text', 'noise']) {
    await window.__showVariant(name);
    const m = await measure();
    out.variants[name] = {
      ms: m.ms, bridgeMs: m.bridgeMs, kib: Math.round(m.shot.bytes / 1024),
      // Every variant gets a pixel read out of it, not just the first: a
      // backend whose snapshot silently misses `<canvas>` content would
      // otherwise sail through, reported only as a suspiciously small PNG.
      sample: sample(m.bitmap, 0.75, 0.75),
      detail: patchDetail(m.bitmap, m.shot.width, m.shot.height),
      // `bytes` is what the backend said; this is what actually arrived.
      // GTK3 reported a `noise` frame of 59 KiB whose pixels were full-detail
      // noise, which is not something a lossless encoder can do — so the
      // reported size and the delivered bytes are worth separating.
      b64Bytes: Math.round(shotBase64Length * 3 / 4)
    };
    if (dump) out.variants[name].png = shotPngBase64;
    // What the page itself holds, for the same patch — the control that says
    // whether a thin `noise` frame is the backend's doing or the page's.
    if (name === 'noise') {
      const c = document.getElementById('noise');
      out.canvasDetail = patchDetail(c, c.width, c.height);
    }
    if (name !== 'flat') { m.bitmap.close(); continue; }

    // The flat frame is the one the size and colour checks read.
    out.width = m.shot.width;
    out.height = m.shot.height;
    out.decodedWidth = m.bitmap.width;
    out.decodedHeight = m.bitmap.height;
    out.expectedWidth = Math.round(window.innerWidth * window.devicePixelRatio);
    out.expectedHeight = Math.round(window.innerHeight * window.devicePixelRatio);

    out.inside = sample(m.bitmap, 0.25, 0.25);   // the red mark
    out.outside = sample(m.bitmap, 0.75, 0.75);  // the blue page behind it
    m.bitmap.close();
  }
  return JSON.stringify(out);
})()
JS

echo
echo "== driving =="
[[ -n "$DUMP" ]] && PROBE_JS="${PROBE_JS/__DUMP__/true}" || PROBE_JS="${PROBE_JS/__DUMP__/false}"

OUT=$(${HEADLESS[@]+"${HEADLESS[@]}"} "$CLI" drive eval ${DRIVE_TARGET[@]+"${DRIVE_TARGET[@]}"} \
    --timeout 600 "$PROBE_JS" 2>"$WORK/drive.err") \
    || { tail -20 "$WORK/drive.err" >&2; exit 1; }

# Through stdin, not argv: with --dump the reply carries whole PNGs, and a
# multi-megabyte argument is past ARG_MAX — which fails as an empty run rather
# than as an error.
printf '%s' "$OUT" | python3 "$REPO/Scripts/report-window-snapshot.py" ${DUMP:+--dump "$DUMP"}
