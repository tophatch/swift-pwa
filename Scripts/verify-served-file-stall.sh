#!/usr/bin/env bash
#
# Check that a served file whose bytes aren't on local disk doesn't freeze the
# app while it downloads (#338), on macOS with iCloud Drive.
#
# A fresh scaffolded app serves a folder in iCloud Drive holding two 6 MB files:
# remote.bin, evicted (`brctl evict`) so reading it downloads it, and
# local.bin. Its page (served-file-stall-probe/) asks for remote.bin and then
# local.bin, and times a bridge round trip every 50ms; the script times
# `drive eval "1"` alongside. Both need the app's main thread.
#
# Rows:
#   evicted      remote.bin is dataless. The worst round trips and local.bin's
#                load time must stay well under remote.bin's download time.
#   on disk      the same, once remote.bin has downloaded — the baseline.
#
# The evicted row is only evidence if remote.bin really was dataless (checked
# before launch) and really took a while to arrive; a download faster than the
# threshold makes the row INCONCLUSIVE, not a pass.
#
# Usage:
#   Scripts/verify-served-file-stall.sh [--released] [--threshold-ms 300] [--keep]
#
#   --released   build the app against the released package, not this
#                checkout: the control, which should FAIL the evicted row.
#
# Creates its own folder in iCloud Drive and deletes it on exit.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASED=0
KEEP=0
THRESHOLD=300
SECONDS_PER_ROW=12
while [[ $# -gt 0 ]]; do
    case "$1" in
        --released) RELEASED=1; shift ;;
        --threshold-ms) THRESHOLD="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || { echo "macOS only: it needs iCloud Drive" >&2; exit 2; }
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
[[ -d "$ICLOUD" ]] || { echo "::error::iCloud Drive isn't set up for this user" >&2; exit 1; }

WORK="$(mktemp -d)"
SERVED="$ICLOUD/swift-pwa-served-file-stall-$$"
cleanup() {
    [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null
    [[ "$KEEP" == 1 ]] || rm -rf "$WORK" "$SERVED"
}
trap cleanup EXIT
APP_DIR="$WORK/ServeStallProbe"
CLI="$REPO/.build/debug/swift-pwa"

echo "→ building the CLI"
(cd "$REPO" && swift build --product swift-pwa) >/dev/null 2>&1 || {
    echo "::error::couldn't build swift-pwa"; exit 1; }

echo "→ scaffolding a probe app ($([[ $RELEASED == 1 ]] && echo "released package" || echo "this checkout"))"
(cd "$WORK" && "$CLI" init "$(basename "$APP_DIR")") >/dev/null || { echo "::error::swift-pwa init failed"; exit 1; }
python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import pathlib, re, sys
app_dir, repo, released = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
if not released:
    # The scaffold pins the released package; point it at this checkout, under
    # the checkout's directory name, which is what SwiftPM calls a path
    # dependency.
    manifest = app_dir / "Package.swift"
    text = manifest.read_text()
    text = re.sub(r'\.package\(url: "[^"]*swift-pwa"[^)]*\)', f'.package(path: "{repo}")', text)
    text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
    manifest.write_text(text)
app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text, count = re.subn(r'(?m)^func configure\(_ ctx: any AppContext\) throws \{\n',
                      'func configure(_ ctx: any AppContext) throws {\n    registerServeProbe(ctx)\n',
                      app_swift.read_text())
assert count == 1, "the scaffold's configure moved; this patch needs updating"
app_swift.write_text(text)
PY
cp "$REPO/Scripts/served-file-stall-probe/Probe.swift" "$APP_DIR/Sources/$(basename "$APP_DIR")/Probe.swift"
cp "$REPO/Scripts/served-file-stall-probe/index.html" "$APP_DIR/web/index.html"

echo "→ building the probe app"
(cd "$APP_DIR" && swift build) >/dev/null 2>&1 || {
    echo "::error::the probe app didn't build"; (cd "$APP_DIR" && swift build 2>&1 | grep -E "error" | head -20); exit 1; }
BINARY="$(cd "$APP_DIR" && swift build --show-bin-path)/$(basename "$APP_DIR")"

echo "→ putting two 6 MB files in iCloud Drive and waiting for them to upload"
mkdir -p "$SERVED"
head -c 6291456 /dev/urandom > "$SERVED/remote.bin"
head -c 6291456 /dev/urandom > "$SERVED/local.bin"

is_dataless() { [[ "$(stat -f %Sf "$1")" == *dataless* ]]; }
# `brctl evict` refuses a file that hasn't uploaded yet, so it doubles as the
# upload check.
evict() {
    for _ in $(seq 1 120); do
        brctl evict "$1" >/dev/null 2>&1 && is_dataless "$1" && return 0
        sleep 2
    done
    return 1
}

PORT=47950
PASS=0; FAIL=0; INCONCLUSIVE=0

# row <name> <want: fast|baseline>
row() {
    local name="$1" want="$2" out="$WORK/app.out" token="" result=""
    : > "$out"
    PORT=$((PORT + 1))
    SWIFT_PWA_DRIVE="$PORT" SWIFT_PWA_DRIVE_BACKGROUND=1 SWIFT_PWA_WEB_ROOT="$APP_DIR/web" \
        SERVE_PROBE_DIR="$SERVED" "$BINARY" >"$out" 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 300); do
        token="$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' "$out" | head -1)"
        [[ -n "$token" ]] && break
        sleep 0.1
    done
    [[ -n "$token" ]] || { echo "  FAIL  $name — the app never started its driver"; FAIL=$((FAIL+1)); return; }

    # `drive eval` round trips for the length of the page's own measurement.
    local worst_eval
    worst_eval="$(python3 - "$CLI" "$PORT" "$token" "$SECONDS_PER_ROW" <<'PY'
import subprocess, sys, time
cli, port, token, seconds = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
worst, end = 0.0, time.time() + seconds
while time.time() < end:
    t = time.time()
    subprocess.run([cli, "drive", "eval", "1", "--attach", port, "--token", token], capture_output=True)
    worst = max(worst, time.time() - t)
    time.sleep(0.05)
print(round(worst * 1000))
PY
)"
    for _ in $(seq 1 100); do
        result="$("$CLI" drive eval "window.__result" --attach "$PORT" --token "$token" 2>/dev/null)"
        [[ "$result" == *worstBridgeMs* ]] && break
        result=""
        sleep 0.2
    done
    kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
    [[ -n "$result" ]] || { echo "  FAIL  $name — the page never reported"; FAIL=$((FAIL+1)); return; }

    # `drive eval` hands back the page's JSON string as a JSON string.
    python3 - "$name" "$want" "$THRESHOLD" "$worst_eval" "$result" <<'PY'
