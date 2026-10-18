#!/usr/bin/env bash
#
# What a page receives on `app.openFile` on Android (#298).
#
# An opened document arrives as a `content://` URI, and for MediaStore,
# Downloads and most apps' FileProviders the URI's last segment is an id, not a
# name. The intent's MIME type is gone once the Activity has handled it. So the
# Activity resolves both while it holds the read grant, and the page gets them
# beside the path. Rows:
#
#   1. "Open with" (ACTION_VIEW) of a MediaStore image on a COLD launch: the
#      name has a space and an underscore, and must arrive as the provider's
#      display name, with the provider's type, and the file must be readable.
#   2. The same for a MediaStore audio file opened into the RUNNING app, from a
#      different provider table. The launcher Activity is `standard`, so this
#      arrives as a second Activity that hands the intent to the first and
#      finishes, and the read grant belongs to the one that finishes. The file
#      must still be readable afterwards.
#   3. CONTROL, and it must fall back: a URI the provider has no row for. The
#      name is the URI's last segment and the type is the one on the intent.
#
# Rows 1 and 2 send a deliberately wrong type on the intent, so a pass proves
# the type came from the provider and not the intent.
#
# What `am start` can't do, and so what this leaves to a share by hand:
#   - A share (ACTION_SEND). `--grant-read-uri-permission` covers the intent's
#     data and ClipData; an app's own startActivity copies EXTRA_STREAM into
#     ClipData, `am start` doesn't, so a shell share arrives with no grant.
#   - A non-media file. The shell's grant reaches MediaStore's media
#     collections but not its generic `external/file` rows or a documents
#     provider; the app can't read such a file at all.
# Both run the same lookup as these rows. Share a PDF from the Files app to
# check them.
#
# Usage:
#   Scripts/verify-android-open-file.sh [-s <adb-serial>] [-k]
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
CDP=("$REPO/Scripts/android-cdp-eval.py")
if [ -n "$SERIAL" ]; then
    ADB=(adb -s "$SERIAL")
    CDP+=(-s "$SERIAL")
fi

WORK="${TMPDIR:-/tmp}/swift-pwa-android-open-file"
APP="OpenCheck"
APP_DIR="$WORK/$APP"
PKG="com.example.opencheck"
JPG_NAME="OpenCheck Photo_0001.jpg"
MP3_NAME="opencheck tone_01.mp3"

cleanup() {
    "${ADB[@]}" shell rm -f "'/sdcard/Download/$JPG_NAME'" "'/sdcard/Download/$MP3_NAME'" >/dev/null 2>&1 || true
    [ "$KEEP" -eq 1 ] || rm -rf "$WORK"
}
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

echo "== scaffolding $APP against this checkout =="
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

# fs.* so a row can also read the file, which tells "the app has no grant"
# apart from "the provider wouldn't name it".
app_swift = app_dir / "Sources" / app_dir.name / "App.swift"
text = app_swift.read_text()
text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                      '    ctx.use(FsPlugin(SystemFs()))\n\n    _ = try ctx.createWindow(', text)
assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
app_swift.write_text(text)
PY

# Subscribed at startup, as the docs say to: a cold-launch file is retained and
# replays on subscribe.
cat > "$APP_DIR/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>open file check</title>
<body style="font:14px system-ui;padding:24px">waiting for app.openFile…</body>
<script>
window.__opened = [];
__SWIFT_PWA__.on('app.openFile', function (payload) {
  window.__opened.push(payload);
  document.body.textContent = JSON.stringify(payload);
});
</script>
HTML

# Uninstall first: a URI grant the app was given on an earlier run outlives the
# reinstall that `deploy` does, and would let a read pass that shouldn't.
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
echo "== deploying ($ABI) =="
(cd "$APP_DIR" && "$CLI" deploy --target android --android-abis "$ABI" >"$WORK/deploy.log" 2>&1) \
    || { tail -30 "$WORK/deploy.log"; exit 1; }

