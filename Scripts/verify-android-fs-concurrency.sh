#!/usr/bin/env bash
#
# Whether Android file calls run side by side, or queue behind one slow
# provider (#322).
#
# A listing of a Google Drive folder asks Drive to refresh and waits for its
# notification — about a second on a warm provider, up to `loadingTimeoutMs`
# on a cold one (#316). On one shared thread, everything else waited behind
# that. Rows:
#
#   0. Each listing really waits on Drive (over 300 ms on average) — the
#      instrument's own control. Without the wait the rows below prove nothing.
#   1. Six listings sent together take well under the time of six sent one
#      after another: their waits overlap.
#   2. A call sent while a listing waits (a file's metadata, which asks the
#      provider nothing slow) answers without waiting for that listing.
#
# The folder is listed six times rather than six folders once, so the run
# creates nothing in the user's Drive. It needs the Drive folder picked for
# Scripts/verify-android-saf-drive.sh (`--pick`): this scaffolds the same app,
# whose grant and stored folder survive the reinstall.
#
# With --released, the app is built by the last release's CLI and package: the
# control, where rows 1 and 2 have to fail.
#
# Usage:
#   Scripts/verify-android-fs-concurrency.sh [-s <adb-serial>] [--released] [-k]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
RELEASED=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERIAL="$2"; shift 2 ;;
        --released) RELEASED=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 [-s serial] [--released] [-k]" >&2; exit 2 ;;
    esac
done

ADB=(adb)
CDP=("$REPO/Scripts/android-cdp-eval.py")
DEVICE_FLAG=()
if [ -n "$SERIAL" ]; then
    ADB=(adb -s "$SERIAL")
    CDP+=(-s "$SERIAL")
    DEVICE_FLAG=(--device "$SERIAL")
    export ANDROID_SERIAL="$SERIAL"
fi
# The app Scripts/verify-android-saf-drive.sh picks the folder with.
APP=SafDriveCheck
PKG=com.example.safdrivecheck

WORK="${TMPDIR:-/tmp}/swift-pwa-fs-concurrency"
APP_DIR="$WORK/$APP"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
rm -rf "$WORK"; mkdir -p "$WORK"

if [ "$RELEASED" -eq 1 ]; then
    echo "== downloading the last release's CLI =="
    gh release download --repo tophatch/swift-pwa --pattern "swift-pwa-macos-$(uname -m)" --dir "$WORK"
    CLI="$WORK/swift-pwa-macos-$(uname -m)"
    chmod +x "$CLI"
else
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa >"$WORK/cli-build.log" 2>&1) \
        || { grep -E "error:" "$WORK/cli-build.log" | head -20; exit 1; }
    CLI="$REPO/.build/debug/swift-pwa"
fi
(cd "$WORK" && "$CLI" init "$APP" >/dev/null)
python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import pathlib, re, sys
app_dir, repo, released = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "1"
if not released:
    package = app_dir / "Package.swift"
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', package.read_text())
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    package.write_text(text.replace('package: "swift-pwa"', f'package: "{repo.name}"'))
# The plugins Scripts/verify-android-saf-drive.sh registers, so the page can
# list the folder it picked.
app = app_dir / "Sources" / app_dir.name / "App.swift"
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    ctx.use(DialogPlugin(SystemDialog()))\n    ctx.use(FsPlugin(SystemFs()))\n\n'
                      '    _ = try ctx.createWindow(', app.read_text())
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app.write_text(text)
PY

echo "== deploying =="
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a ${DEVICE_FLAG[@]+"${DEVICE_FLAG[@]}"} \
    >"$WORK/deploy.log" 2>&1) || { grep -E "error|Error" "$WORK/deploy.log" | head -20; exit 1; }
"${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 4

tree="$("${CDP[@]}" "$PKG" "localStorage.getItem('tree')" 2>&1 | tail -1)"
case "$tree" in *content://*) ;; *) echo "no Drive folder granted: run Scripts/verify-android-saf-drive.sh --pick first" >&2; exit 1 ;; esac

out="$("${CDP[@]}" --timeout 300 "$PKG" "$(cat <<'JS'
(async () => {
  const tree = localStorage.getItem('tree');
  const now = () => performance.now();
  const list = () => __SWIFT_PWA__.invoke('fs.readDir', { path: tree });
  const first = await list();
  const file = (first.entries.find(e => e.isFile) || first.entries[0]).path;
  const n = 6;
  let t0 = now();
  for (let i = 0; i < n; i++) await list();
  const sequential = Math.round(now() - t0);
  t0 = now();
  await Promise.all(Array.from({ length: n }, list));
  const parallel = Math.round(now() - t0);
  t0 = now();
  const listing = list().then(() => Math.round(now() - t0));
  await new Promise(r => setTimeout(r, 30));
  const m0 = now();
  await __SWIFT_PWA__.invoke('fs.metadata', { path: file });
  const metadata = Math.round(now() - m0);
  return 'n=' + n + ' sequential=' + sequential + ' parallel=' + parallel +
         ' metadata=' + metadata + ' listing=' + (await listing);
})()
JS
)" 2>&1 | tail -1)"
echo "   $out"
num() { echo "$out" | grep -oE "$1=[0-9]+" | cut -d= -f2; }
n=$(num n); seq=$(num sequential); par=$(num parallel); meta=$(num metadata); listing=$(num listing)
[ -n "$seq" ] || { echo "the page reported nothing usable"; exit 1; }

PASS=0
FAIL=0
row() { if [ "$3" -eq 1 ]; then PASS=$((PASS + 1)); echo "PASS $1. $2"; else FAIL=$((FAIL + 1)); echo "FAIL $1. $2"; fi; }
[ $((seq / n)) -gt 300 ] && ok=1 || ok=0
row 0 "each listing waits on Drive ($((seq / n)) ms each) — the instrument can see a stall" "$ok"
[ $((par * 2)) -lt "$seq" ] && ok=1 || ok=0
row 1 "$n listings sent together overlap ($par ms, against $seq ms one after another)" "$ok"
[ $((meta * 2)) -lt "$listing" ] && ok=1 || ok=0
row 2 "a call sent during a listing doesn't wait for it ($meta ms, the listing $listing ms)" "$ok"

NOTE=""
if [ "$RELEASED" -eq 1 ]; then NOTE=" (control: rows 1 and 2 should fail)"; fi
echo "== $PASS passed, $FAIL failed$NOTE =="
if [ "$RELEASED" -eq 1 ]; then [ "$PASS" -eq 1 ]; else [ "$FAIL" -eq 0 ]; fi
