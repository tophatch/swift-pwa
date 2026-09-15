#!/usr/bin/env bash
#
# Verify that an *app's own* `@MainActor` code runs on the Linux backends (#216).
#
# Off Apple, `MainActor` is backed by libdispatch's main queue, and `gtk_main()`
# drains nothing — so before the fix, a bridge command that touches a
# `@MainActor` class never returned: no error, no timeout, no stderr. That
# failure mode is invisible to a unit suite, so this drives a real scaffolded
# app (not an Example — those carry fallbacks the scaffold never emits) through
# four commands:
#
#   probe.nonisolated   control: must answer in both builds. Without it a
#                       hang anywhere upstream reads as "the fix didn't work".
#   probe.actorMethod   a method on a `@MainActor final class` — the shape the
#                       reporting adopter's LockService had
#   probe.mainActorRun  `await MainActor.run { … }`
#   probe.dispatchMain  `DispatchQueue.main.async` — same single cause, and the
#                       half a main-executor hook could never have fixed
#
# Run it on the Linux host itself (Scripts/remote-linux.sh syncs the tree).
#
# Usage: verify-main-actor.sh [--gtk4] [--toolchain <ver>] [--repo <dir>]

set -euo pipefail

GTK4=0
TOOLCHAIN=""
REPO="$HOME/swift-pwa"
WORK="${TMPDIR:-/tmp}/mainactorcheck"

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
APP="$WORK/MainActorCheck"

# ── scaffold ─────────────────────────────────────────────────────────────
if [[ ! -d "$APP" ]]; then
    rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
    "$CLI" init MainActorCheck --path MainActorCheck >/dev/null
    cd "$APP"
    sed -i -e 's|\.package(url: "https://github.com/tophatch/swift-pwa", from: "[^"]*")|.package(path: "'"$REPO"'")|' Package.swift
fi
cd "$APP"

# ── the probe commands ───────────────────────────────────────────────────
cat > Sources/MainActorCheck/Probe.swift <<'SWIFT'
import Dispatch
import Foundation
import SwiftPWA

/// The shape the reporting adopter's `LockService` had: app state behind the
/// main actor, reached from a bridge handler running on the cooperative pool.
@MainActor
final class ProbeService {
    private var touches = 0
    func touch() -> Int {
        touches += 1
        return touches
    }
}

struct ProbeResult: Encodable, Sendable {
    let value: Int
    let onMainThread: Bool
}

@MainActor let probeService = ProbeService()

@MainActor
func registerProbes(_ ctx: any AppContext) {
    // Control. Answers on the cooperative pool, touching no actor — if this
    // hangs, the driver or the bridge is at fault, not the main actor.
    ctx.registry.register("probe.nonisolated") { (_: ProbeArgs, _) async throws -> ProbeResult in
        ProbeResult(value: 1, onMainThread: Thread.isMainThread)
    }
    ctx.registry.register("probe.actorMethod") { (_: ProbeArgs, _) async throws -> ProbeResult in
        let value = await probeService.touch()
        return ProbeResult(value: value, onMainThread: false)
    }
    ctx.registry.register("probe.mainActorRun") { (_: ProbeArgs, _) async throws -> ProbeResult in
        await MainActor.run { ProbeResult(value: 2, onMainThread: Thread.isMainThread) }
    }
    ctx.registry.register("probe.dispatchMain") { (_: ProbeArgs, _) async throws -> ProbeResult in
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: ProbeResult(value: 3, onMainThread: Thread.isMainThread))
            }
        }
    }
}

struct ProbeArgs: Decodable, Sendable {}
SWIFT

python3 - <<'PY'
path = "Sources/MainActorCheck/App.swift"
src = open(path).read()
marker = "func configure(_ ctx: any AppContext) throws {\n"
assert marker in src, "the scaffold's configure function moved"
if "registerProbes" not in src:
    src = src.replace(marker, marker + "            registerProbes(ctx)\n", 1)
open(path, "w").write(src)
PY

"${SWIFT[@]}" build --configuration debug >/dev/null 2>&1 || {
    echo "BUILD FAILED"; "${SWIFT[@]}" build --configuration debug 2>&1 | tail -30; exit 1
}

# ── launch under Xvfb and drive ──────────────────────────────────────────
LOG="$WORK/app.log"
rm -f "$LOG"
SWIFT_PWA_DRIVE=0 SWIFT_PWA_WEB_ROOT="$APP/web" \
    xvfb-run -a "$APP/.build/debug/MainActorCheck" > "$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do grep -q "driver listening" "$LOG" && break; sleep 1; done
PORT=$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$LOG" | head -1)
TOKEN=$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' "$LOG" | head -1)
if [[ -z "$PORT" ]]; then echo "app never announced a driver port:"; cat "$LOG"; exit 1; fi

FAILED=0
probe() {
    local cmd="$1"
    printf '  %-22s ' "$cmd"
    local out
    # A hang is the bug's signature, so the timeout is the measurement: a
    # working command answers in single-digit milliseconds.
    if out=$("$CLI" drive eval --attach "$PORT" --token "$TOKEN" --timeout 8 "
        (async () => {
          const t0 = performance.now();
          const r = await __SWIFT_PWA__.invoke('$cmd', {});
          return { ms: Math.round(performance.now() - t0), value: r.value };
        })()" 2>&1); then
        echo "$out" | tr -d '\n'; echo
    else
        echo "NO REPLY (hung) — $(echo "$out" | tr -d '\n' | tail -c 120)"
        FAILED=1
    fi
}

echo "backend: $([[ "$GTK4" == 1 ]] && echo gtk4 || echo gtk3)"
probe probe.nonisolated
probe probe.actorMethod
probe probe.mainActorRun
probe probe.dispatchMain

echo
if [[ "$FAILED" == 0 ]]; then echo "PASS — every probe answered."; else echo "FAIL — see above."; fi
exit "$FAILED"
