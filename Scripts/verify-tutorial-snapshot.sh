#!/usr/bin/env bash
#
# Run the `window.snapshot` code from docs/tutorials/making-it-feel-native.md
# against a real app, exactly as it is written there.
#
# The code is **extracted from the tutorial**, not retyped here: a snippet that
# has drifted from the page it is printed on is worse than no snippet, because
# it still looks authoritative. If someone edits the tutorial's JS into
# something that doesn't run, this fails.
#
# What it checks, in one driven run:
#
#   frozen     the overlay exists while the transition is mid-flight, covers
#              the viewport, and is a decoded image with real pixel dimensions
#   ordering   the frozen copy shows the page as it was BEFORE the change —
#              the whole point, and the thing that breaks if a backend's
#              snapshot flushes layout after the mutation instead of before
#   cleanup    the overlay is gone afterwards and the page shows the new state
#
# Usage: verify-tutorial-snapshot.sh [--repo <dir>] [--keep]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

WORK="${TMPDIR:-/tmp}/swift-pwa-tutorial-snapshot"
APP_NAME="TutorialSnapshot"
APP="$WORK/$APP_NAME"
CLI="$REPO/.build/debug/swift-pwa"
TUTORIAL="$REPO/docs/tutorials/making-it-feel-native.md"

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
sed -i.bak -e "s|package: \"swift-pwa\"|package: \"$(basename "$REPO")\"|" Package.swift
rm -f Package.swift.bak
cp "$REPO/Package.resolved" Package.resolved 2>/dev/null || true

# The tutorial's own `freezeScreen` / `crossfade`, lifted out of the prose.
python3 - "$TUTORIAL" "$WORK/tutorial.js" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
blocks = re.findall(r"```js\n(.*?)```", text, re.S)
wanted = [b for b in blocks if "freezeScreen" in b and "crossfade" in b]
if len(wanted) != 1:
    sys.exit("expected exactly one js block defining freezeScreen + crossfade, found %d"
             % len(wanted))
pathlib.Path(sys.argv[2]).write_text(wanted[0])
print("   extracted %d lines from the tutorial" % wanted[0].count("\n"))
PY