echo "== fixtures =="
# MediaStore files each by extension: the JPEG under images, the ID3 stub
# under audio.
printf 'ID3\x03\x00\x00\x00\x00\x00\x00' > "$WORK/$MP3_NAME"
base64 -d > "$WORK/$JPG_NAME" <<'B64'
/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=
B64
"${ADB[@]}" push "$WORK/$JPG_NAME" "$WORK/$MP3_NAME" /sdcard/Download/ >/dev/null

media_id() { # <collection-uri> <display-name>
    local row
    for _ in $(seq 1 20); do
        row=$("${ADB[@]}" shell content query --uri "$1" --projection _id \
            --where "\"_display_name='$2'\"" 2>/dev/null | tr -d '\r' || true)
        if [[ "$row" =~ _id=([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
        sleep 0.5
    done
    echo "MediaStore never indexed $2" >&2
    exit 1
}
JPG_URI="content://media/external/images/media/$(media_id content://media/external/images/media "$JPG_NAME")"
MP3_URI="content://media/external/audio/media/$(media_id content://media/external/audio/media "$MP3_NAME")"
MISSING_URI="content://media/external/file/987654321"
echo "jpg: $JPG_URI"
echo "mp3: $MP3_URI"

last_payload() {
    for _ in $(seq 1 30); do
        out=$("${CDP[@]}" "$PKG" "JSON.stringify(window.__opened.at(-1) || null)" 2>/dev/null || true)
        if [ -n "$out" ] && [ "$out" != '"null"' ]; then echo "$out"; return; fi
        sleep 0.5
    done
    echo '"null"'
}

FAIL=0
check() { # <row> <payload-json-in-json> <expected-name> <expected-type>
    if python3 - "$2" "$3" "$4" <<'PY'
import json, sys
raw, name, mime = sys.argv[1:4]
payload = json.loads(json.loads(raw))  # the CDP helper prints the string JSON-encoded
ok = (payload is not None
      and payload.get("names") == [name]
      and payload.get("mimeTypes") == [mime]
      and len(payload.get("paths", [])) == 1)
print("  payload:", json.dumps(payload))
sys.exit(0 if ok else 1)
PY
    then echo "PASS $1"
    else echo "FAIL $1 (wanted name=$3 type=$4)"; FAIL=1
    fi
}

# The control proves the name and type in rows 1 and 2 came from the
# provider: here there's no row, so they must be the fallbacks.
readable() { # <row> <uri>: the grant reached the app, so the read works
    out=$("${CDP[@]}" "$PKG" "(async()=>{try{await __SWIFT_PWA__.invoke('fs.readBinary',{path:'$2'});return 'ok'}catch(e){return String(e)}})()" || true)
    if [ "$out" = '"ok"' ]; then echo "PASS $1: readable"
    else echo "FAIL $1: not readable: $out"; FAIL=1
    fi
}

echo "== 1. open with, cold launch =="
"${ADB[@]}" shell am force-stop "$PKG"
"${ADB[@]}" shell am start -W -n "$PKG/.MainActivity" -a android.intent.action.VIEW \
    -d "$JPG_URI" -t application/x-not-the-type --grant-read-uri-permission >/dev/null
check "open with (cold)" "$(last_payload)" "$JPG_NAME" "image/jpeg"
readable "open with (cold)" "$JPG_URI"

echo "== 2. open with, warm =="
"${ADB[@]}" shell am start -W -n "$PKG/.MainActivity" -a android.intent.action.VIEW \
    -d "$MP3_URI" -t application/x-not-the-type --grant-read-uri-permission >/dev/null
check "open with (warm)" "$(last_payload)" "$MP3_NAME" "audio/mpeg"
readable "open with (warm)" "$MP3_URI"

echo "== 3. control: no provider row, so the fallbacks =="
"${ADB[@]}" shell am start -W -n "$PKG/.MainActivity" -a android.intent.action.SEND \
    -t application/x-check --eu android.intent.extra.STREAM "$MISSING_URI" --grant-read-uri-permission >/dev/null
check "fallback (control)" "$(last_payload)" "987654321" "application/x-check"

exit "$FAIL"
