# On-device testing for the Android backend

How the v0.5.x System\* plugin set was verified end-to-end on a
Samsung Galaxy Tab S10+ (Android 16, arm64). Reproduces the same
loop on any USB-connected Android device. Pairs with
[android-setup.md](android-setup.md) — that doc covers the
build pipeline; this one covers driving the page from the host
once the APK is installed, including round-tripping each
`System*` plugin without touching the device's screen yourself.

The trick that makes this work: `WebView.setWebContentsDebuggingEnabled(true)`
(set automatically in debug builds by the bundler-generated
`MainActivity`) exposes the page over Chrome DevTools Protocol on a
per-process abstract Unix socket. Forward it to localhost via `adb`
and you can drive `__SWIFT_PWA__.invoke(...)` from a host shell.

## 1. Prerequisites

The host needs the same toolchain as a regular Android build (see
[android-setup.md](android-setup.md) §1) plus `adb` and a
`websockets`-capable Python:

```bash
brew install swiftly openjdk@17 python3
swiftly install 6.2.0
swift sdk install <swift-android-sdk-6.2-url> --checksum <sha>
curl -fsSLo /tmp/ndk.zip https://dl.google.com/android/repository/android-ndk-r27d-darwin.zip
unzip /tmp/ndk.zip -d ~/

# adb ships with Android Studio's platform-tools; standalone via sdkmanager
ls ~/Library/Android/sdk/platform-tools/adb
pip3 install websockets
```

The device needs USB debugging enabled:

1. **Settings → About tablet** → tap "Build number" 7× to unlock
   Developer options.
2. **Settings → Developer options → USB debugging** ON.
3. Plug in via USB. The device prompts to authorize the host's
   RSA key; accept it.
4. `adb devices` should show the serial number with state `device`
   (not `unauthorized` / `offline`).

```bash
export PATH=$HOME/Library/Android/sdk/platform-tools:$PATH
adb devices
# List of devices attached
# R52X9006H2T  device
```

## 2. Build → install → launch

```bash
export ANDROID_NDK_HOME=$HOME/android-ndk-r27d
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$ANDROID_HOME/platform-tools:$PATH

cd Examples/HelloPWA
rm -rf build/HelloPWA-android
swiftly run +6.2.0 swift run --package-path ../.. swift-pwa build \
  --target android --cross-compile-android --android-abis arm64-v8a
cd build/HelloPWA-android
./gradlew --no-daemon assembleDebug

APK=app/build/outputs/apk/debug/app-debug.apk
adb install -r "$APK"
adb shell am force-stop com.swiftpwa.hello   # clean slate; safe even if not running
adb logcat -c                                 # clear ring buffer for the launch
adb shell am start -n com.swiftpwa.hello/.MainActivity
sleep 4
adb logcat -d "swift-pwa:I" "AndroidRuntime:E" "*:F"
```

A clean launch shows three INFO lines under tag `swift-pwa`:

```
swift-pwa: bridge attached
swift-pwa: entry: swiftPwaMain enter
swift-pwa: loadUrl: https://swift-pwa.local/web/index.html
```

Any `FATAL EXCEPTION: main` from `AndroidRuntime:E` is a hard
launch failure — common ones are documented in
[android-setup.md](android-setup.md) §8.

## 3. Hooking up Chrome DevTools Protocol

The WebView's CDP endpoint lives on a per-process abstract socket
named `webview_devtools_remote_<pid>`. Forward it to localhost:

```bash
PID=$(adb shell pidof com.swiftpwa.hello)
adb forward tcp:9222 localabstract:webview_devtools_remote_$PID
```

> **The PID changes every launch.** Re-run the `adb forward` line
> after each `am force-stop` + `am start`. There's no "follow the
> app" mode — abstract sockets are bound to the process at
> creation, and a new launch creates a new socket.

The page's WebSocket URL comes out of the `/json` endpoint:

```bash
curl -s http://localhost:9222/json | python3 -c \
  "import json,sys; print([p['webSocketDebuggerUrl'] for p in json.load(sys.stdin) if p.get('type')=='page'][0])"
# → ws://localhost:9222/devtools/page/<id>
```

