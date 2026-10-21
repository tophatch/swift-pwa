#!/usr/bin/env bash
#
# Whether `swift-pwa deploy --target android` says so when the app it launched
# isn't running (#313). `am start -W` reports `Status: ok` whenever the intent
# was delivered, so deploy printed "Deployed" for an app that crashed at
# launch, or that the device froze as it started (a Boox's App Freeze).
#
# Rows:
#   1. A scaffolded app that runs: "Deployed to <serial>." With --freezes (a
#      device that disables a freshly installed app as it launches), the same
#      app has to be reported not running, with the freeze named instead.
#   2. The same app with a `configure` that crashes: "Installed on <serial>;
#      the app is not running".
#
# With --released, deploy is the last release's CLI: the control, where row 2
# has to fail (it printed "Deployed").
#
# Usage:
#   Scripts/verify-android-deploy-launch.sh [-s <adb-serial>] [--released] [--freezes] [-k]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
RELEASED=0
FREEZES=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERIAL="$2"; shift 2 ;;
        --released) RELEASED=1; shift ;;
        --freezes) FREEZES=1; shift ;;
        -k) KEEP=1; shift ;;
        *) echo "usage: $0 [-s serial] [--released] [--freezes] [-k]" >&2; exit 2 ;;
    esac
done

ADB=(adb)
[ -n "$SERIAL" ] && { ADB=(adb -s "$SERIAL"); export ANDROID_SERIAL="$SERIAL"; }
WORK="${TMPDIR:-/tmp}/swift-pwa-android-deploy-launch${SERIAL:+-$SERIAL}"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device" >&2; exit 1; }
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

# <app name> <crash: 0|1> — scaffolds, deploys from scratch, prints deploy's
# last line.
deploy() {
    local app="$1" crash="$2" pkg
    pkg="com.example.$(echo "$app" | tr '[:upper:]' '[:lower:]')"
    (cd "$WORK" && "$CLI" init "$app" >/dev/null)
    python3 - "$WORK/$app" "$REPO" "$RELEASED" "$crash" <<'PY'
import pathlib, re, sys
app_dir, repo, released, crash = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
if not released:
    manifest = app_dir / "Package.swift"
    text = manifest.read_text()
    text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                          f'.package(path: "{repo}")', text)
    assert count == 1, "the scaffold's package pin moved; this would test the released package"
    text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
    manifest.write_text(text)
if crash:
    app = app_dir / "Sources" / app_dir.name / "App.swift"
    text = app.read_text()
    text, count = re.subn(r'(?m)^    _ = try ctx\.createWindow\(',
                          '    fatalError("deploy-launch probe: crashing in configure")\n\n'
                          '    _ = try ctx.createWindow(', text)
    assert count == 1, "the scaffold's createWindow call moved; this patch needs updating"
    app.write_text(text)
PY
    "${ADB[@]}" uninstall "$pkg" >/dev/null 2>&1 || true
    (cd "$WORK/$app" && "$CLI" deploy --target android --android-abis arm64-v8a >"$WORK/$app.log" 2>&1) \
        || { tail -20 "$WORK/$app.log" >&2; return 1; }
    "${ADB[@]}" shell am force-stop "$pkg" >/dev/null 2>&1 || true
    [ "$KEEP" -eq 1 ] || "${ADB[@]}" uninstall "$pkg" >/dev/null 2>&1 || true
    grep -E "^(Deployed to|Installed on)" "$WORK/$app.log" | tail -1
}

FAILED=0
row() { # <name> <0|1 passed> <detail>
    if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1 ($3)"; FAILED=1; fi
}

echo "== deploying an app that runs =="
runs=$(deploy LaunchRuns 0)
echo "   $runs"
if [ "$FREEZES" -eq 1 ]; then
    [[ "$runs" == *"the app is not running"*"disabled right after it launched"* ]] && r=1 || r=0
    row "1. a device that freezes a new app is reported, freeze named" "$r" "$runs"
else
    [[ "$runs" == "Deployed to "* ]] && r=1 || r=0
    row "1. an app that runs is reported deployed" "$r" "$runs"
fi

echo "== deploying an app that crashes in configure =="
crashes=$(deploy LaunchCrashes 1)
echo "   $crashes"
[[ "$crashes" == *"the app is not running"* ]] && r=1 || r=0
row "2. an app that crashed at launch is reported not running" "$r" "$crashes"

echo
if [ "$FAILED" -eq 0 ]; then echo "PASS: every row held."; else echo "FAIL: see above."; fi
exit "$FAILED"
