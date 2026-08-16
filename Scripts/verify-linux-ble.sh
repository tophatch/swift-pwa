#!/usr/bin/env bash
#
# Verify the Linux `ble.*` backend against a *scaffolded* app on a real box.
#
# Runs on the Linux host itself (copy it over, or use Scripts/remote-linux.sh to
# sync the tree first). It scaffolds a fresh `swift-pwa init` app — not an
# Example, which carries fallbacks the scaffold never emits — registers the
# plugin, and drives the whole surface:
#
#   availability   a powered adapter, or the sentence explaining why not
#   undeclared     no `declare(.bluetooth)` → refused before the radio is
#                  touched, with a diagnostic on stderr naming the fix
#   scan           whatever is advertising nearby, so the D-Bus plumbing is
#                  exercised against real advertisements
#   connect        scan → connect → subscribe → write → read, against
#                  whichever swift-pwa test peripheral is in radio range
#
# Needs one of Scripts/ble-test-peripheral.{swift,py} or the Android fixture
# running within a few metres. Prefer an LE-only one (the Android fixture): a
# Mac or another Linux box is dual-mode, and BlueZ tries classic Bluetooth
# first for those and fails `br-connection-key-missing`.
#
# Usage: verify-linux-ble.sh [--gtk4] [--toolchain <ver>] [--repo <dir>]

set -euo pipefail

GTK4=0
TOOLCHAIN=""
REPO="$HOME/swift-pwa"
WORK="${TMPDIR:-/tmp}/blecheck"

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
APP="$WORK/BleCheck"

# The fixture's service and characteristics, kept in step with
# Scripts/ble-test-peripheral.{swift,py}.
SERVICE="5057ab00-0000-4000-b000-000000000001"
WRITE="5057ab00-0000-4000-b000-000000000002"
NOTIFY="5057ab00-0000-4000-b000-000000000003"
READ="5057ab00-0000-4000-b000-000000000004"

drive() { "$CLI" drive eval --attach "$PORT" --token "$TOKEN" --timeout 60 "$1"; }

# ── scaffold ─────────────────────────────────────────────────────────────
if [[ ! -d "$APP" ]]; then
    rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
    "$CLI" init BleCheck --path BleCheck >/dev/null
    cd "$APP"
    sed -i -e 's|\.package(url: "https://github.com/tophatch/swift-pwa", from: "[^"]*")|.package(path: "'"$REPO"'")|' Package.swift
fi
cd "$APP"
cp -n Sources/BleCheck/App.swift "$WORK/App.swift.orig" 2>/dev/null || true

run_variant() {
    local name="$1" injection="$2"
    echo
    echo "════════ variant: $name ════════"

    python3 - "$WORK/App.swift.orig" Sources/BleCheck/App.swift "$injection" <<'PY'
import sys
src_path, dst_path, injection = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path).read()
marker = "func configure(_ ctx: any AppContext) throws {\n"
assert marker in src, "the scaffold's configure function moved"
open(dst_path, "w").write(src.replace(marker, marker + injection + "\n", 1))
PY

    "${SWIFT[@]}" build --configuration debug >/dev/null 2>&1 || {
        echo "BUILD FAILED"; "${SWIFT[@]}" build --configuration debug 2>&1 | tail -20; return 1
    }

    local log="$WORK/$name.log"
    rm -f "$log"
    SWIFT_PWA_DRIVE=0 SWIFT_PWA_WEB_ROOT="$APP/web" \
        xvfb-run -a "$APP/.build/debug/BleCheck" > "$log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 60); do grep -q "driver listening" "$log" && break; sleep 1; done
    PORT=$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$log" | head -1)
    TOKEN=$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' "$log" | head -1)
    if [[ -z "$PORT" ]]; then echo "app never announced a driver port:"; cat "$log"; kill $pid 2>/dev/null; return 1; fi

    echo "── ble.availability"
    drive "__SWIFT_PWA__.invoke('ble.availability', {})" || true

    echo "── ble.scan (8s, unfiltered)"
    drive "new Promise((resolve) => {
        const seen = new Map();
        const stop = __SWIFT_PWA__.subscribe('ble.scan', {},
            (p) => seen.set(p.id, p),
            (e) => resolve({ error: String((e && e.message) || e) }));
        setTimeout(() => { stop(); resolve({
            count: seen.size,
            sample: [...seen.values()].slice(0, 3),
        }); }, 8000);
    })" || true

    if [[ "$name" == "declared" ]]; then
        echo "── ble.connect → subscribe → write → read  (finds the fixture itself)"
        drive "new Promise((resolve) => {
            const log = [];
            let found = null;
            const stop = __SWIFT_PWA__.subscribe('ble.scan', { services: ['$SERVICE'] },
                (p) => { if (!found) found = p; });
            setTimeout(() => {
                stop();
                if (!found) { resolve({ error: 'no swift-pwa test peripheral in range — start one of Scripts/ble-test-peripheral.*' }); return; }
                log.push({ scanned: found.name, rssi: found.rssi });
                const link = __SWIFT_PWA__.session('ble.connect', { id: found.id, timeoutMs: 25000 }, {
                    onChunk: (e) => {
                        if (e.kind === 'ready') {
                            log.push({ ready: (e.services || []).length + ' services' });
                            link.push({ kind: 'subscribe', characteristic: '$NOTIFY', token: 1 });
                        } else if (e.kind === 'ack' && e.token === 1) {
                            log.push({ note: 'notifications on' });
                            link.push({ kind: 'write', characteristic: '$WRITE', valueBase64: btoa('ping'), withResponse: true, token: 2 });
                        } else if (e.kind === 'ack' && e.token === 2) {
                            log.push({ note: 'write acknowledged' });
                            link.push({ kind: 'read', characteristic: '$READ', token: 3 });
                        } else if (e.kind === 'read') {
                            log.push({ read: atob(e.value) });
                        } else if (e.kind === 'notify') {
                            log.push({ notify: atob(e.value) });
                        } else { log.push(e); }
                    },
                    onError: (err) => { log.push({ streamError: String((err && err.message) || err) }); resolve(log); },
                });
                setTimeout(() => { link.close(); resolve(log); }, 16000);
            }, 6000);
        })" || true
    fi

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true

    echo "── app stderr (permission diagnostics)"
    grep -a "swift-pwa:" "$log" || echo "   (none)"
}

# Undeclared first: the refusal has to arrive before the radio is touched, and
# it's the one failure a page can't tell from "nothing is nearby".
run_variant undeclared '        ctx.use(BLEPlugin(SystemBluetooth()))'
run_variant declared '        ctx.permissions.declare(.bluetooth)
        ctx.use(BLEPlugin(SystemBluetooth()))'
run_variant vetoed '        ctx.permissions.declare(.bluetooth)
        ctx.permissions.setVeto { permission, _ in permission == .bluetooth }
        ctx.use(BLEPlugin(SystemBluetooth()))'

echo
echo "done."