import json, sys
name, want, threshold, worst_eval, raw = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
r = json.loads(raw)
while isinstance(r, str):
    r = json.loads(r)
local, remote = r["local"], r["remote"]
line = (f"bridge worst {r['worstBridgeMs']} ms ({r['rounds']} rounds), drive eval worst {worst_eval} ms, "
        f"local.bin at {local['ms']} ms, remote.bin at {remote['ms']} ms")
errors = [f"{k}: {v['error']}" for k, v in (("local.bin", local), ("remote.bin", remote)) if "error" in v]
held = max(r["worstBridgeMs"], worst_eval, local["ms"])
if errors:
    verdict = "FAIL"; line += " — " + "; ".join(errors)
elif want == "fast" and remote["ms"] < threshold:
    verdict = "INCONCLUSIVE"; line += f" — remote.bin arrived under {threshold} ms, so nothing was slow"
elif held >= threshold:
    verdict = "FAIL"; line += f" — the main thread was held {held} ms"
else:
    verdict = "PASS"
print(f"  {verdict}  {name} — {line}")
sys.exit({"PASS": 0, "FAIL": 1, "INCONCLUSIVE": 3}[verdict])
PY
    case $? in 0) PASS=$((PASS+1)) ;; 3) INCONCLUSIVE=$((INCONCLUSIVE+1)) ;; *) FAIL=$((FAIL+1)) ;; esac
}

evict "$SERVED/remote.bin" || { echo "::error::remote.bin never uploaded, or wouldn't evict"; exit 1; }
echo "→ remote.bin is dataless; running"
row "evicted" fast
if is_dataless "$SERVED/remote.bin"; then
    echo "  FAIL  on disk — remote.bin is still dataless after the app read it"; FAIL=$((FAIL+1))
else
    row "on disk (baseline)" baseline
fi

echo
echo "$PASS passed, $FAIL failed, $INCONCLUSIVE inconclusive"
[[ $FAIL == 0 && $INCONCLUSIVE == 0 ]]
