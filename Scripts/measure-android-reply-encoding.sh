#!/usr/bin/env bash
#
# How long a large command reply takes to reach the page on Android (#307).
#
# Scaffolds an app with one typed command returning N records of 20 fields,
# the shape of a list a page re-requests, deploys it, and times
# `invoke` from the page with `performance.now()` across several runs. The
# whole reply crosses `Envelope.encode`, which off Apple is where a large
# reply's time went.
#
# Pass --released for the control: the same app built against the last release
# instead of this checkout, so both numbers come from one device, one app, one
# payload.
#
# Usage:
#   Scripts/measure-android-reply-encoding.sh [-s <adb-serial>] [-n rows] [-r runs] [--released] [-k]
#     -s          adb serial to target (default: the only attached device)
#     -n          records in the reply (default 45000, about 15 MB of JSON)
#     -r          timed runs after one warm-up (default 5)
#     --released  build against the released package (the scaffold's default pin)
#     -k          keep the scaffolded app directory for debugging
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
ROWS=45000
RUNS=5
RELEASED=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERIAL="$2"; shift 2 ;;
        -n) ROWS="$2"; shift 2 ;;
        -r) RUNS="$2"; shift 2 ;;
        --released) RELEASED=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 [-s serial] [-n rows] [-r runs] [--released] [-k]" >&2; exit 2 ;;
    esac
done

ADB=(adb)
CDP=("$REPO/Scripts/android-cdp-eval.py" --timeout 300)
if [ -n "$SERIAL" ]; then
    ADB=(adb -s "$SERIAL")
    CDP+=(-s "$SERIAL")
fi

WORK="${TMPDIR:-/tmp}/swift-pwa-reply-encoding"
APP="ReplyBench"
APP_DIR="$WORK/$APP"
PKG="com.example.replybench"

cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "no device: attach one over USB (wireless adb ports rotate and are flaky)" >&2
    exit 1
fi
# A Samsung with its screen off freezes the app, and a CDP call then hangs.
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP

rm -rf "$WORK"; mkdir -p "$WORK"

echo "== building the CLI =="
(cd "$REPO" && swift build --product swift-pwa >/dev/null)
CLI="$REPO/.build/debug/swift-pwa"

echo "== scaffolding $APP =="
(cd "$WORK" && "$CLI" init "$APP" >/dev/null)
python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import pathlib, re, sys
app_dir, repo, released = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
manifest = app_dir / "Package.swift"
text = manifest.read_text()
pin = re.search(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "([^"]+)"\)', text)
assert pin, "the scaffold's package pin moved; this patch needs updating"
if released:
    print(f"   against the released package, {pin.group(1)}")
else:
    text = text.replace(pin.group(0), f'.package(path: "{repo}")')
    text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
    print("   against this checkout")
manifest.write_text(text)

app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text = app_swift.read_text()
command = '''    ctx.registry.register("bench.rows", typed: { (args: BenchArgs, _) -> [BenchRow] in
        (0 ..< args.count).map(BenchRow.init)
    })

'''
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(', command + '    _ = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
text += '''
struct BenchArgs: Codable, Sendable { var count: Int }

/// Twenty fields, mixed types, a few optionals: a record a page lists.
struct BenchRow: Codable, Sendable {
    var id: Int, bookId: Int, index: Int, wordCount: Int, position: Int
    var title: String, path: String, lang: String, author: String, kind: String
    var readAt: Double?, progress: Double, updated: Double, created: Double
    var hidden: Bool, bookmarked: Bool, downloaded: Bool
    var series: String?, tags: [String], href: String

    init(_ i: Int) {
        id = i; bookId = i / 50; index = i % 50; wordCount = 3000 + i % 997; position = i
        title = "Chapter \\(i): \\"A title\\""; path = "books/\\(i / 50)/\\(i).xhtml"; lang = "en"
        author = "Someone"; kind = "chapter"
        readAt = i % 3 == 0 ? nil : 1.7e9 + Double(i); progress = Double(i % 100) / 100
        updated = 1.7e9; created = 1.6e9
        hidden = i % 7 == 0; bookmarked = false; downloaded = true
        series = nil; tags = ["fiction", "en"]; href = "#c\\(i)"
    }
}
'''
app_swift.write_text(text)
PY

"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
echo "== deploying ($ABI) =="
# `deploy` compiles the Swift side in release, what an adopter's users run, and
# installs the debug APK, whose WebView is reachable over DevTools.
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis "$ABI" >"$WORK/deploy.log" 2>&1) \
    || { tail -30 "$WORK/deploy.log"; exit 1; }

for _ in $(seq 1 30); do
    "${CDP[@]}" "$PKG" "typeof __SWIFT_PWA__" 2>/dev/null | grep -q object && break
    sleep 1
done

echo "== timing invoke('bench.rows', {count: $ROWS}), 1 warm-up + $RUNS runs =="
"${CDP[@]}" "$PKG" "(async () => {
  const times = [];
  let length = 0;
  for (let i = 0; i <= $RUNS; i++) {
    const start = performance.now();
    const rows = await __SWIFT_PWA__.invoke('bench.rows', { count: $ROWS });
    const ms = performance.now() - start;
    if (rows.length !== $ROWS) throw new Error('got ' + rows.length + ' rows');
    length = JSON.stringify(rows).length;
    if (i > 0) times.push(Math.round(ms));
  }
  const sorted = [...times].sort((a, b) => a - b);
  return JSON.stringify({ runs: times, median: sorted[sorted.length >> 1], replyChars: length });
})()" | python3 -c 'import json, sys
r = json.loads(json.loads(sys.stdin.read()))  # the CDP helper prints the string JSON-encoded
print("runs (ms):", r["runs"])
print("median:   ", r["median"], "ms")
print("reply:    ", round(r["replyChars"] / 1e6, 1), "M chars")'
