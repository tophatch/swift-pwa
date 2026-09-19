#!/usr/bin/env bash
#
# What a *default install* can do on Android with no permission granted (#250).
#
# The claim this exists to check, because the whole design rests on it: since
# Android 11 an app can create, list and read **its own** files in shared
# storage by path, with no permission at all. All-files access is only what
# lets it see what *everything else* put there. If that holds, an app's default
# library lives at `/sdcard/Documents/<App>`, which is a real path — so
# `serveDirectory` mounts it and ranges work — and its contents survive
# uninstall.
#
#   1. `app.documentsDir` resolves to that folder and reports
#      `survivesUninstall: true`.
#   2. The app writes a file there and lists it back, with
#      MANAGE_EXTERNAL_STORAGE **denied**.
#   3. CONTROL, and it must fail: a file `adb push` put in the *same folder*,
#      as a different uid, cannot be read by the app. That is what proves no
#      ambient grant is in play. The three questions have different answers and
#      only one of them matters: the **listing hides it** (so an app's scan
#      never sees it — and a folder it may not read lists as *empty* rather
#      than failing, which is the trap), `stat` on the exact path may still
#      find it, and the **read** is what decides whether the app can use it.
#   4. The folder serves: `ctx.serveDirectory` over it answers a `Range`.
#   5. The files survive `adb uninstall`.
#
# Usage:
#   Scripts/verify-android-user-documents.sh [-s <adb-serial>] [-k]
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

WORK="${TMPDIR:-/tmp}/swift-pwa-android-user-docs"
APP="DocsCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.docscheck"
# Where the app's own documents folder must land. `/sdcard/Documents` is
# `Environment.DIRECTORY_DOCUMENTS` under `$EXTERNAL_STORAGE`, and the leaf is
# the app's display name.
DEVICE_DOCS="/sdcard/Documents/$APP"

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

# No `permissions` block: the point is what a default install can do.
probe = '''import Foundation
import SwiftPWA

struct ProbeReport: Codable, Sendable { let line: String }
struct ProbeAck: Encodable, Sendable { let ok: Bool }
struct NoArgs: Decodable, Sendable {}

@MainActor
func registerProbes(_ ctx: any AppContext) {
    ctx.use(FsPlugin(SystemFs()))
    ctx.registry.register("probe.record", typed: { (args: ProbeReport, _) -> ProbeAck in
        RuntimeDiagnostics.emit("DOCSPROBE " + args.line)
        return ProbeAck(ok: true)
    })
    // The claim in one line: the app's own user-visible folder is a real path,
    // so it mounts like any other and streams with ranges. A SAF tree can do
    // neither today (#249).
    ctx.registry.register("probe.serveDocuments", typed: { (_: NoArgs, _) async -> ProbeReport in
        let docs = await MainThread.run { () -> String in
            let url = ctx.documentsDirectory()
            ctx.serveDirectory(url, at: "/library")
            return url.path
        }
        return ProbeReport(line: docs)
    })
}
'''
(app_dir / "Sources" / app_dir.name / "Probe.swift").write_text(probe)

app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text = app_swift.read_text()
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    registerProbes(ctx)\n\n    _ = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app_swift.write_text(text)
PY

cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>user documents check</title>
<body style="font:14px system-ui;padding:24px">checking…</body>
<script>
(function () {
  function report(line) { return __SWIFT_PWA__.invoke('probe.record', { line: line }); }
  function step(name, fn) {
    return fn().then(
      function (detail) { return report(name + ' ' + detail); },
      function (e) { return report(name + ' THREW ' + e); });
  }

  var docs = null;

  step('where', function () {
    return __SWIFT_PWA__.invoke('app.documentsDir').then(function (d) {
      docs = d.path;
      return 'path=' + d.path + ' survives=' + d.survivesUninstall;
    });
  }).then(function () {
    // Writing into shared storage with nothing granted. This is the claim.
    return step('write', function () {
      return __SWIFT_PWA__.invoke('fs.writeText', {
        path: docs + '/own-book.txt', contents: 'a book the app itself wrote'
      }).then(function () { return 'ok'; });
    });
  }).then(function () {
    return step('list', function () {
      return __SWIFT_PWA__.invoke('fs.readDir', { path: docs }).then(function (r) {
        var entries = r.entries || r;
        return 'count=' + entries.length +
               ' names=' + entries.map(function (e) { return e.name; }).sort().join(',');
      });
    });
  }).then(function () {
    // THE CONTROL. `adb push` put a file in this same folder, as a different
    // uid. A default install must not be able to *use* it — and the three
    // questions have different answers, which is the part that misleads:
    // the listing hides it, `stat` may still find it by exact path, and only
    // the read says whether the app can do anything with it.
    return step('pushed', function () {
      var path = docs + '/pushed-by-adb.txt';
      return __SWIFT_PWA__.invoke('fs.exists', { path: path }).then(function (r) {
        var seen = (r.exists === undefined ? r : r.exists);
        return __SWIFT_PWA__.invoke('fs.readText', { path: path }).then(
          function (t) { return 'stat=' + seen + ' read=ok bytes=' + t.contents.length; },
          function () { return 'stat=' + seen + ' read=denied'; });
      });
    });
  }).then(function () {
    return step('serve', function () {
      return __SWIFT_PWA__.invoke('probe.serveDocuments', {}).then(function () {
        return fetch('/library/own-book.txt', { headers: { Range: 'bytes=2-5' } })
          .then(function (res) {
            return res.text().then(function (t) {
              return 'status=' + res.status + ' header=' + res.headers.get('Content-Length') +
                     ' len=' + t.length + ' body=' + JSON.stringify(t);
            });
          });
      });
    });
  }).then(function () {
    document.body.textContent = 'done';
    return report('finished');
  });
})();
</script>
HTML

cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"
rm -rf "$APP_DIR/.build"

echo "== resolving dependencies =="
if ! (cd "$APP_DIR" && swift package resolve >/dev/null 2>"$WORK/resolve.err"); then
    tail -5 "$WORK/resolve.err" >&2
    exit 1
fi

echo "== cross-compiling, installing and launching on the device =="
# A clean slate: uninstall first, so "the folder survives uninstall" is being
# measured rather than inherited from a previous run.
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" shell rm -rf "$DEVICE_DOCS" >/dev/null 2>&1 || true
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a)

echo "== staging a file the app did NOT write (the control) =="
"${ADB[@]}" shell mkdir -p "$DEVICE_DOCS" >/dev/null 2>&1 || true
printf 'adb put this here' > "$WORK/pushed-by-adb.txt"
"${ADB[@]}" push "$WORK/pushed-by-adb.txt" "$DEVICE_DOCS/pushed-by-adb.txt" >/dev/null

# Denied explicitly: a previous run on this device may have allowed it, and an
# inherited grant would make every check below meaningless.
"${ADB[@]}" shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE deny >/dev/null 2>&1 || true

"${ADB[@]}" logcat -c || true
"${ADB[@]}" shell am force-stop "$PKG" || true
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
"${ADB[@]}" shell sleep 20 >/dev/null 2>&1 || true

LOG="$WORK/logcat.txt"
"${ADB[@]}" logcat -d -s swift-pwa > "$LOG" 2>/dev/null || true

echo
echo "-- what the app saw --"
grep -o 'DOCSPROBE .*' "$LOG" | sed 's/^/   /' || echo "   (nothing)"
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

expect "the app reported at all (control)" 'DOCSPROBE '
expect "documentsDir is the user-visible folder, and says it outlives the app" \
    "DOCSPROBE where path=$DEVICE_DOCS survives=true"
expect "the app writes into shared storage with nothing granted" 'DOCSPROBE write ok'
expect "…and lists the file it wrote" 'DOCSPROBE list count=1 names=own-book.txt'
# The control, in the form that decides whether an app can *use* the file. The
# listing above already showed the folder as holding one entry, so the scan an
# app actually performs never sees it either.
expect "a file the app didn't write cannot be read by it (control)" 'DOCSPROBE pushed stat=.* read=denied'
# `bytes=2-5` over "a book the app itself wrote" is "book".
expect "the folder serves, and answers a Range" \
    'DOCSPROBE serve status=200 header=4 len=4 body="book"'
expect "the page ran to the end" 'DOCSPROBE finished'

echo
echo "== uninstalling, to see what the user keeps =="
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
# `adb shell` has shell-level access, so it sees every file regardless of what
# the app could see — which is the point: the user's file is still on the
# device even though the app that wrote it is gone.
if "${ADB[@]}" shell ls "$DEVICE_DOCS/own-book.txt" >/dev/null 2>&1; then
    echo "PASS  the app's file survives uninstall"
else
    echo "FAIL  the app's file survives uninstall"
    failed=1
fi
if "${ADB[@]}" shell ls "/sdcard/Android/data/$PKG" >/dev/null 2>&1; then
    echo "FAIL  the private app-data dir survives uninstall (it should not)"
    failed=1
else
    echo "PASS  the private app-data dir is gone, as expected"
fi

"${ADB[@]}" shell rm -rf "$DEVICE_DOCS" >/dev/null 2>&1 || true

[ "$failed" -eq 0 ] || exit 1
echo
echo "A default install owns a user-visible folder on Android, with no permission."
