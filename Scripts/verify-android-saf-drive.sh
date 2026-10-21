#!/usr/bin/env bash
#
# Whether a file added to a picked Google Drive folder from elsewhere shows up
# in `fs.readDir` on Android (#316).
#
# Drive's DocumentsProvider answers a listing from its local cache. Read once,
# the cache is all an app gets: a file uploaded to the folder from a computer
# stayed out of every listing for as long as this looked. Drive never marks
# that listing `EXTRA_LOADING`; it brings it up to date when asked to
# (`ContentResolver.refresh`) and notifies about a second later. The runtime
# now asks, waits for the notification and lists again.
#
# Needs a Drive folder the probe app was granted, and the same folder synced on
# this Mac by Google Drive for desktop, which is where new files are added
# from. The grant survives the reinstall between a control run and a fixed run
# (the same debug key signs both), so the folder is picked once:
#
#   1. Scripts/verify-android-saf-drive.sh --folder <local Drive path> --pick
#      and pick the folder in the system picker on the device.
#   2. Scripts/verify-android-saf-drive.sh --folder <...> --released
#      The control: a file added now must NOT appear, in any of five listings
#      over two minutes. If it does, Drive's cache caught up on its own and the
#      fixed run below proves nothing; run again later.
#   3. Scripts/verify-android-saf-drive.sh --folder <...>
#      A file added now has to appear in the first listing. Then the two ends
#      of `loadingTimeoutMs`: 1 ms has to fail with E_STILL_LOADING, and 0 has
#      to return the cached listing without an error.
#
# Usage:
#   Scripts/verify-android-saf-drive.sh --folder <path> [-s <adb-serial>] [--pick] [--released] [-k]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
FOLDER=""
PICK=0
RELEASED=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERIAL="$2"; shift 2 ;;
        --folder) FOLDER="$2"; shift 2 ;;
        --pick) PICK=1; shift ;;
        --released) RELEASED=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 --folder <path> [-s serial] [--pick] [--released] [-k]" >&2; exit 2 ;;
    esac
done
[ -d "$FOLDER" ] || { echo "--folder must be the picked Drive folder as Drive for desktop syncs it here" >&2; exit 2; }

ADB=(adb)
CDP=("$REPO/Scripts/android-cdp-eval.py")
if [ -n "$SERIAL" ]; then
    ADB=(adb -s "$SERIAL")
    CDP+=(-s "$SERIAL")
    export ANDROID_SERIAL="$SERIAL"
fi

WORK="${TMPDIR:-/tmp}/swift-pwa-android-saf-drive${SERIAL:+-$SERIAL}"
APP="SafDriveCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.safdrivecheck"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device" >&2; exit 1; }
# A Samsung with its screen off freezes the app, and a CDP call then hangs.
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP

rm -rf "$WORK"; mkdir -p "$WORK"
if [ "$RELEASED" -eq 1 ]; then
    echo "== downloading the last release's CLI =="
    gh release download --repo tophatch/swift-pwa --pattern "swift-pwa-macos-$(uname -m)" --dir "$WORK"
    CLI="$WORK/swift-pwa-macos-$(uname -m)"
    chmod +x "$CLI"
else
    echo "== building the CLI =="
    (cd "$REPO" && swift build --product swift-pwa >/dev/null)
    CLI="$REPO/.build/debug/swift-pwa"
fi
(cd "$WORK" && "$CLI" init "$APP" >/dev/null)
python3 - "$APP_DIR" "$REPO" "$RELEASED" <<'PY'
import pathlib, re, sys
app_dir, repo, released = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
if not released:
    manifest = app_dir / "Package.swift"
    text = manifest.read_text()
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', text)
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
    manifest.write_text(text)
app = app_dir / "Sources" / app_dir.name / "App.swift"
text = app.read_text()
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    ctx.use(DialogPlugin(SystemDialog()))\n    ctx.use(FsPlugin(SystemFs()))\n\n'
                      '    _ = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app.write_text(text)
PY
# The picked tree lives in localStorage, which a reinstall keeps.
cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Drive check</title>
<body style="font:16px system-ui;padding:24px"><p>Drive check</p>
<script>
window.pick = () => { __SWIFT_PWA__.invoke('dialog.openDirectory', {})
  .then((r) => localStorage.setItem('tree', r.path || '')); return 'picking'; };
