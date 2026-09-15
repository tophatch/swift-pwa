#!/usr/bin/env bash
#
# End-to-end check, on a real device, of the two Android gaps in #213 and #214:
#
#   1. `ctx.serveDirectory(_:at:)` serves a directory the app mounts at
#      *runtime*, from a root *outside app storage* — and answers Range
#      requests, so a large file streams rather than downloading whole.
#   2. `android.permissions` in pwa.json reaches the installed APK.
#   3. The Activity's foreground state reaches Swift as the window's
#      `didFocus` / `didBlur`.
#
# All three were unreachable before: the `WebViewAssetLoader` is built in
# `Activity.onCreate` before any Swift runs, so only build-time `build.serve`
# mounts rooted in app storage existed; `permissions.web` maps web capabilities
# only, so a permission with no web name couldn't be declared; and nothing
# surfaced resume/pause at all.
#
# The app reports through `RuntimeDiagnostics` -> logcat, because Android
# discards stdout and stderr. The first probe is a control: if it never
# arrives, the run says nothing about the rest.
#
# Usage:
#   Scripts/verify-android-served-mounts.sh [-s <adb-serial>] [-k]
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

WORK="${TMPDIR:-/tmp}/swift-pwa-android-mount-check"
APP="MountCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.mountcheck"
# Outside app storage on purpose: `InternalStoragePathHandler`, which is all
# `build.serve` can use, refuses a root that isn't inside the app's own
# directories. A user's library folder is exactly this shape.
DEVICE_ROOT="/sdcard/Download/swift-pwa-mount-check"

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

python3 - "$APP_DIR" "$REPO" "$DEVICE_ROOT" <<'PY'
import json, pathlib, re, sys
app_dir, repo, device_root = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]

manifest = app_dir / "Package.swift"
text = manifest.read_text()
text = re.sub(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
              f'.package(path: "{repo}")', text)
text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
manifest.write_text(text)

# #214 part 1: a permission the web-permission mapping has no name for.
pwa = json.loads((app_dir / "pwa.json").read_text())
pwa.setdefault("android", {})["permissions"] = ["android.permission.MANAGE_EXTERNAL_STORAGE"]
(app_dir / "pwa.json").write_text(json.dumps(pwa, indent=2) + "\n")

probe = f'''import Foundation
import SwiftPWA

struct ProbeReport: Decodable, Sendable {{ let line: String }}
struct ProbeAck: Encodable, Sendable {{ let ok: Bool }}
struct NoArgs: Decodable, Sendable {{}}

/// The library root. Outside app storage, and named at runtime - neither of
/// which `build.serve` can express.
let libraryRoot = URL(fileURLWithPath: "{device_root}")

@MainActor
func registerProbes(_ ctx: any AppContext) {{
    // The control, and the only way anything gets out.
    ctx.registry.register("probe.record", typed: {{ (args: ProbeReport, _) -> ProbeAck in
        RuntimeDiagnostics.emit("MOUNTPROBE " + args.line)
        return ProbeAck(ok: true)
    }})
    // Through the main actor, because that is where an app actually calls
    // this from: a `locations.remove` command handler runs on the cooperative
    // pool, and `AppContext` is `@MainActor`. Before #216 that hop never
    // completed on Android.
    ctx.registry.register("probe.unmount") {{ (_: NoArgs, _) async throws -> ProbeAck in
        await MainThread.run {{ ctx.unserveDirectory(at: "/loc") }}
        return ProbeAck(ok: true)
    }}
    // The call that did nothing at all before.
    ctx.serveDirectory(libraryRoot, at: "/loc")
}}

/// #214 part 2: the window's foreground state, which an app hangs a re-lock or
/// a folder re-walk off.
@MainActor
func watchLifecycle(_ window: any Window) {{
    let events = window.eventStream()
    Task.detached {{
        for await event in events {{
            switch event {{
            case .didFocus: RuntimeDiagnostics.emit("MOUNTPROBE lifecycle didFocus")
            case .didBlur: RuntimeDiagnostics.emit("MOUNTPROBE lifecycle didBlur")
            default: break
            }}
        }}
    }}
}}
'''
(app_dir / "Sources" / app_dir.name / "Probe.swift").write_text(probe)

app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text = app_swift.read_text()
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    registerProbes(ctx)\n\n    let probeWindow = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
# Attach the watcher at the end of `configure`, once the window exists.
text = text.rstrip()
closing = text.rfind("\n}")
app_swift.write_text(text[:closing] + "\n    watchLifecycle(probeWindow)" + text[closing:] + "\n")
PY

cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>served mount check</title>
<body style="font:14px system-ui;padding:24px">Checking runtime mounts...</body>
<script>
(function () {
  function report(line) { return __SWIFT_PWA__.invoke('probe.record', { line: line }); }

  function step(name, fn) {
    return fn().then(
      function (detail) { return report(name + ' ' + detail); },
      function (e) { return report(name + ' THREW ' + e); });
  }

  step('whole', function () {
    return fetch('/loc/book.bin').then(function (r) {
      return r.arrayBuffer().then(function (b) {
        return 'status=' + r.status + ' bytes=' + b.byteLength;
      });
    });
  }).then(function () {
    // The WebView rejects a 206 from an intercepted response outright, and
    // ranges the stream itself over a 200 instead: it skips to the start
    // offset and runs to the end of the file, reporting 200 and no
    // Content-Range. So what a seek actually gets is "from byte 10 onward",
    // which is what makes a <video> seek work.
    return step('range', function () {
      return fetch('/loc/book.bin', { headers: { Range: 'bytes=10-19' } }).then(function (r) {
        return r.text().then(function (t) {
          return 'status=' + r.status + ' len=' + t.length +
                 ' from=' + JSON.stringify(t.slice(0, 10));
        });
      });
    });
  }).then(function () {
    return step('missing', function () {
      return fetch('/loc/not-here.bin').then(function (r) { return 'status=' + r.status; });
    });
  }).then(function () {
    // The bundle must still be served by the asset loader - a mount that
    // shadowed it would break the app instead of extending it.
    return step('bundle', function () {
      return fetch('/index.html').then(function (r) { return 'status=' + r.status; });
    });
  }).then(function () {
    return __SWIFT_PWA__.invoke('probe.unmount', {});
  }).then(function () {
    return step('unmounted', function () {
      return fetch('/loc/book.bin').then(function (r) { return 'status=' + r.status; });
    });
  }).then(function () {
    document.body.textContent = 'done';
  });
})();
</script>
HTML

cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"
rm -rf "$APP_DIR/.build"

echo "== staging the library folder on the device =="
"${ADB[@]}" shell rm -rf "$DEVICE_ROOT" >/dev/null 2>&1 || true
"${ADB[@]}" shell mkdir -p "$DEVICE_ROOT"
# 64 KiB, so a range request is answering out of a file no one would want to
# fetch whole. Bytes 10-19 are a known marker the page checks.
python3 -c "
import sys
data = bytearray(b'x' * 65536)
data[10:20] = b'RANGE-OKAY'
sys.stdout.buffer.write(bytes(data))
" > "$WORK/book.bin"
"${ADB[@]}" push "$WORK/book.bin" "$DEVICE_ROOT/book.bin" >/dev/null

"${ADB[@]}" logcat -c || true

echo "== resolving dependencies =="
if ! (cd "$APP_DIR" && swift package resolve >/dev/null 2>"$WORK/resolve.err"); then
    tail -5 "$WORK/resolve.err" >&2
    exit 1
fi

echo "== cross-compiling, installing and launching on the device =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a)

# All-files access is a *special* permission: declaring it makes the request
# possible, and this is the request. Granting it by hand here is the same thing
# the app would send the user to Settings to do.
echo "== granting All-files access =="
"${ADB[@]}" shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE allow || true
"${ADB[@]}" shell am force-stop "$PKG" || true
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
"${ADB[@]}" shell sleep 20 >/dev/null 2>&1 || true

echo "== backgrounding and resuming, for the lifecycle events =="
"${ADB[@]}" shell input keyevent KEYCODE_HOME
"${ADB[@]}" shell sleep 3 >/dev/null 2>&1 || true
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
"${ADB[@]}" shell sleep 5 >/dev/null 2>&1 || true

LOG="$WORK/logcat.txt"
"${ADB[@]}" logcat -d -s swift-pwa > "$LOG" 2>/dev/null || true

echo
echo "-- what the app saw --"
grep -o 'MOUNTPROBE .*' "$LOG" | sed 's/^/   /' || echo "   (nothing)"
echo

failed=0
expect() { # label pattern
    local label="$1" pattern="$2"
    if grep -q "$pattern" "$LOG"; then
        echo "PASS  $label"
    else
        echo "FAIL  $label"
        failed=1
    fi
}

# #213: the mount is served at all, whole and by range.
expect "a runtime mount outside app storage serves a whole file" \
    'MOUNTPROBE whole status=200 bytes=65536'
# Not a 206: the WebView refuses one from an intercepted response. It does the
# skip itself, which is what a media seek needs; see the generated Kotlin.
expect "a Range request is served from the requested offset" \
    'MOUNTPROBE range status=200 len=65526 from="RANGE-OKAY"'
expect "a missing file under a mount 404s" 'MOUNTPROBE missing status=404'
expect "the app's own bundle is untouched" 'MOUNTPROBE bundle status=200'
expect "unserveDirectory takes effect" 'MOUNTPROBE unmounted status=404'

# #214 part 2: lifecycle.
expect "leaving the foreground reaches Swift as didBlur" 'MOUNTPROBE lifecycle didBlur'
expect "returning reaches Swift as didFocus" 'MOUNTPROBE lifecycle didFocus'

# #214 part 1: the declared permission is in the *installed* package.
echo
if "${ADB[@]}" shell dumpsys package "$PKG" 2>/dev/null \
    | grep -q "android.permission.MANAGE_EXTERNAL_STORAGE"; then
    echo "PASS  android.permissions reached the installed APK"
else
    echo "FAIL  android.permissions did not reach the installed APK"
    failed=1
fi

[ "$failed" -eq 0 ] || exit 1
echo
echo "Runtime mounts, range requests and the Activity lifecycle all work on Android."
