#!/usr/bin/env bash
#
# Verify the Linux permission handler against a *scaffolded* app on a real box.
#
# Runs on the Linux host itself (copy it over, or use Scripts/remote-linux.sh to
# sync the tree first). It scaffolds a fresh `swift-pwa init` app — not an
# Example, which carries fallbacks the scaffold never emits — and drives three
# variants through the same probes:
#
#   undeclared  nothing declared        → every request refused, with a
#                                         diagnostic on stderr naming the fix
#   declared    camera/mic/geolocation  → requests reach the platform
#   vetoed      declared, veto refuses  → refused again, without asking
#
# The probes are promises handed straight to `drive eval`, which awaits them.
#
# Usage: verify-linux-permissions.sh [--gtk4] [--toolchain <ver>] [--repo <dir>]
#
# Capture needs real hardware *and* a reachable audio server: over SSH, export
# XDG_RUNTIME_DIR=/run/user/$(id -u) or WebKit reports zero devices and the
# result tells you nothing about permissions.

set -euo pipefail

GTK4=0
TOOLCHAIN=""
REPO="$HOME/swift-pwa"
WORK="${TMPDIR:-/tmp}/permcheck"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gtk4) GTK4=1; shift ;;
        --toolchain) TOOLCHAIN="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

SWIFT=(swift)
if [[ -n "$TOOLCHAIN" ]]; then
    SWIFT=("$HOME/.local/share/swiftly/bin/swiftly" run "+$TOOLCHAIN" swift)
fi
# Presence selects the GTK4 backend, so `=0` is not "off" — unset it instead.
if [[ "$GTK4" == 1 ]]; then export SWIFT_PWA_GTK4=1; else unset SWIFT_PWA_GTK4; fi
CLI="$REPO/.build/debug/swift-pwa"
APP="$WORK/PermCheck"

drive() { "$CLI" drive eval --attach "$PORT" --token "$TOKEN" --timeout 25 "$1"; }

# ── scaffold ─────────────────────────────────────────────────────────────
if [[ ! -d "$APP" ]]; then
    rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
    "$CLI" init PermCheck --path PermCheck >/dev/null
    cd "$APP"
    sed -i -e 's|\.package(url: "https://github.com/tophatch/swift-pwa", from: "[^"]*")|.package(path: "'"$REPO"'")|' Package.swift
fi
cd "$APP"
cp -n Sources/PermCheck/App.swift "$WORK/App.swift.orig" 2>/dev/null || true

# ── one variant: patch App.swift, build, launch under Xvfb, probe ────────
run_variant() {
    local name="$1" injection="$2"
    echo
    echo "════════ variant: $name ════════"

    python3 - "$WORK/App.swift.orig" Sources/PermCheck/App.swift "$injection" <<'PY'
import sys
src_path, dst_path, injection = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path).read()
# Insert right after the configure closure opens, before any window exists.
marker = "func configure(_ ctx: any AppContext) throws {\n"
assert marker in src, "the scaffold's configure function moved"
if injection:
    src = src.replace(marker, marker + injection + "\n", 1)
open(dst_path, "w").write(src)
PY

    "${SWIFT[@]}" build --configuration debug >/dev/null 2>&1 || {
        echo "BUILD FAILED"; "${SWIFT[@]}" build --configuration debug 2>&1 | tail -20; return 1
    }

    local log="$WORK/$name.log"
    rm -f "$log"
    SWIFT_PWA_DRIVE=0 SWIFT_PWA_WEB_ROOT="$APP/web" \
        xvfb-run -a "$APP/.build/debug/PermCheck" > "$log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 60); do grep -q "driver listening" "$log" && break; sleep 1; done
    PORT=$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$log" | head -1)
    TOKEN=$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' "$log" | head -1)
    if [[ -z "$PORT" ]]; then echo "app never announced a driver port:"; cat "$log"; kill $pid 2>/dev/null; return 1; fi

    echo "── geolocation"
    local t0 t1
    t0=$(date +%s%N)
    drive 'new Promise(r => navigator.geolocation.getCurrentPosition(
        p => r({ok: true, accuracy: p.coords.accuracy}),
        e => r({ok: false, code: e.code, message: e.message}),
        {timeout: 12000}))' || true
    t1=$(date +%s%N)
    # Latency separates a refusal from a question: a real prompt or a real fix
    # takes seconds, an instant refusal is the runtime saying no by itself.
    echo "   $(( (t1 - t0) / 1000000 )) ms"

    echo "── getUserMedia({audio: true})"
    drive 'navigator.mediaDevices.getUserMedia({audio: true})
        .then(s => ({ok: true, tracks: s.getAudioTracks().length}))
        .catch(e => ({ok: false, name: e.name, message: e.message}))' || true

    echo "── enumerateDevices() labels"
    drive 'navigator.mediaDevices.enumerateDevices()
        .then(ds => ds.map(d => d.kind + ":" + (d.label || "(no label)")))' || true

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true

    echo "── app stderr (permission diagnostics)"
    grep -a "swift-pwa:" "$log" || echo "   (none)"
}

run_variant undeclared ""
run_variant declared '        ctx.permissions.declare(.camera, .microphone, .geolocation)'
# Vetoing *one* declared permission, so the run shows granularity rather than a
# blanket off-switch: geolocation must flip back to a refusal while the
# microphone keeps working.
run_variant vetoed '        ctx.permissions.declare(.camera, .microphone, .geolocation)
        ctx.permissions.setVeto { permission, _ in permission == .geolocation }'

echo
echo "done."
