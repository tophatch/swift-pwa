#!/usr/bin/env bash
#
# End-to-end check that an Android build can tell the app's own page from a
# frame it embeds - `CommandContext.frame` (#204).
#
# `bridge.js` is injected with `WebViewCompat.addDocumentStartJavaScript`, which
# runs in every frame on the app's origin, so an `<iframe>` can invoke commands
# exactly as the app's own page does. The inbound channel is what decides
# whether the runtime can see the difference: `addJavascriptInterface` reports
# nothing about the caller, while `WebViewCompat.addWebMessageListener` carries
# `isMainFrame` and the sending document's origin.
#
# Nothing here can be checked from the page: an embedded frame's reply never
# reaches it (`deliver` evaluates into the main frame), so the app's own
# diagnostics - which reach logcat, unlike stdout - are the only observer.
#
# Usage:
#   Scripts/verify-android-frame-identity.sh [-s <adb-serial>] [-k]
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

WORK="${TMPDIR:-/tmp}/swift-pwa-android-frame-check"
APP="FrameCheck"
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

# Point the scaffold at this checkout rather than the published release, and
# give it a package id we can `run-as` / filter logcat by.
python3 - "$APP_DIR" "$REPO" <<'PY'
import pathlib, re, sys
app_dir, repo = pathlib.Path(sys.argv[1]), sys.argv[2]

manifest = app_dir / "Package.swift"
text = manifest.read_text()
text = re.sub(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
              f'.package(path: "{repo}")', text)
text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
manifest.write_text(text)


# The handler reports through RuntimeDiagnostics, which Android routes to
# logcat - stdout and stderr are discarded there, which is exactly how a silent
# refusal stayed silent before.
app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
probe = '''    struct ProbeArgs: Codable, Sendable { let label: String }
    struct ProbeResult: Codable, Sendable { let ok: Bool }
    ctx.registry.register("probe.record", typed: { (args: ProbeArgs, cmd) -> ProbeResult in
        let seen: String
        switch cmd.frame {
        case .main: seen = "main"
        case let .subframe(origin):
            if let o = origin { seen = "subframe(\\(o.scheme)://\\(o.host))" } else { seen = "subframe(nil)" }
        case .unknown: seen = "unknown"
        }
        RuntimeDiagnostics.emit("FRAMEPROBE " + args.label + " " + seen)
        return ProbeResult(ok: true)
    })

'''
app_swift.write_text(re.sub(r'(?m)^    _ = try ctx\.createWindow\(',
                            probe + '    _ = try ctx.createWindow(',
                            app_swift.read_text()))
PY

# One document serves every nesting level: each copy calls the command and,
# until the deepest level, embeds another.
cat > "$APP_DIR/web/child.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>child</title>
<script>
  var params = new URLSearchParams(location.search);
  var depth = parseInt(params.get('depth') || '1', 10);
  __SWIFT_PWA__.invoke('probe.record', { label: params.get('label') || 'child-path' });
  var next = { 1: 'grandchild', 2: 'great-grandchild' }[depth];
  if (next) {
    document.addEventListener('DOMContentLoaded', function () {
      var f = document.createElement('iframe');
      f.src = 'child.html?label=' + next + '&depth=' + (depth + 1);
      document.body.appendChild(f);
    });
  }
</script>
<body></body>
HTML

# The main document embeds itself once, which is the case a comparison of URIs
# could not answer: the child's document URI is identical to its parent's.
cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>frame identity check</title>
<body style="font:14px system-ui;padding:24px">Checking frame identity...</body>
<script>
(function () {
  var isTop = window.top === window;
  __SWIFT_PWA__.invoke('probe.record', { label: isTop ? 'main' : 'child-same' });
  if (!isTop) { return; }
  function frame(attr, value) {
    var f = document.createElement('iframe');
    f.setAttribute(attr, value);
    document.body.appendChild(f);
  }
  frame('src', 'child.html?label=child-path');
  frame('src', location.pathname);
  frame('srcdoc', '<script>__SWIFT_PWA__.invoke("probe.record", { label: "srcdoc" });<\/script>');
})();
</script>
HTML

