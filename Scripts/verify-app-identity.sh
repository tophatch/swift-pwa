#!/usr/bin/env bash
#
# What an app is *called* at runtime, and so where `app.documentsDir` puts the
# user's files (#254).
#
# The reported failure: the same app answered `AetherReader` under
# `swift-pwa drive` and `Aether Reader` once bundled, because an unbundled
# binary has nothing but its executable name to go on — and a SwiftPM target
# name can't contain a space. `documentsDir` is derived from that name, so a
# development run created an empty `~/Documents/AetherReader` beside the user's
# real `~/Documents/Aether Reader`, adopted it, and showed an empty library.
# (The probe below uses a name of its own — see TARGET.)
#
# Three legs, and the middle one is the control that gives the other two their
# meaning:
#
#   1. driven      `swift-pwa drive` passes pwa.json's name through the
#                  environment → the manifest name.
#   2. bare        the same binary launched with nothing set → the executable
#                  name. This is the *unfixed* behaviour, asserted on purpose:
#                  it is what a Linux or Windows app still gets when it is run
#                  outside the tooling, and it proves leg 1 measured the
#                  override rather than something baked in.
#   3. bundled     a debug `.app` — an Info.plist, and the driver compiled in,
#                  so the bundled answer can be measured rather than inferred.
#                  macOS only; no other platform this project targets gives an
#                  unbundled binary a manifest to read.
#   4. declared    `AppPlugin.setDisplayName` from `configure`, which is what
#                  docs/javascript-api.md tells a Linux or Windows app to do —
#                  those two never get an Info.plist, so a *shipped* binary
#                  there still answers its executable name.
#
# Usage: verify-app-identity.sh [--repo <dir>] [--keep]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

WORK="${TMPDIR:-/tmp}/swift-pwa-app-identity"
# Deliberately a name no real app has: the probe asks for `documentsDir`, which
# creates the folder in the *user's* Documents, and the cleanup below removes it.
# Naming it after a real app would put that cleanup next to someone's library.
TARGET="SwiftPWAIdentityProbe"        # the SwiftPM target: no space is possible
DISPLAY_NAME="SwiftPWA Identity Probe" # what pwa.json calls it, with the space
APP="$WORK/$TARGET"
CLI="$REPO/.build/debug/swift-pwa"

cleanup() {
    [[ -n "${PID:-}" ]] && kill "$PID" 2>/dev/null
    [[ "$KEEP" -eq 1 ]] || rm -rf "$WORK"
    # The probe asks for documentsDir, which *creates* the folder — in the real
    # Documents directory, where a person can see it. Remove both names, but
    # only while empty, so a same-named folder of someone's own survives.
    for leaf in "$DISPLAY_NAME" "$TARGET"; do
        rmdir "$HOME/Documents/$leaf" 2>/dev/null || true
    done
    return 0
}
trap cleanup EXIT

echo "== building the CLI =="
(cd "$REPO" && swift build --product swift-pwa >/dev/null)

echo "== scaffolding $TARGET, renamed to \"$DISPLAY_NAME\" in pwa.json =="
rm -rf "$WORK"; mkdir -p "$WORK"
(cd "$WORK" && "$CLI" init "$TARGET" >/dev/null)
cd "$APP"
sed -i.bak -e 's|\.package(url: "https://github.com/tophatch/swift-pwa", from: "[^"]*")|.package(path: "'"$REPO"'")|' Package.swift
rm -f Package.swift.bak
python3 - "$DISPLAY_NAME" <<'PY'
import json, sys, pathlib
p = pathlib.Path("pwa.json")
m = json.loads(p.read_text())
m["name"] = sys.argv[1]
p.write_text(json.dumps(m, indent=2) + "\n")
PY
cp "$REPO/Package.resolved" Package.resolved 2>/dev/null || true

