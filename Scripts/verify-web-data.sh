#!/usr/bin/env bash
#
# Verify SWIFT_PWA_WEB_DATA=ephemeral on macOS and Linux (#303).
#
# Every launch of an app shares one persistent web data store, so a value one
# test run writes is there in the next, and runs side by side read each other's
# writes. An ephemeral launch has to start empty, keep what it writes for as
# long as it runs, share nothing with another launch, and leave the persistent
# store as it found it. Each row reads and writes both localStorage and
# IndexedDB, which the engines keep in different places:
#
#   1. CONTROL, must hold: a normal launch writes, a second normal launch reads
#      it back. Without it, "ephemeral reads nothing" could mean the probe can't
#      see storage at all.
#   2. Two ephemeral launches in turn: each starts empty, neither sees the
#      control's value or the other's, and each reads back its own write.
#   3. Two ephemeral launches at once: neither sees the other's write.
#   4. A normal launch afterwards still reads the control's value.
#
# A scaffolded app, not an Example (the examples are not the scaffold). Run it
# on the host under test: Scripts/remote-linux.sh syncs the tree for Linux, and
# Scripts/verify-web-data.ps1 is the Windows twin.
#
# Usage: verify-web-data.sh [--gtk4] [--toolchain <ver>] [--repo <dir>] [--released]
#   --released  build against the last release instead of this checkout: the
#               control for the fix, where rows 2 and 3 have to fail
set -euo pipefail

GTK4=0
RELEASED=0
TOOLCHAIN=""
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gtk4) GTK4=1; shift ;;
        --toolchain) TOOLCHAIN="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --released) RELEASED=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
SWIFT=(swift)
if [[ -n "$TOOLCHAIN" ]]; then
    SWIFT=("$HOME/.local/share/swiftly/bin/swiftly" run "+$TOOLCHAIN" swift)
fi
# Presence selects the GTK4 backend, so `=0` is not "off": unset it instead.
if [[ "$GTK4" == 1 ]]; then export SWIFT_PWA_GTK4=1; else unset SWIFT_PWA_GTK4; fi
unset SWIFT_PWA_WEB_DATA