# Pin the scaffold to the checkout's own dependency versions: the app depends
# on this checkout by path, so its pins are the right ones and the build is
# reproducible run to run.
cp "$REPO/Package.resolved" "$APP_DIR/Package.resolved"

# The whole build dir, not just the Android triple: the host resolve runs under
# the default toolchain and the cross-compile under 6.2, and their SwiftPM
# checkout layouts collide ("already exists in file system"). It also covers the
# rule that a C-shim header change, or a struct-layout change in core, doesn't
# reliably invalidate the cross-compiled cache - both surface as a crash or a
# stale binary rather than a rebuild.
rm -rf "$APP_DIR/.build"

"${ADB[@]}" logcat -c || true

# Resolve up front, under the toolchain the cross-compile uses, so a dependency
# problem is reported as one instead of surfacing as "could not produce a native
# library for the requested ABI".
echo "== resolving dependencies =="
# --skip-update: with pins copied above and the dependencies already in the
# shared cache, there is nothing to update - and the update is what
# intermittently fails, on a different dependency each run.
if ! (cd "$APP_DIR" && swiftly run +6.2 swift package resolve --skip-update >/dev/null 2>"$WORK/resolve.err"); then
    tail -5 "$WORK/resolve.err" >&2
    if grep -q "already exists in file system" "$WORK/resolve.err"; then
        cat >&2 <<'HINT'

SwiftPM reports this as "no connectivity" for one dependency - a different one
each run - while that same repository clones and fetches fine by hand, so it is
a race in its update path rather than a network or cache problem. Deleting the
named repository under ~/Library/Caches/org.swift.swiftpm/repositories clears it
for a run or two; it is re-cloned on the next resolve.
HINT
    fi
    exit 1
fi

echo "== cross-compiling, installing and launching on the device =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a)

# Device-side sleep: a foreground sleep here is blocked, and the frames need a
# moment to load, run bridge.js and call.
"${ADB[@]}" shell sleep 12 >/dev/null 2>&1 || true

LOG="$WORK/logcat.txt"
"${ADB[@]}" logcat -d -s swift-pwa > "$LOG" 2>/dev/null || true

echo
echo "-- what the app saw --"
grep -o 'FRAMEPROBE .*' "$LOG" | sed 's/^/   /' || echo "   (nothing)"

failed=0
check() { # label expected
    local label="$1" want="$2"
    # `|| true` on both: with `set -e` plus `pipefail`, a grep that matches
    # nothing would abort the script at the first missing label instead of
    # reporting it - which hid every check after the first failure.
    local got count
    got=$(grep -o "FRAMEPROBE $label [^ ]*" "$LOG" | awk '{print $3}' | sort -u || true)
    count=$(grep -c "FRAMEPROBE $label " "$LOG" || true)
    if [ -z "$got" ]; then
        echo "FAIL  $label never reached the bridge (expected $want)"
        failed=1
    elif [ "$count" -gt 1 ]; then
        echo "FAIL  $label arrived $count times - delivered on more than one channel"
        failed=1
    elif [ "$got" != "$want" ]; then
        echo "FAIL  $label reported $got, expected $want"
        failed=1
    else
        echo "PASS  $label -> $want"
    fi
}

ORIGIN="subframe(https://swift-pwa.local)"
check main             main
check child-path       "$ORIGIN"
check child-same       "$ORIGIN"
check grandchild       "$ORIGIN"
check great-grandchild "$ORIGIN"

# `srcdoc` inherits its parent's origin but has no URL of its own, so whether
# the message-listener origin rules admit it is a property of the WebView, not
# of this package. Reported either way rather than asserted.
if grep -q "FRAMEPROBE srcdoc " "$LOG"; then
    echo "NOTE  srcdoc reached the bridge as $(grep -o 'FRAMEPROBE srcdoc [^ ]*' "$LOG" | awk '{print $3}' | sort -u)"
else
    echo "NOTE  srcdoc did not reach the bridge - the origin rules exclude it"
fi

[ "$failed" -eq 0 ] || exit 1
echo
echo "Frame identity is reported correctly on Android."
