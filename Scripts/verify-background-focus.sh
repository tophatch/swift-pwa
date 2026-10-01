#!/usr/bin/env bash
#
# Check that a backgrounded driven run (`SWIFT_PWA_DRIVE_BACKGROUND=1`, #208)
# never takes the front on macOS — including when the process that launched it
# is frontmost, which is a suite started from an editor's terminal (#283).
#
# AppKit activates a launching app that already has a window ordered in when it
# finishes launching, whatever its activation policy. That only shows when the
# *parent* is frontmost, so this runs a launcher (background-focus-probe/
# launcher.swift) that makes itself frontmost first, then launches the app and
# polls `NSWorkspace.frontmostApplication` for the child's pid.
#
# Two controls, both of which must hold or the run proves nothing:
#   1. The launcher became frontmost (a locked screen or no GUI session can't
#      — the run stops there).
#   2. The same app launched *without* the variable does take the front, and
#      the backgrounded one put a window up — so "never frontmost" means
#      something.
#
# Runs against a fresh `swift-pwa init` app repointed at this checkout: a
# startup change verified only against an example can still be broken for every
# adopter.
#
# Usage:
#   Scripts/verify-background-focus.sh [--app-dir <dir>] [--runs <n>] [--seconds <s>]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""
RUNS=3
SECONDS_PER_RUN=3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-dir) APP_DIR="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --seconds) SECONDS_PER_RUN="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || { echo "macOS only: the other backends never activate on map"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[[ -n "$APP_DIR" ]] || APP_DIR="$WORK/BackgroundFocusProbe"
CLI="$REPO/.build/debug/swift-pwa"

echo "→ building the CLI"
(cd "$REPO" && swift build --product swift-pwa) >/dev/null 2>&1 || {
    echo "::error::couldn't build swift-pwa"; exit 1; }

if [[ ! -d "$APP_DIR" ]]; then
    echo "→ scaffolding a probe app in $APP_DIR"
    mkdir -p "$(dirname "$APP_DIR")"
    (cd "$(dirname "$APP_DIR")" && "$CLI" init "$(basename "$APP_DIR")") >/dev/null || {
        echo "::error::swift-pwa init failed"; exit 1; }
fi

# `swift-pwa init` pins the released package; point it at this checkout.
python3 - "$APP_DIR/Package.swift" "$REPO" <<'PY'
import re, sys
path, repo = sys.argv[1], sys.argv[2]
source = open(path).read()
patched = re.sub(r'\.package\(url: "[^"]*swift-pwa"[^)]*\)', f'.package(path: "{repo}")', source)
if patched != source:
    open(path, "w").write(patched)
PY

echo "→ building the probe app"
(cd "$APP_DIR" && swift build) >/dev/null 2>&1 || {
    echo "::error::the probe app didn't build"; (cd "$APP_DIR" && swift build 2>&1 | tail -20); exit 1; }
BINARY="$(cd "$APP_DIR" && swift build --show-bin-path)/$(basename "$APP_DIR")"

echo "→ building the launcher"
swiftc -O -o "$WORK/launcher" "$REPO/Scripts/background-focus-probe/launcher.swift" || {
    echo "::error::the launcher didn't build"; exit 1; }

PASS=0; FAIL=0
# A bare SwiftPM binary has no staged web/, so point it at the source one the
# way `swift-pwa drive` does.
run() { SWIFT_PWA_WEB_ROOT="$APP_DIR/web" "$WORK/launcher" "$BINARY" "$SECONDS_PER_RUN" "$1"; }

OUT="$(run 0)"; STATUS=$?
if [[ $STATUS == 3 ]]; then
    echo "::error::the launcher couldn't become frontmost — is the screen locked, or is there no GUI session?"
    exit 1
fi
if [[ "$OUT" != *"child_frontmost=true"* ]]; then
    echo "::error::control failed: launched normally, the app never took the front ($OUT)."
    echo "        Without that, a backgrounded run that never takes it proves nothing."
    exit 1
fi
echo "  ok    control: launched normally, the app takes the front ($OUT)"

for i in $(seq 1 "$RUNS"); do
    OUT="$(run 1)"
    if [[ "$OUT" != *"child_window=true"* ]]; then
        echo "  FAIL  backgrounded run $i: the app never ordered a window in ($OUT)"; FAIL=$((FAIL+1))
    elif [[ "$OUT" == *"child_frontmost=true"* ]]; then
        echo "  FAIL  backgrounded run $i: the app took the front ($OUT)"; FAIL=$((FAIL+1))
    else
        echo "  PASS  backgrounded run $i: window ordered in, never frontmost"; PASS=$((PASS+1))
    fi
done

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
