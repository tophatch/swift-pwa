#!/usr/bin/env bash
#
# End-to-end check, on a real device, of how an Android app reaches files —
# the Android gaps in #213 / #214, and the three the same adopter reported
# against 0.11.1 (#242, #243, #244):
#
#   1. `ctx.serveDirectory(_:at:)` serves a directory the app mounts at
#      *runtime*, from a root *outside app storage* — and answers Range
#      requests, so a large file streams rather than downloading whole.
#   2. `android.permissions` in pwa.json reaches the installed APK.
#   3. The Activity's foreground state reaches Swift as the window's
#      `didFocus` / `didBlur`.
#   4. #242: the origin root serves `web.entry`, and a missing path 404s with
#      a body rather than `ERR_INVALID_RESPONSE`.
#   5. #244: a ranged response's `Content-Length` and its body agree.
#   6. #243: All-files access can be read *and asked for* — including the trip
#      to Settings and back — and `deviceName` isn't `localhost`.
#
# The first three were unreachable before: the `WebViewAssetLoader` is built in
# `Activity.onCreate` before any Swift runs, so only build-time `build.serve`
# mounts rooted in app storage existed; `permissions.web` maps web capabilities
# only, so a permission with no web name couldn't be declared; and nothing
# surfaced resume/pause at all.
#
# **Two launches, deliberately.** The first runs with All-files access NOT
# granted, which is the only way to see `denied`, the Settings hand-off, and
# what happens when the user comes back having granted nothing. The second runs
# with it granted by `appops`, which is what the hand-off would have done, and
# is where the serving checks are read from.
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
# #214: a permission the web-permission mapping has no name for, passed
# through verbatim. VIBRATE rather than MANAGE_EXTERNAL_STORAGE so this route
# stays distinguishable from the named one below.
pwa.setdefault("android", {})["permissions"] = ["android.permission.VIBRATE"]
# #243: the runtime knows this one by name, so declaring it emits the manifest
# entries *and* makes `ctx.permissions.request(.allFiles)` possible.
pwa["permissions"] = {"device": ["allFiles"]}
(app_dir / "pwa.json").write_text(json.dumps(pwa, indent=2) + "\n")