# Leg 4's subject: the app naming itself, the way an installed Linux or Windows
# app has to. Behind an env var so one binary serves both legs.
cat > "Sources/$TARGET/Probe.swift" <<SWIFT
import Foundation
import SwiftPWA

func installDeclaredName() {
    if ProcessInfo.processInfo.environment["PROBE_DECLARES_NAME"] == "1" {
        AppPlugin.setDisplayName("$DISPLAY_NAME")
    }
}
SWIFT
python3 - <<'PY'
import pathlib, re
path = pathlib.Path("Sources").glob("*/App.swift")
src_path = next(path)
src = src_path.read_text()
marker = "func configure(_ ctx: any AppContext) throws {\n"
assert marker in src, "the scaffold's configure function moved; this patch needs updating"
if "installDeclaredName" not in src:
    src = src.replace(marker, marker + "            installDeclaredName()\n", 1)
    src_path.write_text(src)
PY

# The page reports what the runtime believes, for whichever launch is running.
cat > web/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>app identity</title>
<body style="font:14px system-ui;padding:24px">checking…</body>
HTML

echo "== building the app =="
swift build >/dev/null 2>"$WORK/build.err" || { tail -20 "$WORK/build.err" >&2; exit 1; }

FAILED=0
# A GUI app needs a display. On a headless Linux box that means Xvfb — which
# also has to wrap `drive`, since `drive` launches the app itself.
HEADLESS=()
if [[ "$(uname)" != "Darwin" && -z "${DISPLAY:-}" ]] && command -v xvfb-run >/dev/null; then
    HEADLESS=(xvfb-run -a)
fi
# Ask a running app who it thinks it is. `drive eval` returns JSON *inside*
# JSON, so the fields arrive backslash-escaped — read them with python rather
# than pattern-matching the string.
IDENTITY_JS="
    (async () => {
      const name = await __SWIFT_PWA__.invoke('app.name');
      const docs = await __SWIFT_PWA__.invoke('app.documentsDir');
      return JSON.stringify({ name: name.value, docs: docs.path });
    })()"