# A page with two states and a colour for each, so "which one did the picture
# catch" has an answer a pixel can give.
cat > web/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>tutorial snapshot</title>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>
  html, body { margin: 0; height: 100%; }
  body { background: #00aa00; }              /* the BEFORE state */
  body.after { background: #aa0000; }        /* the AFTER state */
</style>
<body><script>
  window.__showChapter = function () { document.body.classList.add('after'); };
</script>
HTML

echo "== building the app =="
swift build >/dev/null 2>"$WORK/build.err" || { tail -20 "$WORK/build.err" >&2; exit 1; }

# `<<'JS'` — **quoted**, so the shell expands nothing. An unquoted heredoc here
# ran command substitution on a backticked word inside a JS comment
# (`.finished: command not found`) and corrupted the script it was building.
# Never assemble JavaScript in an expanding heredoc.
cat > "$WORK/harness.template.js" <<'JS'
(async () => {
/*__TUTORIAL_JS__*/

  const out = {};
  const can = await __SWIFT_PWA__.invoke('window.canSnapshot');
  out.canSnapshot = can.value;

  // Raise the window first. WebKit on macOS stops servicing animations for an
  // occluded window, and a driven app launches behind whatever started it — so
  // the fade's promise would never resolve and this would read as the
  // tutorial's code hanging. The snapshot itself is unaffected: it renders
  // through the compositor, not the screen.
  await __SWIFT_PWA__.invoke('window.focus');
  await new Promise(r => setTimeout(r, 300));

  // Run the tutorial's own crossfade and look at the page while it is still in
  // flight: an overlay that is never added and one that is added and removed
  // look identical from the end.
  const settled = crossfade(() => window.__showChapter());
  await new Promise(r => setTimeout(r, 80));

  const frozen = document.querySelector('img[style*="9999"]');
  out.overlayPresent = !!frozen;
  if (frozen) {
    out.overlayCovers = frozen.clientWidth === innerWidth && frozen.clientHeight === innerHeight;
    out.overlayPixels = frozen.naturalWidth + 'x' + frozen.naturalHeight;
    // What the frozen copy actually pictured. Had it caught the page AFTER the
    // change this would be the new colour, and the transition would have shown
    // nothing at all.
    const c = document.createElement('canvas');
    c.width = frozen.naturalWidth; c.height = frozen.naturalHeight;
    const ctx = c.getContext('2d');
    ctx.drawImage(frozen, 0, 0);
    const d = ctx.getImageData(Math.floor(c.width / 2), Math.floor(c.height / 2), 1, 1).data;
    out.frozenColour = '#' + [d[0], d[1], d[2]]
      .map(v => v.toString(16).padStart(2, '0')).join('');
  }
  // …while the live page underneath has already moved on.
  out.liveClass = document.body.className;

  await settled;
  out.overlayRemoved = !document.querySelector('img[style*="9999"]');
  return JSON.stringify(out);
})()
JS

python3 - "$WORK/harness.template.js" "$WORK/tutorial.js" "$WORK/harness.js" <<'PY'
import pathlib, sys
template, tutorial, out = (pathlib.Path(a) for a in sys.argv[1:4])
body = template.read_text()
assert "/*__TUTORIAL_JS__*/" in body
out.write_text(body.replace("/*__TUTORIAL_JS__*/", tutorial.read_text().rstrip()))
PY

HARNESS="$(cat "$WORK/harness.js")"

echo
echo "== driving =="
if ! OUT=$(${HEADLESS[@]+"${HEADLESS[@]}"} "$CLI" drive eval --timeout 300 "$HARNESS" \
        2>"$WORK/drive.err"); then
    tail -25 "$WORK/drive.err" >&2
    exit 1
fi
if [[ -z "$OUT" ]]; then
    echo "the driver returned nothing; its stderr:" >&2
    tail -25 "$WORK/drive.err" >&2
    exit 1
fi

# The reporter goes to a file first: `python3 - <<'PY'` takes its *program*
# on stdin, so a pipe into it is silently swallowed and the script reads an
# empty string.
cat > "$WORK/report.py" <<'PY'
import json, sys

raw = sys.stdin.read().strip().splitlines()[-1].strip()
value = raw
for _ in range(4):
    if isinstance(value, dict):
        break
    try:
        value = json.loads(value)
    except Exception:
        break
if not isinstance(value, dict):
    sys.exit("could not decode the reply: " + repr(raw[-200:]))

failed = 0


def check(label, ok, detail):
    global failed
    print(("PASS  " if ok else "FAIL  ") + label.ljust(52) + detail)
    if not ok:
        failed = 1


print()
check("window.canSnapshot says yes", value.get("canSnapshot") is True,
      "canSnapshot=%s" % value.get("canSnapshot"))
check("the tutorial's freezeScreen puts an overlay on the page",
      value.get("overlayPresent") is True, "present=%s" % value.get("overlayPresent"))
check("it covers the viewport", value.get("overlayCovers") is True,
      "css size matches innerWidth/innerHeight, image is %s device px"
      % value.get("overlayPixels"))
# The ordering claim the tutorial makes in bold, and the one a backend could
# quietly break: snapshot first, change second.
check("the frozen copy shows the page BEFORE the change",
      value.get("frozenColour") == "#00aa00",
      "frozen=%s (before is #00aa00, after is #aa0000)" % value.get("frozenColour"))
check("the live page underneath has already changed",
      value.get("liveClass") == "after", "body.className=%r" % value.get("liveClass"))
check("the overlay is gone when the animation finishes",
      value.get("overlayRemoved") is True, "removed=%s" % value.get("overlayRemoved"))

print()
sys.exit(failed)
PY
printf '%s' "$OUT" | python3 "$WORK/report.py"
