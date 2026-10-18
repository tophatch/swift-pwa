#!/usr/bin/env bash
#
# What a page receives on `app.openFile` when macOS opens a file with the app
# (#298): Launch Services delivers it, and the payload carries the path, the
# file's name, and `null` for the type, since nothing sent one. The name has a
# space and an underscore, so a pass also proves it isn't percent-encoded.
#
# Runs a fresh `init` app (not an Example), pointed at this checkout, opened
# with `open -a … <file>` exactly as Finder's "Open With" does, and reads the
# page over the driver socket.
#
# Usage:
#   Scripts/verify-open-file-macos.sh [-k]
#     -k  keep the scaffolded app directory for debugging
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
while getopts "k" opt; do
    case "$opt" in
        k) KEEP=1 ;;
        *) echo "usage: $0 [-k]" >&2; exit 2 ;;
    esac
done

WORK="${TMPDIR:-/tmp}/swift-pwa-open-file-macos"
APP="OpenCheck"
APP_DIR="$WORK/$APP"
FILE="$WORK/Open Check_01.pdf"
LOG="$WORK/app.log"

cleanup() {
    pkill -f "$APP_DIR/build/macos/$APP.app/Contents/MacOS/$APP" 2>/dev/null || true
    [ "$KEEP" -eq 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK"

echo "== building the CLI =="
(cd "$REPO" && swift build --product swift-pwa >/dev/null)
CLI="$REPO/.build/debug/swift-pwa"

echo "== scaffolding $APP against this checkout =="
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
PY

cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>open file check</title>
<body style="font:14px system-ui;padding:24px">waiting for app.openFile…</body>
<script>
window.__opened = [];
__SWIFT_PWA__.on('app.openFile', function (payload) {
  window.__opened.push(payload);
  document.body.textContent = JSON.stringify(payload);
});
</script>
HTML

echo "== bundling a debug .app (debug so the driver is compiled in) =="
(cd "$APP_DIR" && "$CLI" build --target macos --configuration debug >"$WORK/build.log" 2>&1) \
    || { tail -30 "$WORK/build.log"; exit 1; }

printf '%%PDF-1.4\n%%swift-pwa open-file check\n' > "$FILE"

echo "== opening the file with the app =="
# A new instance (-n), so an older run's app can't take the open event.
open -n -a "$APP_DIR/build/macos/$APP.app" --env SWIFT_PWA_DRIVE=0 \
    --stdout "$LOG" --stderr "$LOG" "$FILE"
for _ in $(seq 1 60); do grep -q "driver listening" "$LOG" 2>/dev/null && break; sleep 0.5; done
PORT=$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$LOG" | head -1)
TOKEN=$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' "$LOG" | head -1)
if [ -z "$PORT" ]; then cat "$LOG"; echo "FAIL the app never announced a driver port"; exit 1; fi

OUT=$("$CLI" drive eval --attach "$PORT" --token "$TOKEN" \
    --wait "window.__opened.length > 0" "JSON.stringify(window.__opened.at(-1))")
python3 - "$OUT" "$FILE" <<'PY'
import json, sys
raw, path = sys.argv[1:3]
value = json.loads(raw)
payload = json.loads(value) if isinstance(value, str) else value  # drive prints JSON in JSON
print("  payload:", json.dumps(payload))
real = lambda p: __import__("os").path.realpath(p)
ok = (len(payload.get("paths", [])) == 1
      and real(payload["paths"][0]) == real(path)
      and payload.get("names") == ["Open Check_01.pdf"]
      and payload.get("mimeTypes") == [None])
print("PASS open with (macOS)" if ok else "FAIL open with (macOS)")
sys.exit(0 if ok else 1)
PY