A short Python helper opens the WebSocket, sends a single
`Runtime.evaluate`, and prints the result. Save as
`/tmp/cdp_eval.py`:

```python
import json, sys
from websockets.sync.client import connect

ws_url, expr = sys.argv[1], sys.argv[2]
with connect(ws_url) as ws:
    ws.send(json.dumps({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {"expression": expr, "awaitPromise": True, "returnByValue": True}
    }))
    r = json.loads(ws.recv()).get("result", {}).get("result", {})
    print(json.dumps(r.get("value", r)))
```

Usage:

```bash
WS=$(curl -s http://localhost:9222/json | python3 -c \
  "import json,sys; print([p['webSocketDebuggerUrl'] for p in json.load(sys.stdin) if p.get('type')=='page'][0])")
python3 /tmp/cdp_eval.py "$WS" "1 + 2"   # → 3
```

## 4. Round-tripping each plugin

`__platform.info` lists every command the runtime registered —
this is the first call to make. If a plugin doesn't show up here,
the JS-side `__SWIFT_PWA__.invoke('<command>', ...)` will reject
with "command not registered" rather than reach Swift.

```bash
python3 /tmp/cdp_eval.py "$WS" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('__platform.info', {})))()"
# → "{\"os\":\"android\",\"tempDir\":\"...\",\"commands\":[\"biometric.authenticate\",\"biometric.canAuthenticate\",\"clipboard.clear\",\"clipboard.readText\",\"clipboard.writeText\",\"dialog.confirm\",\"dialog.message\",...]}"
```

### 4.1. Sync plugins (clipboard, biometric status, notification auth)

These resolve immediately — no native UI to drive:

```bash
# Clipboard write/read round-trip
python3 /tmp/cdp_eval.py "$WS" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('clipboard.writeText', {text: 'hello'})))()"
python3 /tmp/cdp_eval.py "$WS" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('clipboard.readText', {})))()"
# → "{\"text\":\"hello\"}"

# Biometric availability
python3 /tmp/cdp_eval.py "$WS" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('biometric.canAuthenticate', {})))()"
# → "{\"available\":true,\"kind\":\"unknown\"}"

# Notification authorization (API 33+ shows a system prompt the first time)
python3 /tmp/cdp_eval.py "$WS" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('notifications.requestAuthorization', {})))()"
# → "{\"granted\":true}"

# Send a notification (visible in the system shade)
python3 /tmp/cdp_eval.py "$WS" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('notifications.send', {title: 'swift-pwa', body: 'hi', sound: false})))()"
# → "{\"id\":\"95937348\"}"
```

### 4.2. Interactive plugins (dialog, biometric, file picker)

These suspend the JS-side promise until the user resolves a
native UI element. Pattern: fire-and-forget the invoke into a
`window` slot, drive the native UI separately, then read the
slot back:

```bash
# 1. Fire — promise sits pending, the result will land in window._dlg
python3 /tmp/cdp_eval.py "$WS" \
  "(()=>{__SWIFT_PWA__.invoke('dialog.confirm', {message: 'Tap YES', okLabel: 'Yes', cancelLabel: 'No'}).then(r=>window._dlg=JSON.stringify(r)); return 'pending';})()"

# 2. Drive the native UI (see §5)
adb shell input tap 1838 826   # YES button on a 2800x1752 landscape

# 3. Read the resolved result
python3 /tmp/cdp_eval.py "$WS" "window._dlg || 'still pending'"
# → "{\"ok\":true}"
```

The same pattern works for `dialog.openFile` (SAF Documents UI),
`dialog.saveFile`, `dialog.openDirectory`, and
`biometric.authenticate`.

## 5. Tapping native UI

Native dialogs / SAF pickers / the BiometricPrompt aren't part of
the WebView, so CDP can't reach them. Drive via `adb`:

```bash
# Native pixel size (the system UI's coordinate space)
adb shell wm size                    # → "Physical size: 2800x1752"

# Screenshot at native resolution
adb shell screencap -p > /tmp/shot.png

# Tap by absolute device coordinates
adb shell input tap <x> <y>

# Send keys
adb shell input keyevent KEYCODE_DPAD_RIGHT
adb shell input keyevent KEYCODE_ENTER
adb shell input keyevent KEYCODE_BACK    # ⚠ exits the app if no modal is open
```