probe = f'''import Foundation
import SwiftPWA

struct ProbeReport: Codable, Sendable {{ let line: String }}
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

    // #243. Declaring is the ceiling; `status` / `request` are the runtime
    // half that did not exist. `camera` is deliberately NOT declared, so the
    // page has a control that must read `unavailable`.
    ctx.permissions.declare(.allFiles)
    // Captured out here, the way a real plugin does: the policy is app-wide
    // and `AppContext` is `@MainActor`, while a command handler isn't.
    let permissions = ctx.permissions
    ctx.registry.register("probe.permissionStatus", typed: {{ (args: ProbeReport, _) async -> ProbeReport in
        let permission = DevicePermission(rawValue: args.line) ?? .allFiles
        return await ProbeReport(line: permissions.status(permission).rawValue)
    }})
    ctx.registry.register("probe.permissionRequest", typed: {{ (_: NoArgs, _) async -> ProbeReport in
        // May take as long as the user does: this is a Settings screen, not a
        // dialog. The script presses BACK for them.
        await ProbeReport(line: permissions.request(.allFiles).rawValue)
    }})
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

  var chain = Promise.resolve();
  function next(name, fn) {
    chain = chain.then(function () { return step(name, fn); });
  }

  next('whole', function () {
    return fetch('/loc/book.bin').then(function (r) {
      return r.arrayBuffer().then(function (b) {
        return 'status=' + r.status + ' bytes=' + b.byteLength;
      });
    });
  });

  // #244. The WebView rejects a 206 from an intercepted response outright and
  // ranges the stream itself over a 200: it skips to the start offset, and
  // reports Content-Length as the length *asked for*. It used to then read to
  // the end of the file, so the header and the body disagreed. Both numbers
  // are reported here, because the bug is the gap between them.
  next('range', function () {
    return fetch('/loc/book.bin', { headers: { Range: 'bytes=10-19' } }).then(function (r) {
      return r.text().then(function (t) {
        return 'status=' + r.status + ' header=' + r.headers.get('Content-Length') +
               ' len=' + t.length + ' from=' + JSON.stringify(t.slice(0, 10));
      });
    });
  });

  // A range with no explicit end already agreed with itself; it must stay
  // whole-tail rather than being capped to nothing.
  next('openrange', function () {
    return fetch('/loc/book.bin', { headers: { Range: 'bytes=65526-' } }).then(function (r) {
      return r.text().then(function (t) { return 'status=' + r.status + ' len=' + t.length; });
    });
  });

  next('missing', function () {
    return fetch('/loc/not-here.bin').then(function (r) {
      return r.text().then(function (t) {
        return 'status=' + r.status + ' body=' + t.length;
      });
    });
  });

  // The bundle must still be served by the asset loader - a mount that
  // shadowed it would break the app instead of extending it.
  next('bundle', function () {
    return fetch('/index.html').then(function (r) { return 'status=' + r.status; });
  });

  // #242. `location.replace('/')` is the ordinary "go back to the top", and it
  // dead-ended here and nowhere else.
  next('root', function () {
    return fetch('/').then(function (r) {
      return r.text().then(function (t) {
        return 'status=' + r.status + ' title=' + /<title>([^<]*)<\/title>/.test(t);
      });
    });
  });

  // #242's second half: a 404 with a body, so the failure says what it is
  // instead of reading as ERR_INVALID_RESPONSE.
  next('bundle404', function () {
    return fetch('/nope.html').then(function (r) {
      return r.text().then(function (t) {
        return 'status=' + r.status + ' body=' + t.length +
               ' names=' + (t.indexOf('/nope.html') >= 0);
      });
    });
  });

  // #243. `deviceName` exists because ProcessInfo.hostName is `localhost` on
  // every Android device.
  next('device', function () {
    return __SWIFT_PWA__.invoke('__platform.info').then(function (info) {
      return 'name=' + info.deviceName;
    });
  });

  next('permstatus', function () {
    return __SWIFT_PWA__.invoke('probe.permissionStatus', { line: 'allFiles' })
      .then(function (r) { return 'state=' + r.line; });
  });

  // The control: never declared, so it can never be granted by asking.
  next('permundeclared', function () {
    return __SWIFT_PWA__.invoke('probe.permissionStatus', { line: 'camera' })
      .then(function (r) { return 'state=' + r.line; });
  });

  chain.then(function () {
    return __SWIFT_PWA__.invoke('probe.unmount', {});
  }).then(function () {
    return step('unmounted', function () {
      return fetch('/loc/book.bin').then(function (r) { return 'status=' + r.status; });
    });
  }).then(function () {
    document.body.textContent = 'done';
    // Last, and only once everything else has been reported: this one opens a
    // Settings screen and doesn't come back until the user does.
    return step('permrequest', function () {
      return __SWIFT_PWA__.invoke('probe.permissionRequest', {})
        .then(function (r) { return 'state=' + r.line; });
    });
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

LOG1="$WORK/logcat-ungranted.txt"
LOG2="$WORK/logcat-granted.txt"

# `deploy` launches the app itself, and that run reaches the Settings hand-off
# too — so the screen is already up, on top of the app's own task. Clear it
# before starting, or the launch below resumes the task with Settings still in
# front and the page never re-runs.
"${ADB[@]}" shell input keyevent KEYCODE_BACK
"${ADB[@]}" shell am force-stop "$PKG" || true

# ---------------------------------------------------------------------------
# Launch 1: All-files access NOT granted. The only run that can see `denied`,
# the Settings hand-off, and what the app is told when the user comes back
# having granted nothing.
# ---------------------------------------------------------------------------
echo "== launch 1: without All-files access =="
"${ADB[@]}" shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE deny >/dev/null 2>&1 || true
"${ADB[@]}" logcat -c || true
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
"${ADB[@]}" shell sleep 22 >/dev/null 2>&1 || true

# The page's last step asks for the permission, which opens a Settings screen.
# Catch it in the foreground — that is the hand-off actually happening, as
# opposed to an intent that resolved to nothing — then press BACK for the user.
#
# Through a file, not a pipe: `dumpsys | grep -m1` under `set -o pipefail`
# reports the pipeline as failed (grep exits first, dumpsys takes SIGPIPE) and
# the check reads as "nothing in the foreground" while Settings is plainly on
# the screen.
echo "== the Settings hand-off =="
"${ADB[@]}" shell dumpsys activity activities > "$WORK/activities.txt" 2>/dev/null || true
FOREGROUND="$(grep -m1 'topResumedActivity' "$WORK/activities.txt" || true)"
echo "   foreground: ${FOREGROUND:-(nothing)}"
# No force-stop between the request and this BACK: the pending request lives in
# the app's process, and killing it loses both the answer and the way back.
"${ADB[@]}" shell input keyevent KEYCODE_BACK
"${ADB[@]}" shell sleep 8 >/dev/null 2>&1 || true
"${ADB[@]}" logcat -d -s swift-pwa > "$LOG1" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Launch 2: granted. `appops set … allow` is exactly what the Settings screen
# the app just opened would have done.
# ---------------------------------------------------------------------------
echo "== launch 2: with All-files access granted =="
"${ADB[@]}" logcat -c || true
"${ADB[@]}" shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE allow || true
"${ADB[@]}" shell am force-stop "$PKG" || true
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
"${ADB[@]}" shell sleep 20 >/dev/null 2>&1 || true

echo "== backgrounding and resuming, for the lifecycle events =="
"${ADB[@]}" shell input keyevent KEYCODE_HOME
"${ADB[@]}" shell sleep 3 >/dev/null 2>&1 || true
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
"${ADB[@]}" shell sleep 5 >/dev/null 2>&1 || true
"${ADB[@]}" logcat -d -s swift-pwa > "$LOG2" 2>/dev/null || true
# An uncaught Java exception on Chromium's thread takes the whole app down, and
# every check below then fails with no hint as to why. Say so before they do.
"${ADB[@]}" logcat -d -b crash -v brief > "$WORK/crash.txt" 2>/dev/null || true
if grep -q "$PKG" "$WORK/crash.txt"; then
    echo
    echo "!! the app crashed during this run:"
    grep -A 12 "FATAL EXCEPTION" "$WORK/crash.txt" | tail -20 | sed 's/^/   /'
fi

echo
echo "-- launch 1, without the permission --"
grep -o 'MOUNTPROBE .*' "$LOG1" | sed 's/^/   /' || echo "   (nothing)"
echo "-- launch 2, with it --"
grep -o 'MOUNTPROBE .*' "$LOG2" | sed 's/^/   /' || echo "   (nothing)"
echo

failed=0
expect() { # label pattern [log]
    local label="$1" pattern="$2" log="${3:-$LOG2}"
    if grep -q "$pattern" "$log"; then
        echo "PASS  $label"
    else
        echo "FAIL  $label"
        failed=1
    fi
}

# The control. Nothing below says anything if the app never reported at all.
expect "the app reached the page and reported (control)" 'MOUNTPROBE '

# #213: the mount is served at all, whole and by range.
expect "a runtime mount outside app storage serves a whole file" \
    'MOUNTPROBE whole status=200 bytes=65536'
# #244: not a 206 — the WebView refuses one from an intercepted response, and
# does the skip itself. What changed is that the body now STOPS at the end of
# the range, so `header` and `len` agree. Before, header=10 arrived with
# len=65526.
expect "a Range request is served from the requested offset" \
    'MOUNTPROBE range status=200 header=10 len=10 from="RANGE-OKAY"'
expect "a range with no explicit end still runs to EOF" \
    'MOUNTPROBE openrange status=200 len=10'
expect "a missing file under a mount 404s" 'MOUNTPROBE missing status=404'
expect "the app's own bundle is untouched" 'MOUNTPROBE bundle status=200'
expect "unserveDirectory takes effect" 'MOUNTPROBE unmounted status=404'

# #242: the origin root, and a 404 that says what it is.
expect "the origin root serves the entry document" 'MOUNTPROBE root status=200 title=true'
expect "a missing bundle path 404s with a body naming it" \
    'MOUNTPROBE bundle404 status=404 body=[1-9][0-9]* names=true'

# #243: the runtime tier, and the device's own name.
expect "All-files access reads granted once granted" 'MOUNTPROBE permstatus state=granted'
expect "All-files access reads denied before it is" \
    'MOUNTPROBE permstatus state=denied' "$LOG1"
expect "an undeclared permission is unavailable, not denied" \
    'MOUNTPROBE permundeclared state=unavailable'
# The whole round trip: the intent resolved, Settings came up, and the
# launcher's callback resumed the Swift continuation when the user came back.
expect "requesting it hands off to Settings and resolves on the way back" \
    'MOUNTPROBE permrequest state=denied' "$LOG1"
if echo "${FOREGROUND:-}" | grep -qi "settings"; then
    echo "PASS  the Settings screen was actually in the foreground"
else
    echo "FAIL  the Settings screen was actually in the foreground"
    echo "      foreground was: ${FOREGROUND:-(nothing)}"
    failed=1
fi
MODEL="$("${ADB[@]}" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n')"
expect "deviceName is the device, not localhost" "MOUNTPROBE device name=$MODEL"

# #214: both declaration routes reach the *installed* package — the verbatim
# `android.permissions` list and the named `permissions.device` entry.
echo
DUMP="$WORK/package-dump.txt"
"${ADB[@]}" shell dumpsys package "$PKG" > "$DUMP" 2>/dev/null || true
for perm in android.permission.VIBRATE android.permission.MANAGE_EXTERNAL_STORAGE; do
    if grep -q "$perm" "$DUMP"; then
        echo "PASS  $perm reached the installed APK"
    else
        echo "FAIL  $perm did not reach the installed APK"
        failed=1
    fi
done

[ "$failed" -eq 0 ] || exit 1
echo
echo "Serving, ranges, the permission tier and the Activity lifecycle all work on Android."
