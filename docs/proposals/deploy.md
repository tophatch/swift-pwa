# swift-pwa feedback / handoff

Notes from packaging **App** with swift-pwa. Untracked scratch — a running list
of asks and papercuts for the swift-pwa maintainers, written from a real consumer's build.

Environment: macOS host, swift-pwa CLI **0.9.2**, Swift 6.2 Android SDK, NDK r27d, JDK 17.
Target device: Galaxy Tab S10+ (Android 16, arm64) over wireless adb.

---

## Feature request: a `deploy` command

Today, getting a build onto a device is `build` + three by-hand steps. We just scripted it
(`scripts/deploy-android.sh` in this repo) — the fact that a ~90-line wrapper is worth keeping is
the signal. It'd be a natural first-class CLI verb, a sibling to `build`.

**Proposed:** `swift-pwa deploy --target <platform> [--device <serial|ip:port>] [flags]`

= `build` → package/assemble → install → launch, in one step, per platform:

- **android**: `--cross-compile-android` build → `gradlew assembleDebug` → `adb install -r` → `am start -n <pkg>/.MainActivity -W`
- **macos**: `build` → `open build/<Name>.app`
- **ios**: `build` → `xcrun devicectl device install` (or simulator) → launch
- **linux/windows**: `build` → run the produced binary (or no-op with a note)

### Particulars we'd want

1. **Wireless-adb auto-connect.** When `--device` looks like `ip:port`, run `adb connect` first.
   Ours rotates the port per session, so this is the daily friction point.
2. **Device selection = adb's own rules.** Sole connected device by default; honor `--device` /
   `ANDROID_SERIAL`; clear error (not a silent pick) when several are attached and none is chosen.
   We had 3 devices attached and had to hand-pass the serial to every `adb` call.
3. **`--launch` / `--no-launch`** and **`--no-build`** (install the already-built artifact — the
   fast path when only re-testing an install), plus **`--reinstall`/`-r`** semantics by default.
4. **Fold the cross-compile toolchain discovery into the CLI.** Right now we must
   `export TOOLCHAINS=<6.2 xctoolchain bundle id>` by hand so the cross-compiler matches the
   Android SDK's Swift exactly. The CLI already knows it's targeting the 6.2 Android SDK — it
   could discover/select the matching xctoolchain itself (our script greps the Info.plist
   `CFBundleIdentifier` as a stopgap). A wrong/omitted `TOOLCHAINS` fails deep in the build with
   a non-obvious error.
5. **Reuse `doctor`'s preflight** so a missing NDK/JDK/adb fails fast with the same message.

Even shipping `deploy` for android alone would remove the most error-prone part of our loop.

---

## Papercut: no `web.directory` exclude → giant bundles

The bundler copies `web.directory` **wholesale** into the app (documented, intentional — no
staging step). But with real media that gets extreme fast: App's `web/` is **2.2 GB**
(`web/packs` 1.4 GB of bundled roster-pack art + `web/assets/staff` 657 MB), so the **debug APK is
2.3 GB**. It installs and runs fine (device had space), but the sideload is multi-minute and every
build re-copies the lot.

**Asks (either would help):**
- An **`exclude` glob** (or `.swiftpwaignore`) under `web` in `pwa.json`, so heavy/optional assets
  (e.g. packs, hi-res art) can be left out of a given build.
- Or an **on-demand / split-asset** story for Android (install-time asset packs, or serve select
  dirs from app data like the existing `/packs` mount) so the base app stays lean.

This is worth raising independently of `deploy` — it's the single biggest cost in our native loop,
and it silently scales with content.

---

## Working well (for balance)

- `--cross-compile-android` staging + stripping the runtime `.so`s in one step (130 MB → 74 MB
  jniLibs) — no by-hand runtime-lib copy, as promised in the 0.7.2 notes.
- `window.background_color` now painting the Android windowBackground/statusBar/WebView (0.7.7/0.7.8)
  without breaking the web app's `prefers-color-scheme`. Clean dark launch.
- Native bridge fully live on Android (Quit to Desktop, dialog export, pack import all work).

## Deploy Script Reference