WORK="${TMPDIR:-/tmp}/swift-pwa-web-data"
APP="$WORK/WebDataCheck"
EXE="$APP/.build/debug/WebDataCheck"
PIDS=()
cleanup() { for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

echo "== building the CLI =="
(cd "$REPO" && "${SWIFT[@]}" build --product swift-pwa >/dev/null)
CLI="$REPO/.build/debug/swift-pwa"

rm -rf "$WORK"; mkdir -p "$WORK"
(cd "$WORK" && "$CLI" init WebDataCheck >/dev/null)
if [[ "$RELEASED" == 1 ]]; then
    echo "== scaffolded against the released package =="
else
    echo "== scaffolded against this checkout =="
    python3 - "$APP/Package.swift" "$REPO" <<'PY'
import pathlib, re, sys
manifest, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
text = manifest.read_text()
text, count = re.subn(r'\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)',
                      f'.package(path: "{repo}")', text)
assert count == 1, "the scaffold's package pin moved; this would test the released package"
text = text.replace('package: "swift-pwa"', f'package: "{pathlib.Path(repo).name}"')
manifest.write_text(text)
PY
fi
(cd "$APP" && "${SWIFT[@]}" build >"$WORK/build.log" 2>&1) || { tail -30 "$WORK/build.log"; exit 1; }

# launch <name> <ephemeral 0|1>: starts the app, sets $PORT_<name>, $TOKEN_<name>
# and $PID_<name>.
launch() {
    local name="$1" ephemeral="$2" log="$WORK/$1.log"
    local env=(SWIFT_PWA_DRIVE=0 SWIFT_PWA_WEB_ROOT="$APP/web")
    [[ "$ephemeral" == 1 ]] && env+=(SWIFT_PWA_WEB_DATA=ephemeral)
    if [[ "$(uname)" == Linux ]]; then
        env "${env[@]}" xvfb-run -a "$EXE" >"$log" 2>&1 &
    else
        env "${env[@]}" "$EXE" >"$log" 2>&1 &
    fi
    local pid=$!
    PIDS+=("$pid")
    for _ in $(seq 1 60); do grep -q "driver listening" "$log" && break; sleep 1; done
    local port token
    port=$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$log" | head -1)
    token=$(sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' "$log" | head -1)
    if [[ -z "$port" ]]; then echo "$name never announced a driver port:"; cat "$log"; exit 1; fi
    printf -v "PORT_$name" '%s' "$port"
    printf -v "TOKEN_$name" '%s' "$token"
    printf -v "PID_$name" '%s' "$pid"
}

js() { # <name> <expression>
    local port="PORT_$1" token="TOKEN_$1"
    "$CLI" drive eval --attach "${!port}" --token "${!token}" --timeout 15 "$2" 2>>"$WORK/drive.log"
}

# What the page holds under the probe key, as "<localStorage>/<IndexedDB>".
IDB='new Promise((ok, fail) => {
  const open = indexedDB.open("probe", 1);
  open.onupgradeneeded = () => open.result.createObjectStore("kv");
  open.onerror = () => fail(open.error);
  open.onsuccess = () => ok(open.result);
})'
read_probe() { # <name>
    js "$1" "(async () => {
      const db = await $IDB;
      const idb = await new Promise(ok => {
        const get = db.transaction('kv').objectStore('kv').get('probe');
        get.onsuccess = () => ok(get.result ?? null);
      });
      db.close();
      return (localStorage.getItem('probe') ?? 'null') + '/' + (idb ?? 'null');
    })()" | tr -d '"\n'
}
write_probe() { # <name> <value>
    js "$1" "(async () => {
      localStorage.setItem('probe', '$2');
      const db = await $IDB;
      await new Promise(ok => {
        const tx = db.transaction('kv', 'readwrite');
        tx.objectStore('kv').put('$2', 'probe');
        tx.oncomplete = ok;
      });
      db.close();
      return 'ok';
    })()" >/dev/null
}
# A clean quit, not a kill: WebKit writes localStorage out lazily, and a killed
# control would lose its write and fail for the wrong reason.
quit() { # <name>
    local pid="PID_$1"
    js "$1" "__SWIFT_PWA__.invoke('app.quit'); 'bye'" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do kill -0 "${!pid}" 2>/dev/null || return 0; sleep 0.5; done
    echo "$1 didn't quit; killing it"; kill "${!pid}" 2>/dev/null || true
}

FAILED=0
expect() { # <row> <got> <wanted>
    if [[ "$2" == "$3" ]]; then echo "PASS $1: $2"
    else echo "FAIL $1: got $2, wanted $3"; FAILED=1
    fi
}

echo "== backend: $([[ "$(uname)" == Linux ]] && { [[ "$GTK4" == 1 ]] && echo gtk4 || echo gtk3; } || echo macos) =="

launch control1 0
write_probe control1 persistent
quit control1
launch control2 0
expect "1. control: a normal launch reads the last one's write" "$(read_probe control2)" "persistent/persistent"
quit control2

launch eph1 1
expect "2. ephemeral launch starts empty" "$(read_probe eph1)" "null/null"
write_probe eph1 eph1
expect "2. ephemeral launch reads its own write" "$(read_probe eph1)" "eph1/eph1"
quit eph1
launch eph2 1
expect "2. next ephemeral launch starts empty" "$(read_probe eph2)" "null/null"
quit eph2

launch par1 1
launch par2 1
write_probe par1 par1
expect "3. side by side, the other launch's write isn't visible" "$(read_probe par2)" "null/null"
expect "3. side by side, each keeps its own" "$(read_probe par1)" "par1/par1"
quit par1
quit par2

launch after 0
expect "4. the persistent store is as the control left it" "$(read_probe after)" "persistent/persistent"
# Leave the persistent store empty for the next run's control.
js after "(async () => { localStorage.clear(); indexedDB.deleteDatabase('probe'); return 1 })()" >/dev/null
quit after

echo
if [[ "$FAILED" == 0 ]]; then echo "PASS: every row held."; else echo "FAIL: see above."; fi
exit "$FAILED"