# `drive eval` returns JSON *inside* JSON, so the object arrives backslash-
# escaped — unwrap it rather than pattern-matching the string, which is a
# mistake this project has already paid for three times.
decode() { python3 -c '
import json, sys
# `drive` narrates its build on stdout; the result is the last line.
value = sys.stdin.read().strip().splitlines()[-1].strip()
for _ in range(4):
    if isinstance(value, dict): break
    try: value = json.loads(value)
    except Exception: break
if not isinstance(value, dict):
    sys.exit("could not decode: " + repr(value))
print(value["name"] + "\t" + value["docs"])'; }

identity_from() { # port token log
    local raw
    # 90s, not a few: an Xvfb-hosted WebKitGTK window can take most of a minute
    # to reach `readyState === "complete"` on a cold GPU-less box.
    if ! raw=$("$CLI" drive eval --attach "$1" --token "$2" --timeout 90 "$IDENTITY_JS" 2>"$WORK/eval.err"); then
        echo "drive eval failed:" >&2; tail -5 "$WORK/eval.err" >&2
        echo "the app said:" >&2; tail -10 "${3:-/dev/null}" >&2
        return 1
    fi
    printf '%s' "$raw" | decode
}

check() { # label actual-name actual-docs expected-name
    local label="$1" name="$2" docs="$3" want="$4"
    if [[ "$name" == "$want" && "$(basename "$docs")" == "$want" ]]; then
        printf 'PASS  %-38s name=%-16s documentsDir=%s\n' "$label" "\"$name\"" "$docs"
    else
        printf 'FAIL  %-38s name=%-16s documentsDir=%s   (wanted %s)\n' \
            "$label" "\"$name\"" "$docs" "\"$want\""
        FAILED=1
    fi
}

# Launch a binary with the driver on, wait for its handshake, and answer with
# "port token". Everything the app writes lands in $LOG.
launch_and_wait() { # binary log [env assignments…]
    local binary="$1" log="$2"; shift 2
    rm -f "$log"
    # `${a[@]}` on an empty array is an unbound-variable error under `set -u`.
    env "$@" SWIFT_PWA_DRIVE=0 ${HEADLESS[@]+"${HEADLESS[@]}"} "$binary" > "$log" 2>&1 &
    # This function is called through `< <(…)`, so it runs in a subshell and
    # can't hand the pid back in a variable.
    echo $! > "$WORK/app.pid"
    for _ in $(seq 1 60); do grep -q "driver listening" "$log" 2>/dev/null && break; sleep 1; done
    local port token
    port=$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$log" | head -1)
    token=$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' "$log" | head -1)
    if [[ -z "$port" ]]; then
        echo "the app never announced a driver port:" >&2; cat "$log" >&2; exit 1
    fi
    echo "$port $token"
}

echo
echo "-- 1. driven: swift-pwa drive, which passes pwa.json's name --"
OUT=$(${HEADLESS[@]+"${HEADLESS[@]}"} "$CLI" drive eval --timeout 180 "$IDENTITY_JS" 2>"$WORK/drive.err") \
    || { tail -20 "$WORK/drive.err" >&2; exit 1; }
IFS=$'\t' read -r NAME DOCS < <(printf '%s' "$OUT" | decode)
check "driven (drive)" "$NAME" "$DOCS" "$DISPLAY_NAME"

echo
echo "-- 2. bare: the same binary, nothing set (the control) --"
read -r PORT TOKEN < <(launch_and_wait "$APP/.build/debug/$TARGET" "$WORK/bare.log" \
    "SWIFT_PWA_WEB_ROOT=$APP/web")
PID=$(cat "$WORK/app.pid")
IFS=$'\t' read -r NAME DOCS < <(identity_from "$PORT" "$TOKEN" "$WORK/bare.log")
kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
check "bare binary (no manifest reaches it)" "$NAME" "$DOCS" "$TARGET"

if [[ "$(uname)" == "Darwin" ]]; then
    echo
    echo "-- 3. bundled: a debug .app, which has an Info.plist --"
    "$CLI" build --target macos --configuration debug >/dev/null 2>"$WORK/bundle.err" \
        || { tail -20 "$WORK/bundle.err" >&2; exit 1; }
    BUNDLE="$APP/build/macos/$DISPLAY_NAME.app/Contents/MacOS/$TARGET"
    [[ -x "$BUNDLE" ]] || { echo "no bundled binary at $BUNDLE" >&2; exit 1; }
    read -r PORT TOKEN < <(launch_and_wait "$BUNDLE" "$WORK/bundled.log")
    PID=$(cat "$WORK/app.pid")
    IFS=$'\t' read -r NAME DOCS < <(identity_from "$PORT" "$TOKEN" "$WORK/bundled.log")
    kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
    check "bundled .app (Info.plist)" "$NAME" "$DOCS" "$DISPLAY_NAME"
else
    echo
    echo "SKIP  bundled .app — macOS only"
fi

echo
echo "-- 4. declared: AppPlugin.setDisplayName from configure --"
read -r PORT TOKEN < <(launch_and_wait "$APP/.build/debug/$TARGET" "$WORK/declared.log" \
    "SWIFT_PWA_WEB_ROOT=$APP/web" "PROBE_DECLARES_NAME=1")
PID=$(cat "$WORK/app.pid")
IFS=$'\t' read -r NAME DOCS < <(identity_from "$PORT" "$TOKEN" "$WORK/declared.log")
kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
check "app declares its own name" "$NAME" "$DOCS" "$DISPLAY_NAME"

echo
if [[ "$FAILED" == 0 ]]; then
    echo "A driven run and a bundled app agree on the name, and so on the user's folder."
else
    echo "Legs disagree — see above."
fi
exit "$FAILED"