Strategy that worked: take a `screencap` after the dialog appears,
locate the target button visually, multiply by the
screen-to-screencap ratio if the screencap arrived downscaled,
then `input tap`.

> **Don't tap blind.** AlertDialog button positions vary by theme
> and tablet vs phone; SAF picker layouts shift between OEMs. Take
> the screencap, find the target, then tap.

## 6. Verifying side effects outside the page

Some plugin effects don't show up in JS — they touch the system.
Direct probes:

```bash
# Notifications: the system's record (more reliable than a shade screenshot)
adb shell dumpsys notification --noredact | grep -A2 com.swiftpwa.hello
# → reports id, channel (swift-pwa.default), flags=AUTO_CANCEL|SILENT, etc.

# Pull notification shade visually
adb shell cmd statusbar expand-notifications
adb shell screencap -p > /tmp/notif.png
adb shell cmd statusbar collapse

# Activity lifecycle state
adb shell dumpsys activity activities | grep -E 'mResumedActivity|com.swiftpwa.hello'
# → topResumedActivity=ActivityRecord{... com.swiftpwa.hello/.MainActivity ...}

# Clipboard (primary clip — what `ClipboardManager.getPrimaryClip()` returns)
adb shell cmd clipboard get-primary
# (some OEM builds restrict this to the foreground app; reading via
# clipboard.readText through the bridge is the more reliable check)
```

## 7. Things that bit me during v0.5.x bring-up

These are the failure modes that cost real time. Most are flagged
by clear log lines once you know what to look for.

- **`adb forward` socket name uses the PID.** Re-run the forward
  after every `am force-stop` + `am start`. A pre-existing forward
  to a dead PID returns connection-refused on the next `curl
  http://localhost:9222/json` — looks like the device went away
  but actually you're forwarding to a stale socket.

- **`KEYCODE_BACK` exits the app** if no modal is open. The first
  time I sent BACK to dismiss what I thought was a stuck dialog,
  the app went to home and the next `adb shell screencap` showed
  the launcher. `am start -n com.swiftpwa.hello/.MainActivity`
  brings it back; `adb forward` needs to be re-run because the
  PID changed.

- **Biometric prompt blanks `screencap`.** Android's secure-overlay
  protection blocks screenshots over `BiometricPrompt`. The black
  screen is the *right* behaviour, not a bug. Verify the round-trip
  by reading the JS-side promise resolution instead of looking at
  the pixels.

- **`Theme.AppCompat` is required** when the host Activity extends
  `AppCompatActivity` (which it does in v0.5.x — needed for
  `BiometricPrompt` and SAF launcher attachment). Missing it
  surfaces as `IllegalStateException: You need to use a
  Theme.AppCompat theme (or descendant) with this activity` from
  the first `setContentView` call. The v0.5.x bundler sets
  `android:theme="@style/Theme.AppCompat.Light.NoActionBar"` on
  `<application>` automatically; subclassing the generated
  Activity with a non-AppCompat theme breaks this.

- **`POST_NOTIFICATIONS` is API 33+ runtime.** On a clean install,
  the first `notifications.send` call without
  `notifications.requestAuthorization` having run first returns
  the right id but the system silently drops the notification.
  Calling `requestAuthorization` once on launch (or just before
  the first `send`) triggers the system prompt and persists the
  user's answer.

- **SAF returns `content://` URIs, not paths.** `dialog.openFile`
  resolves to a string that looks like
  `content://com.android.providers.media.documents/document/image%3A1000000058`
  — that's the platform contract, not a bug. Apps that need bytes
  resolve via `ContentResolver` (Android-side) — see
  [android-setup.md](android-setup.md) §6.1's `SystemDialog` row.

- **`/usr/bin/strip` on macOS is Mach-O only.** Calling it on an
  ELF `.so` exits non-zero with no useful output. The bundler
  uses `llvm-strip` from the NDK explicitly to avoid this; if you
  drop into the staged jniLibs directory and run a manual strip,
  use
  `$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/<host>/bin/llvm-strip`,
  not the system `strip`.