window.list = async (timeout) => {
  const args = { path: localStorage.getItem('tree') };
  if (timeout != null) args.loadingTimeoutMs = timeout;
  const start = performance.now();
  try {
    const r = await __SWIFT_PWA__.invoke('fs.readDir', args);
    return (r.entries || r).map((e) => e.name).join(',') + ' in ' + Math.round(performance.now() - start) + ' ms';
  } catch (e) { return 'THREW ' + (e.code || '') + ' ' + e.message; }
};
</script>
HTML

echo "== deploying =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis arm64-v8a >"$WORK/deploy.log" 2>&1) \
    || { tail -30 "$WORK/deploy.log"; exit 1; }
js() { "${CDP[@]}" "$PKG" "$1" 2>/dev/null; }
for _ in $(seq 1 30); do [ "$(js "typeof window.list")" = '"function"' ] && break; sleep 1; done

if [ "$PICK" -eq 1 ]; then
    js "pick()" >/dev/null
    echo "Pick the Drive folder synced at $FOLDER in the picker on the device, then ALLOW."
    for _ in $(seq 1 120); do
        tree=$(js "localStorage.getItem('tree')" || true)
        [ -n "$tree" ] && [ "$tree" != '""' ] && [ "$tree" != "null" ] && { echo "picked $tree"; exit 0; }
        sleep 2
    done
    echo "nothing was picked" >&2; exit 1
fi
tree=$(js "localStorage.getItem('tree')")
case "$tree" in *content://*) ;; *) echo "no folder granted yet: run with --pick first" >&2; exit 1 ;; esac

# Added from this Mac, then waited for until Drive for desktop has uploaded it
# (it tags an uploaded item with its Drive id).
NAME="added-$(date +%H%M%S).txt"
printf 'added from elsewhere' > "$FOLDER/$NAME"
echo "== added $NAME; waiting for Drive for desktop to upload it =="
for _ in $(seq 1 60); do
    xattr -p "com.google.drivefs.item-id#S" "$FOLDER/$NAME" >/dev/null 2>&1 && break
    sleep 2
done
xattr -p "com.google.drivefs.item-id#S" "$FOLDER/$NAME" >/dev/null 2>&1 \
    || { echo "Drive for desktop never uploaded $NAME" >&2; exit 1; }
sleep 15

"${ADB[@]}" logcat -c
FAILED=0
if [ "$RELEASED" -eq 1 ]; then
    seen=0
    for i in 1 2 3 4 5; do
        got=$(js "list()")
        echo "   listing $i: $got"
        [[ "$got" == *"$NAME"* ]] && seen=1
        [ "$i" -lt 5 ] && sleep 25
    done
    if [ "$seen" -eq 0 ]; then
        echo "PASS control: the released build never listed $NAME (Drive's cache was stale)"
    else
        echo "INCONCLUSIVE control: the released build listed $NAME, so the cache caught up by itself"
        FAILED=2
    fi
else
    got=$(js "list()")
    echo "   listing: $got"
    waited=$("${ADB[@]}" logcat -d -s swift-pwa | grep -c "SAF listing refreshing" || true)
    echo "   waited on the provider's refresh $waited time(s)"
    if [[ "$got" == *"$NAME"* ]]; then
        echo "PASS the first listing after the upload has $NAME"
    else
        echo "FAIL the first listing after the upload lacks $NAME"
        FAILED=1
    fi
    again=$(js "list()")
    echo "   listing again, nothing changed: $again"
    short=$(js "list(1)")
    echo "   loadingTimeoutMs 1: $short"
    if [[ "$short" == *"THREW E_STILL_LOADING"* ]]; then
        echo "PASS a wait too short to see the refresh fails as E_STILL_LOADING"
    else
        echo "FAIL a 1 ms wait didn't fail as E_STILL_LOADING"
        FAILED=1
    fi
    cached=$(js "list(0)")
    echo "   loadingTimeoutMs 0: $cached"
    if [[ "$cached" == *"$NAME"* && "$cached" != *THREW* ]]; then
        echo "PASS loadingTimeoutMs 0 returns the cached listing at once"
    else
        echo "FAIL loadingTimeoutMs 0 didn't return the cached listing"
        FAILED=1
    fi
fi
exit "$FAILED"
