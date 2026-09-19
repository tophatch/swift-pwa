#!/usr/bin/env bash
#
# End-to-end check, on a real device, that a folder the user picks through the
# Storage Access Framework can actually back a library (#246):
#
#   1. `dialog.openDirectory` returns a tree URI and the runtime takes a
#      *persistable* grant, so the folder survives a relaunch.
#   2. `fs.readDir` lists that tree, in the same `FsEntry` shape a filesystem
#      path lists in.
#   3. Each entry's `path` is a document URI `fs.readBinary` opens — which is
#      the whole point: without listing, the read path that already worked was
#      unreachable, because nothing could learn the URIs.
#   4. A subdirectory in that listing lists in turn (a tree URI and a document
#      URI are not interchangeable, and this is where that bites).
#   5. `fs.metadata` reports `isDir` honestly for a directory document.
#   6. #249: the same tree **serves** — `ctx.serveDirectory` over a tree URI
#      answers `/<mount>/<rel_path>` and honours a `Range`, which is what a
#      reader needs to stream a book rather than load it whole.
#
# **The picker is driven, not tapped by a human.** `uiautomator dump` gives the
# view hierarchy with bounds, so the folder row and the confirm buttons are
# found *by text* and tapped at their centre — coordinates would be a different
# script per device. If the labels don't match (an OEM picker, a locale other
# than English), the run SKIPs with the dump saved, rather than reporting a
# pass it didn't earn.
#
# The first check is a CONTROL that must fail: listing a tree URI the app was
# never granted. A run where everything passes because the probe answers
# everything is the failure mode this script exists to avoid.
#
# Usage:
#   Scripts/verify-android-saf-tree.sh [-s <adb-serial>] [-k]
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

WORK="${TMPDIR:-/tmp}/swift-pwa-android-saf-tree"
APP="SafTreeCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.saftreecheck"
# The folder the user will "pick". Download is one of the few places the
# platform still lets a tree be granted — the volume root is refused outright
# ("To protect your privacy, choose another folder").
LIBRARY="swift-pwa-saf-library"
DEVICE_ROOT="/sdcard/Download/$LIBRARY"

cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "no device: attach one over USB (wireless adb ports rotate and are flaky)" >&2
    exit 1
fi

rm -rf "$WORK"; mkdir -p "$WORK"

# ---------------------------------------------------------------------------
# Driving the picker
# ---------------------------------------------------------------------------

DUMP="$WORK/ui.xml"

# Dump the current view hierarchy to $DUMP. Through a file on the device and
# then `adb pull`: `uiautomator dump /dev/tty` truncates on some builds.
ui_dump() {
    "${ADB[@]}" shell uiautomator dump /sdcard/swift-pwa-ui.xml >/dev/null 2>&1 || return 1
    "${ADB[@]}" shell cat /sdcard/swift-pwa-ui.xml > "$DUMP" 2>/dev/null || return 1
    [ -s "$DUMP" ]
}

# Tap the centre of the first node whose text is exactly $1. By text, so the
# same script works on a phone, a tablet and a fold — a coordinate wouldn't
# survive any of those.
ui_tap_text() {
    local want="$1" bounds x1 y1 x2 y2
    ui_dump || return 1
    # One node per line first: the dump is a single line, and a greedy match
    # across it would pair one node's text with another's bounds.
    bounds="$(tr '<' '\n' < "$DUMP" \
        | grep -F "text=\"$want\"" \
        | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' \
        | head -1 || true)"
    [ -n "$bounds" ] || return 1
    bounds="${bounds#bounds=\"}"; bounds="${bounds%\"}"
    IFS=',[]' read -r _ x1 y1 _ x2 y2 _ <<< "$bounds"
    "${ADB[@]}" shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
    return 0
}

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

