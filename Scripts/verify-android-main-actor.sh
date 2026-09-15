#!/usr/bin/env bash
#
# End-to-end check that an *app's own* `@MainActor` code runs on Android (#216).
#
# Android's UI thread belongs to the JVM's Looper and drains nothing, while
# `MainActor` off Apple is backed by libdispatch's main queue - so a bridge
# command that touched a `@MainActor` class simply never returned. Nothing said
# so: Android discards stdout and stderr, so not even a diagnostic could.
#
# The page races each command against a timeout and reports through a
# *nonisolated* command, which reaches logcat via `RuntimeDiagnostics`. That
# reporting command is also the control: if it never arrives, the failure is
# upstream of the main actor and the run says nothing about it.
#
# Usage:
#   Scripts/verify-android-main-actor.sh [-s <adb-serial>] [-k]
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

WORK="${TMPDIR:-/tmp}/swift-pwa-android-main-actor-check"
APP="MainActorCheck"
APP_DIR="$WORK/$APP"

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
PY

# The shape the reporting adopter's lock service had: app state behind the main
# actor, reached from a bridge handler running on the cooperative pool.
cat > "$APP_DIR/Sources/$APP/Probe.swift" <<'SWIFT'
import Dispatch
import Foundation
import SwiftPWA

@MainActor
final class ProbeService {
    private var touches = 0
    func touch() -> Int {
        touches += 1
        return touches
    }
}

struct ProbeArgs: Decodable, Sendable {}
struct ProbeResult: Encodable, Sendable { let value: Int }
struct ProbeReport: Decodable, Sendable { let line: String }
struct ProbeAck: Encodable, Sendable { let ok: Bool }

@MainActor let probeService = ProbeService()

@MainActor
func registerProbes(_ ctx: any AppContext) {
    // The control, and the only way anything gets out: stdout and stderr are
    // discarded on Android, so RuntimeDiagnostics -> logcat is the observer.
    ctx.registry.register("probe.record", typed: { (args: ProbeReport, _) -> ProbeAck in
        RuntimeDiagnostics.emit("MAINACTORPROBE " + args.line)
        return ProbeAck(ok: true)
    })
    ctx.registry.register("probe.nonisolated") { (_: ProbeArgs, _) async throws -> ProbeResult in
        ProbeResult(value: 1)
    }
    ctx.registry.register("probe.actorMethod") { (_: ProbeArgs, _) async throws -> ProbeResult in
        ProbeResult(value: await probeService.touch())
    }
    ctx.registry.register("probe.mainActorRun") { (_: ProbeArgs, _) async throws -> ProbeResult in
        await MainActor.run { ProbeResult(value: 2) }
    }
    ctx.registry.register("probe.dispatchMain") { (_: ProbeArgs, _) async throws -> ProbeResult in
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: ProbeResult(value: 3)) }
        }
    }
}
SWIFT

python3 - "$APP_DIR" <<'PY'
import pathlib, re, sys
app_dir = pathlib.Path(sys.argv[1])
app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
app_swift.write_text(re.sub(r'(?m)^    _ = try ctx\.createWindow\(',
                            '    registerProbes(ctx)\n\n    _ = try ctx.createWindow(',
                            app_swift.read_text()))
PY

cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>main actor check</title>
<body style="font:14px system-ui;padding:24px">Checking the app's own main-actor code...</body>
<script>
(function () {
  var probes = ['probe.nonisolated', 'probe.actorMethod', 'probe.mainActorRun', 'probe.dispatchMain'];
  // A hang is the bug's signature, so the race IS the measurement: a working
  // command answers in single-digit milliseconds.
  function attempt(name) {
    var t0 = Date.now();
    return Promise.race([
      __SWIFT_PWA__.invoke(name, {}).then(
        function () { return name + ' answered in ' + (Date.now() - t0) + 'ms'; },
        function (e) { return name + ' threw ' + e; }),
      new Promise(function (resolve) {
        setTimeout(function () { resolve(name + ' HUNG'); }, 8000);
      })
    ]);
  }
  probes.reduce(function (chain, name) {
    return chain.then(function () {
      return attempt(name).then(function (line) {
        return __SWIFT_PWA__.invoke('probe.record', { line: line });
      });
    });
  }, Promise.resolve()).then(function () {
    document.body.textContent = 'done';
  });
})();
</script>
HTML

# Pin the scaffold to the checkout's own dependency versions: the app depends
# on this checkout by path, so its pins are the right ones.
cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"

# The whole build dir, not just the Android triple: the host resolve runs under
# the default toolchain and the cross-compile under 6.2, and their SwiftPM
# checkout layouts collide ("already exists in file system").
rm -rf "$APP_DIR/.build"

"${ADB[@]}" logcat -c || true

# Resolve up front, under the same toolchain the cross-compile will use, so a
# dependency problem is reported as one rather than surfacing as "could not
# produce a native library for the requested ABI". `swift-pwa deploy` picks the
# toolchain matching the installed Android SDK, so the ambient `swift` is the
# right one whenever that SDK matches the host Swift.
echo "== resolving dependencies =="
if ! (cd "$APP_DIR" && swift package resolve >/dev/null 2>"$WORK/resolve.err"); then
    tail -5 "$WORK/resolve.err" >&2
    exit 1
fi

echo "== cross-compiling, installing and launching on the device =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a)

# Device-side sleep: a foreground sleep here is blocked. Long enough for the
# page to load and for every probe's 8 s timeout to expire in the worst case.
"${ADB[@]}" shell sleep 45 >/dev/null 2>&1 || true

LOG="$WORK/logcat.txt"
"${ADB[@]}" logcat -d -s swift-pwa > "$LOG" 2>/dev/null || true

echo
echo "-- what the app saw --"
grep -o 'MAINACTORPROBE .*' "$LOG" | sed 's/^/   /' || echo "   (nothing)"
echo

failed=0
check() { # command
    local name="$1" line
    line=$(grep -o "MAINACTORPROBE $name .*" "$LOG" | tail -1 || true)
    if [ -z "$line" ]; then
        echo "FAIL  $name never reported - the run says nothing"
        failed=1
    elif echo "$line" | grep -q "HUNG"; then
        echo "FAIL  $name never answered"
        failed=1
    else
        echo "PASS  ${line#MAINACTORPROBE }"
    fi
}

check probe.nonisolated
check probe.actorMethod
check probe.mainActorRun
check probe.dispatchMain

[ "$failed" -eq 0 ] || exit 1
echo
echo "The app's own main-actor code runs on Android."
