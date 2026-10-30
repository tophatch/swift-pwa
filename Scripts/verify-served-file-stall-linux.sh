#!/usr/bin/env bash
#
# Check that a served file on a slow mount doesn't freeze the app (#338), on
# Linux with a FUSE mount. The twin of verify-served-file-stall.sh (macOS,
# iCloud) and verify-served-file-stall.ps1 (Windows, OneDrive). Run it on the
# Linux box itself, under the backend the build selects (SWIFT_PWA_GTK4=1 for
# GTK4).
#
# A fresh scaffolded app serves a folder holding two 6 MB files, remote.bin and
# local.bin. Its page (served-file-stall-probe/) asks for remote.bin and then
# local.bin, and times a bridge round trip every 50ms; each needs the app's
# main thread. The page writes its result to a file and quits.
#
# Rows:
#   slow mount   the folder is behind a FUSE mount (served-file-stall-probe/
#                slowfs.py) where every lookup and open of remote.bin takes
#                --delay seconds, as on a network mount. The worst round trip
#                and local.bin's load time must stay well under that.
#   local disk   the same folder served directly — the baseline.
#
# The slow row is only evidence if the mount really is slow: the script times
# the first byte of remote.bin through it before launching, and a remote.bin
# that arrived faster than the threshold makes the row INCONCLUSIVE, not a pass.
#
# Usage:
#   Scripts/verify-served-file-stall-linux.sh [--released] [--delay 1.5]
#       [--threshold-ms 300] [--toolchain 6.3.1] [--keep]
#
#   --released    build the app against the released package, not this
#                 checkout: the control, which should FAIL the slow row.
#   --toolchain   run swift under `swiftly run +<v>`, for a box with no
#                 toolchain matching .swift-version.
#
# Needs libfuse 2 (libfuse.so.2, plus the setuid fusermount) and xvfb-run.
# Unlike its twins it downloads something: fusepy's fuse.py, which drives
# libfuse from Python with no compiler or root. It is pinned by checksum and
# cached under ~/.cache/swift-pwa, never added to the repo. fusepy has no
# libfuse 3 support, so a box with only libfuse3 can't run this.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASED=0
KEEP=0
THRESHOLD=300
DELAY=1.5
TOOLCHAIN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --released) RELEASED=1; shift ;;
        --delay) DELAY="$2"; shift 2 ;;
        --threshold-ms) THRESHOLD="$2"; shift 2 ;;
        --toolchain) TOOLCHAIN="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == Linux ]] || { echo "Linux only: it needs a FUSE mount and a GTK backend" >&2; exit 2; }
for tool in xvfb-run fusermount curl python3; do
    command -v "$tool" >/dev/null || { echo "::error::$tool isn't installed" >&2; exit 1; }
done
ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' || {
    echo "::error::libfuse.so.2 isn't installed (fusepy can't drive libfuse 3)" >&2; exit 1; }

# swiftly is not always on a non-interactive shell's PATH (an ssh command);
# adding both of its install locations is harmless when it already is.
export PATH="$HOME/.local/share/swiftly/bin:$HOME/.swiftly/bin:$PATH"
SWIFT=(swift)
[[ -n "$TOOLCHAIN" ]] && SWIFT=(swiftly run "+$TOOLCHAIN" swift)
# The libxml2 compat shim Scripts/remote-linux.sh provisions on libxml2 >= 2.14
# distros; stay out of the way where the box's own libxml2 is old enough.
XML_LIB="$HOME/Code-3p/libxml2-compat/install/lib"
LINK_FLAGS=()
if [[ -f "$XML_LIB/libxml2.so.2" ]]; then
    export LD_LIBRARY_PATH="$XML_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    LINK_FLAGS=(-Xlinker -rpath-link -Xlinker "$XML_LIB")
fi

FUSEPY_VERSION=3.0.1
FUSEPY_SHA256=72ff783ec2f43de3ab394e3f7457605bf04c8cf288a2f4068b4cde141d4ee6bd
FUSEPY_URL="https://files.pythonhosted.org/packages/04/0b/4506cb2e831cea4b0214d3625430e921faaa05a7fb520458c75a2dbd2152/fusepy-$FUSEPY_VERSION.tar.gz"
FUSEPY_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/swift-pwa/fusepy-$FUSEPY_VERSION"
if [[ ! -f "$FUSEPY_DIR/fuse.py" ]]; then
    echo "→ fetching fusepy $FUSEPY_VERSION"
    mkdir -p "$FUSEPY_DIR"
    curl -fsSL "$FUSEPY_URL" -o "$FUSEPY_DIR/sdist.tar.gz" || { echo "::error::couldn't download fusepy"; exit 1; }
    echo "$FUSEPY_SHA256  $FUSEPY_DIR/sdist.tar.gz" | sha256sum -c --quiet - || {
        echo "::error::fusepy's checksum doesn't match"; rm -f "$FUSEPY_DIR/sdist.tar.gz"; exit 1; }
    tar -xzf "$FUSEPY_DIR/sdist.tar.gz" -C "$FUSEPY_DIR" --strip-components=1 "fusepy-$FUSEPY_VERSION/fuse.py"
    rm -f "$FUSEPY_DIR/sdist.tar.gz"