```bash
#!/usr/bin/env bash
#
# deploy-android.sh — build the native Android app and put it on a device, in one command.
#
# Wraps the full PACKAGING.md Android flow: refresh the pack index → cross-compile the Swift
# shell (arm64) → assemble the debug APK → install → launch. For web-layer work use
# scripts/tab-serve.sh (live-reload in Chrome, no rebuild); reach for this only when you need
# the real WebView/native-bridge/packaging behavior on-device.
#
# Prereqs (this machine): the Android toolchain wired by ~/Code-3p/android-env.sh (ANDROID_HOME,
# NDK, JAVA_HOME), the Swift 6.2 Android SDK, a 6.2 xctoolchain, `swift-pwa`, and `adb` — see
# docs/PACKAGING.md "Android (on-device via adb)".
#
# Usage:
#   bash scripts/deploy-android.sh [serial]                 # full build + install + launch
#   bash scripts/deploy-android.sh --connect <ip:port>      # adb-connect a wireless device first
#   bash scripts/deploy-android.sh --no-build [serial]      # skip the build; install the last APK
#   bash scripts/deploy-android.sh --build-only             # build the APK, don't touch a device
#
#   serial is optional; if omitted, the sole connected device is used, or a tablet-looking one is
#   picked when several are attached (override with the TAB_SERIAL env var). A --connect target is
#   used as the serial automatically.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_SH="${ANDROID_ENV_SH:-$HOME/Code-3p/android-env.sh}"
ABIS="${ANDROID_ABIS:-arm64-v8a}"
APK="$ROOT/build/App-android/app/build/outputs/apk/debug/app-debug.apk"
APP="com.example.app"
ACTIVITY="$APP/.MainActivity"

DO_BUILD=1 DO_INSTALL=1 CONNECT="" SERIAL=""
while (( $# )); do
  case "$1" in
    --connect) CONNECT="${2:?--connect needs <ip:port>}"; SERIAL="$CONNECT"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --build-only) DO_INSTALL=0; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) SERIAL="$1"; shift ;;
  esac
done
SERIAL="${SERIAL:-${TAB_SERIAL:-}}"

# The Android SDK/NDK/JDK env lives outside PATH — source it (idempotent) before any tool runs.
[[ -f "$ENV_SH" ]] && source "$ENV_SH" || { echo "missing $ENV_SH (set ANDROID_ENV_SH)" >&2; exit 1; }

if (( DO_BUILD )); then
  # The cross-compiler must match the Android SDK's Swift exactly — discover the 6.2 xctoolchain's
  # bundle id rather than hardcode it (it changes per snapshot).
  TC_PLIST="$(ls -d "$HOME"/Library/Developer/Toolchains/swift-6.2-RELEASE*.xctoolchain/Info.plist 2>/dev/null | head -1 || true)"
  if [[ -n "$TC_PLIST" ]]; then
    export TOOLCHAINS="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TC_PLIST")"
    echo "→ cross-compile toolchain: $TOOLCHAINS"
  else
    echo "warning: no swift-6.2-RELEASE*.xctoolchain found; relying on TOOLCHAINS=${TOOLCHAINS:-unset}" >&2
  fi

  echo "→ prepack: refreshing the content-pack index"
  node "$ROOT/scripts/build-packs-index.mjs"

  echo "→ cross-compiling the Android shell ($ABIS)"
  ( cd "$ROOT" && swift-pwa build --target android --cross-compile-android --android-abis "$ABIS" )

  echo "→ assembling the debug APK"
  ( cd "$ROOT/build/App-android" && ./gradlew assembleDebug )
fi

[[ -f "$APK" ]] || { echo "APK not found: $APK (run without --no-build)" >&2; exit 1; }
echo "→ APK: $APK ($(du -h "$APK" | cut -f1))"

(( DO_INSTALL )) || { echo "built (--build-only); skipping install."; exit 0; }

# Wireless devices need an explicit connect; a passed serial that isn't listed gets one attempt.
[[ -n "$CONNECT" ]] && adb connect "$CONNECT" >/dev/null

pick_serial() {
  [[ -n "$SERIAL" ]] && { echo "$SERIAL"; return; }
  local serials=() s
  while read -r s _; do [[ -n "$s" ]] && serials+=("$s"); done < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
  (( ${#serials[@]} == 0 )) && { echo "no adb device attached (pass a serial or --connect <ip:port>)" >&2; exit 1; }
  (( ${#serials[@]} == 1 )) && { echo "${serials[0]}"; return; }
  for s in "${serials[@]}"; do [[ "$s" == *:* ]] && { echo "$s"; return; }; done   # prefer a wireless/tablet-looking one
  echo "${serials[0]}"
}
SERIAL="$(pick_serial)"
echo "→ installing to $SERIAL (large asset bundle — this can take a few minutes over wifi)"
adb -s "$SERIAL" install -r "$APK"

echo "→ launching"
adb -s "$SERIAL" shell am start -n "$ACTIVITY" -W
echo "done."
```