# No `permissions` block at all, deliberately: this is the route for an app
# that cannot have All-files access, so the run proves the SAF path standing
# on its own rather than reading files because some other grant was in force.
probe = '''import Foundation
import SwiftPWA

struct ProbeReport: Codable, Sendable { let line: String }
struct ProbeAck: Encodable, Sendable { let ok: Bool }
struct NoArgs: Decodable, Sendable {}

@MainActor
func registerProbes(_ ctx: any AppContext) {
    // Both opt-in, and both needed here: the picker hands back the tree and
    // `fs.*` is what the issue is about. A scaffolded app registers neither.
    ctx.use(DialogPlugin(SystemDialog()))
    ctx.use(FsPlugin(SystemFs()))
    // The control, and the only way anything gets out of an Android app —
    // its stdout and stderr go to /dev/null.
    ctx.registry.register("probe.record", typed: { (args: ProbeReport, _) -> ProbeAck in
        RuntimeDiagnostics.emit("SAFPROBE " + args.line)
        return ProbeAck(ok: true)
    })
    // #249: mount the tree the user picked. One call, the same one a desktop
    // app makes with a path — which is the whole point of taking a tree URI
    // here rather than inventing a second API.
    ctx.registry.register("probe.serveTree", typed: { (args: ProbeReport, _) async -> ProbeReport in
        guard let tree = URL(string: args.line) else { return ProbeReport(line: "bad-uri") }
        await MainThread.run { ctx.serveDirectory(tree, at: "/library") }
        return ProbeReport(line: "mounted")
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

cat > "$APP_DIR/web/index.html" <<HTML
<!doctype html><meta charset="utf-8"><title>SAF tree check</title>
<body style="font:14px system-ui;padding:24px">
  <p id="state">waiting</p>
</body>
<script>
(function () {
  var LIBRARY = '$LIBRARY';
  function report(line) { return __SWIFT_PWA__.invoke('probe.record', { line: line }); }
  function step(name, fn) {
    return fn().then(
      function (detail) { return report(name + ' ' + detail); },
      function (e) { return report(name + ' THREW ' + e); });
  }

  // THE CONTROL, and it must fail: a tree URI this app was never granted.
  // If this "lists", the run is measuring something other than a SAF grant.
  step('control', function () {
    return __SWIFT_PWA__.invoke('fs.readDir', {
      path: 'content://com.android.externalstorage.documents/tree/primary%3ADCIM'
    }).then(function (r) {
      return 'LISTED ' + (r.entries || r).length;
    });
  }).then(function () {
    document.getElementById('state').textContent = 'picking';
    // The script drives the picker from here.
    return __SWIFT_PWA__.invoke('dialog.openDirectory', {});
  }).then(function (picked) {
    var tree = picked.path;
    if (!tree) return report('picked NONE');
    return report('picked ' + (tree.indexOf('content://') === 0) +
                  ' ' + (tree.indexOf(LIBRARY) >= 0)).then(function () {
      return step('list', function () {
        return __SWIFT_PWA__.invoke('fs.readDir', { path: tree }).then(function (r) {
          var entries = r.entries || r;
          var names = entries.map(function (e) { return e.name; }).join(',');
          var dirs = entries.filter(function (e) { return e.isDir; }).length;
          var uris = entries.filter(function (e) {
            return e.path.indexOf('content://') === 0;
          }).length;
          window.__entries = entries;
          return 'names=' + names + ' dirs=' + dirs + ' uris=' + uris;
        });
      });
    }).then(function () {
      // The read path that already worked, reached through a URI only the
      // listing could produce.
      return step('read', function () {
        var book = window.__entries.filter(function (e) {
          return e.name === 'one.txt';
        })[0];
        return __SWIFT_PWA__.invoke('fs.readText', { path: book.path })
          .then(function (r) { return 'text=' + JSON.stringify(r.contents); });
      });
    }).then(function () {
      // Descending: a tree URI and a document URI are not interchangeable,
      // and this is the call that finds out.
      return step('descend', function () {
        var sub = window.__entries.filter(function (e) { return e.isDir; })[0];
        return __SWIFT_PWA__.invoke('fs.readDir', { path: sub.path }).then(function (r) {
          var entries = r.entries || r;
          return 'names=' + entries.map(function (e) { return e.name; }).join(',');
        });
      });
    }).then(function () {
      return step('metadir', function () {
        var sub = window.__entries.filter(function (e) { return e.isDir; })[0];
        return __SWIFT_PWA__.invoke('fs.metadata', { path: sub.path })
          .then(function (m) {
            // `size` is absent, not zero, where the provider doesn't say —
            // reported here so the run pins what a real one actually does.
            return 'isDir=' + m.isDir + ' isFile=' + m.isFile +
                   ' size=' + (m.size == null ? 'unknown' : m.size);
          });
      });
    }).then(function () {
      // #249. Mount the very tree the picker returned, then stream out of it.
      return step('serve', function () {
        return __SWIFT_PWA__.invoke('probe.serveTree', { line: tree }).then(function () {
          return fetch('/library/one.txt', { headers: { Range: 'bytes=4-8' } })
            .then(function (res) {
              return res.text().then(function (t) {
                return 'status=' + res.status + ' len=' + t.length + ' body=' + JSON.stringify(t);
              });
            });
        });
      });
    }).then(function () {
      // A file one level down, which is where the walk has to descend — and
      // the second request into that folder should come off the cache.
      return step('servenested', function () {
        return fetch('/library/chapters/nested.txt').then(function (res) {
          return res.text().then(function (t) {
            return 'status=' + res.status + ' body=' + JSON.stringify(t);
          });
        });
      });
    }).then(function () {
      return step('servemissing', function () {
        return fetch('/library/not-here.txt').then(function (res) {
          return res.text().then(function (t) {
            return 'status=' + res.status + ' body=' + t.length;
          });
        });
      });
    }).then(function () {
      return step('metafile', function () {
        var book = window.__entries.filter(function (e) {
          return e.name === 'one.txt';
        })[0];
        return __SWIFT_PWA__.invoke('fs.metadata', { path: book.path })
          .then(function (m) {
            return 'isDir=' + m.isDir +
                   ' size=' + (m.size == null ? 'unknown' : m.size);
          });
      });
    });
  }).then(function () {
    document.getElementById('state').textContent = 'done';
    return report('finished');
  }, function (e) {
    return report('ABORTED ' + e);
  });
})();
</script>
HTML

cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"
rm -rf "$APP_DIR/.build"

echo "== staging the library folder on the device =="
"${ADB[@]}" shell rm -rf "$DEVICE_ROOT" >/dev/null 2>&1 || true
"${ADB[@]}" shell mkdir -p "$DEVICE_ROOT/chapters"
printf 'the first file' > "$WORK/one.txt"
printf 'the second file' > "$WORK/two.txt"
printf 'a chapter' > "$WORK/nested.txt"
"${ADB[@]}" push "$WORK/one.txt" "$DEVICE_ROOT/one.txt" >/dev/null
"${ADB[@]}" push "$WORK/two.txt" "$DEVICE_ROOT/two.txt" >/dev/null
"${ADB[@]}" push "$WORK/nested.txt" "$DEVICE_ROOT/chapters/nested.txt" >/dev/null
# The media scanner is what makes a freshly-pushed file visible to the
# DocumentsProvider; without it the picker can show an empty folder.
"${ADB[@]}" shell "content call --uri content://media/external/file --method scan_volume" >/dev/null 2>&1 || true

echo "== resolving dependencies =="
if ! (cd "$APP_DIR" && swift package resolve >/dev/null 2>"$WORK/resolve.err"); then
    tail -5 "$WORK/resolve.err" >&2
    exit 1
fi

echo "== cross-compiling, installing and launching on the device =="
# A fresh install, deliberately: a persisted SAF grant survives an update
# install, and reusing one would skip the picker this run exists to exercise.
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a)

"${ADB[@]}" logcat -c || true
"${ADB[@]}" shell am force-stop "$PKG" || true
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
"${ADB[@]}" shell sleep 20 >/dev/null 2>&1 || true

echo "== driving the SAF picker =="
SKIP_REASON=""
# The picker opens on "Files on <device>". The library is under Download, so:
# open Download, open the library folder, then confirm twice.
drive_picker() {
    ui_tap_text "Download" || { SKIP_REASON="no 'Download' row in the picker"; return 1; }
    "${ADB[@]}" shell sleep 2 >/dev/null 2>&1 || true
    ui_tap_text "$LIBRARY" || { SKIP_REASON="no '$LIBRARY' row in the picker"; return 1; }
    "${ADB[@]}" shell sleep 2 >/dev/null 2>&1 || true
    ui_tap_text "USE THIS FOLDER" || { SKIP_REASON="no 'USE THIS FOLDER' button"; return 1; }
    "${ADB[@]}" shell sleep 2 >/dev/null 2>&1 || true
    # The confirmation dialog ("Allow <app> to access files in <folder>?").
    ui_tap_text "ALLOW" || ui_tap_text "Allow" || {
        SKIP_REASON="no 'ALLOW' button on the confirmation dialog"; return 1
    }
    return 0
}

if drive_picker; then
    "${ADB[@]}" shell sleep 10 >/dev/null 2>&1 || true
else
    cp "$DUMP" "$WORK/picker-dump.xml" 2>/dev/null || true
    echo
    echo "SKIP  could not drive the picker — $SKIP_REASON"
    echo "      This is an OEM/locale difference in the SAF UI, not a result."
    echo "      The hierarchy at the point it gave up: $WORK/picker-dump.xml"
    echo "      (re-run with -k to keep it)"
    KEEP=1
    exit 0
fi

LOG="$WORK/logcat.txt"
"${ADB[@]}" logcat -d -s swift-pwa > "$LOG" 2>/dev/null || true

echo
echo "-- what the app saw --"
grep -o 'SAFPROBE .*' "$LOG" | sed 's/^/   /' || echo "   (nothing)"
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
refute() { # label pattern
    local label="$1" pattern="$2"
    if grep -q "$pattern" "$LOG"; then
        echo "FAIL  $label"
        failed=1
    else
        echo "PASS  $label"
    fi
}

# The control first: an ungranted tree must NOT list. Everything below is only
# meaningful if this one fails.
refute "an ungranted tree URI does not list (control)" 'SAFPROBE control LISTED'
expect "…and says why rather than returning nothing" 'SAFPROBE control THREW'

expect "the app reported at all (control)" 'SAFPROBE '
expect "the picker returned a tree URI for the folder we staged" 'SAFPROBE picked true true'
# Sorted by name, so this is the whole listing in one line: two files and the
# subdirectory, each carrying a document URI of its own.
expect "the tree lists, sorted, with a document URI per entry" \
    'SAFPROBE list names=chapters,one.txt,two.txt dirs=1 uris=3'
expect "an entry's URI opens through the read path that already worked" \
    'SAFPROBE read text="the first file"'
expect "a subdirectory in the listing lists in turn" \
    'SAFPROBE descend names=nested.txt'
expect "metadata reports a directory as a directory" \
    'SAFPROBE metadir isDir=true isFile=false'
expect "metadata still reports a file as a file, with its size" \
    'SAFPROBE metafile isDir=false size=14'

# #249: the same tree, mounted and streamed from. "the first file"[4:9] is
# "first".
expect "a picked tree mounts and answers a Range" \
    'SAFPROBE serve status=200 len=5 body="first"'
expect "a file one directory down serves too, which is where the walk descends" \
    'SAFPROBE servenested status=200 body="a chapter"'
expect "a path that is not in the tree 404s with a body" \
    'SAFPROBE servemissing status=404 body=[1-9][0-9]*'
expect "the page ran to the end" 'SAFPROBE finished'

echo
if "${ADB[@]}" shell dumpsys package "$PKG" 2>/dev/null | grep -q "MANAGE_EXTERNAL_STORAGE"; then
    echo "FAIL  the app held All-files access — this run proves nothing about SAF"
    failed=1
else
    echo "PASS  the app never had All-files access (this was SAF alone)"
fi

[ "$failed" -eq 0 ] || exit 1
echo
echo "A folder picked through SAF can be listed, descended and read on Android."