fi

WORK="$(mktemp -d)"
BACKING="$WORK/backing"
MOUNT="$WORK/mnt"
cleanup() {
    [[ -n "${FUSE_PID:-}" ]] && { fusermount -u "$MOUNT" 2>/dev/null; wait "$FUSE_PID" 2>/dev/null; }
    [[ "$KEEP" == 1 ]] || rm -rf "$WORK"
}
trap cleanup EXIT
APP_DIR="$WORK/ServeStallProbe"
CLI="$REPO/.build/debug/swift-pwa"

echo "→ building the CLI"
(cd "$REPO" && "${SWIFT[@]}" build --product swift-pwa "${LINK_FLAGS[@]}") >"$WORK/cli-build.log" 2>&1 || {
    echo "::error::couldn't build swift-pwa"; tail -20 "$WORK/cli-build.log"; exit 1; }

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
    text, count = re.subn(r'\.package\(url: "[^"]*swift-pwa"[^)]*\)', f'.package(path: "{repo}")',
                          manifest.read_text())
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    manifest.write_text(text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"'))
app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text, count = re.subn(r'(?m)^func configure\(_ ctx: any AppContext\) throws \{\n',
                      'func configure(_ ctx: any AppContext) throws {\n    registerServeProbe(ctx)\n',
                      app_swift.read_text())
assert count == 1, "the scaffold's configure moved; this patch needs updating"
app_swift.write_text(text)
PY
[[ $? == 0 ]] || exit 1
cp "$REPO/Scripts/served-file-stall-probe/Probe.swift" "$APP_DIR/Sources/$(basename "$APP_DIR")/Probe.swift"
cp "$REPO/Scripts/served-file-stall-probe/index.html" "$APP_DIR/web/index.html"

echo "→ building the probe app"
(cd "$APP_DIR" && "${SWIFT[@]}" build "${LINK_FLAGS[@]}") >/dev/null 2>&1 || {
    echo "::error::the probe app didn't build"
    (cd "$APP_DIR" && "${SWIFT[@]}" build "${LINK_FLAGS[@]}" 2>&1 | grep -E "error" | head -20); exit 1; }
BINARY="$(cd "$APP_DIR" && "${SWIFT[@]}" build --show-bin-path)/$(basename "$APP_DIR")"

echo "→ mounting two 6 MB files behind a FUSE mount that takes ${DELAY}s per lookup and open"
mkdir -p "$BACKING" "$MOUNT"
head -c 6291456 /dev/urandom > "$BACKING/remote.bin"
head -c 6291456 /dev/urandom > "$BACKING/local.bin"
PYTHONPATH="$FUSEPY_DIR" python3 "$REPO/Scripts/served-file-stall-probe/slowfs.py" "$BACKING" "$MOUNT" "$DELAY" \
    >"$WORK/slowfs.log" 2>&1 &
FUSE_PID=$!
for _ in $(seq 1 50); do mountpoint -q "$MOUNT" && break; sleep 0.1; done
mountpoint -q "$MOUNT" || { echo "::error::the FUSE mount never came up"; cat "$WORK/slowfs.log"; exit 1; }

# The control that must succeed: the mount really is slow.
started=$(date +%s%N)
head -c 1 "$MOUNT/remote.bin" >/dev/null
first_byte_ms=$(( ($(date +%s%N) - started) / 1000000 ))
echo "→ first byte of remote.bin through the mount took $first_byte_ms ms"
(( first_byte_ms >= THRESHOLD )) || {
    echo "::error::the mount isn't slower than the ${THRESHOLD} ms threshold, so it can't show a stall"; exit 1; }

# WebKitGTK under Xvfb: no GPU compositor and no sandbox-capable session.
export WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
PASS=0; FAIL=0; INCONCLUSIVE=0

# row <name> <served dir> <want: fast|baseline>
row() {
    local name="$1" served="$2" want="$3" report="$WORK/$RANDOM.json"
    SERVE_PROBE_DIR="$served" SWIFT_PWA_WEB_ROOT="$APP_DIR/web" \
        SWIFT_PWA_INITIAL_ROUTE="/index.html?report=$report" \
        timeout 90 xvfb-run -a "$BINARY" >"$WORK/app.log" 2>&1
    [[ -s "$report" ]] || { echo "  FAIL  $name — the page never reported"; FAIL=$((FAIL+1)); return; }
    python3 - "$name" "$want" "$THRESHOLD" "$report" <<'PY'
import json, sys
name, want, threshold, path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
r = json.load(open(path))
local, remote = r["local"], r["remote"]
line = (f"bridge worst {r['worstBridgeMs']} ms ({r['rounds']} rounds), "
        f"local.bin at {local['ms']} ms, remote.bin at {remote['ms']} ms")
errors = [f"{k}: {v['error']}" for k, v in (("local.bin", local), ("remote.bin", remote)) if "error" in v]
held = max(r["worstBridgeMs"], local["ms"])
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

row "slow mount" "$MOUNT" fast
row "local disk (baseline)" "$BACKING" baseline

echo
echo "$PASS passed, $FAIL failed, $INCONCLUSIVE inconclusive"
[[ $FAIL == 0 && $INCONCLUSIVE == 0 ]]
