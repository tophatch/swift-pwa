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
[android-setup.md](android-setup.md) §1), plus `adb` and Python 3:

The Swift release is whichever the Android SDK bundle you install names —
there is no project-wide pin ([android-setup.md §There is no project-wide Swift
version](android-setup.md#there-is-no-project-wide-swift-version)), so install
the SDK first and match the toolchain to it:

```bash
brew install swiftly openjdk@17 python3
swift sdk install <swift-android-sdk-url> --checksum <sha>
swiftly install <the release that SDK names, exact patch>
curl -fsSLo /tmp/ndk.zip https://dl.google.com/android/repository/android-ndk-r27d-darwin.zip
unzip /tmp/ndk.zip -d ~/

# adb ships with Android Studio's platform-tools; standalone via sdkmanager
ls ~/Library/Android/sdk/platform-tools/adb
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
rm -rf build/android/HelloPWA-android
swiftly run +6.2.0 swift run --package-path ../.. swift-pwa build \
  --target android --cross-compile-android --android-abis arm64-v8a
cd build/android/HelloPWA-android
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
swift-pwa: loadUrl: https://swift-pwa.local/index.html
```

Any `FATAL EXCEPTION: main` from `AndroidRuntime:E` is a hard
launch failure — common ones are documented in
[android-setup.md](android-setup.md) §8.

## 3. Hooking up Chrome DevTools Protocol

The WebView's CDP endpoint lives on a per-process abstract socket
named `webview_devtools_remote_<pid>`. `Scripts/android-cdp-eval.py`
does the whole dance — find the process, forward the socket, discover
the page target, evaluate — so a verification run is one command:

```bash
Scripts/android-cdp-eval.py com.swiftpwa.hello '1 + 1'      # → 2
Scripts/android-cdp-eval.py com.swiftpwa.hello \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('__platform.info')))()"
```

Several expressions run in order against one connection, which is what
you want when a command's effect is only visible to the next call.
`-s <serial>` picks a device, `--timeout 0` waits forever. Stdlib only,
WebSocket framing included — nothing to `pip install`.

> **The PID changes every launch**, so the script re-establishes the
> forward every run rather than assuming one. Abstract sockets are
> bound to the process at creation; there is no "follow the app" mode.

> **Each `swift-pwa drive eval` launches a fresh app instance** and
> tears it down, so state set by one call is gone by the next. CDP
> here does *not* work that way — it attaches to the running app — but
> the distinction matters when comparing the two: a "still pending"
> read from a second `drive eval` is a *new process*, not an
> unfinished promise.

A timeout is itself a measurement: **no reply to `Runtime.evaluate`
means a modal dialog is holding the JS thread**, which is how you
prove a native prompt (a JS `alert()`, a biometric sheet) actually
blocks the page. Read the dialog's own text with
`adb shell uiautomator dump` + `adb pull` — the view hierarchy names
every button, and it works when `adb exec-out screencap` doesn't.

> **Don't reach for a screenshot to read a native prompt** — see §6
> for why a biometric sheet comes back black, and on a multi-display
> device `adb exec-out screencap -p` prepends a warning to
> the PNG bytes, so the file isn't even a PNG.

## 4. Round-tripping each plugin

The examples below use `PKG` for the app's package id:

```bash
PKG=com.swiftpwa.hello
```

`__platform.info` lists every command the runtime registered —
this is the first call to make. If a plugin doesn't show up here,
the JS-side `__SWIFT_PWA__.invoke('<command>', ...)` will reject
with "command not registered" rather than reach Swift.

```bash
Scripts/android-cdp-eval.py "$PKG" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('__platform.info', {})))()"
# → "{\"os\":\"android\",\"tempDir\":\"...\",\"commands\":[\"biometric.authenticate\",\"biometric.canAuthenticate\",\"clipboard.clear\",\"clipboard.readText\",\"clipboard.writeText\",\"dialog.confirm\",\"dialog.message\",...]}"
```

### 4.1. Sync plugins (clipboard, biometric status, notification auth)

These resolve immediately — no native UI to drive:

```bash
# Clipboard write/read round-trip
Scripts/android-cdp-eval.py "$PKG" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('clipboard.writeText', {text: 'hello'})))()"
Scripts/android-cdp-eval.py "$PKG" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('clipboard.readText', {})))()"
# → "{\"text\":\"hello\"}"

# Biometric availability
Scripts/android-cdp-eval.py "$PKG" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('biometric.canAuthenticate', {})))()"
# → "{\"available\":true,\"kind\":\"unknown\"}"

# Notification authorization (API 33+ shows a system prompt the first time)
Scripts/android-cdp-eval.py "$PKG" \
  "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('notifications.requestAuthorization', {})))()"
# → "{\"granted\":true}"

# Send a notification (visible in the system shade)
Scripts/android-cdp-eval.py "$PKG" \
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
Scripts/android-cdp-eval.py "$PKG" \
  "(()=>{__SWIFT_PWA__.invoke('dialog.confirm', {message: 'Tap YES', okLabel: 'Yes', cancelLabel: 'No'}).then(r=>window._dlg=JSON.stringify(r)); return 'pending';})()"

# 2. Drive the native UI (see §5)
adb shell input tap 1838 826   # YES button on a 2800x1752 landscape

# 3. Read the resolved result
Scripts/android-cdp-eval.py "$PKG" "window._dlg || 'still pending'"
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

- **`adb forward` socket name uses the PID.** A pre-existing forward
  to a dead PID returns connection-refused on the next
  `curl http://localhost:9222/json` — looks like the device went
  away when actually you're forwarding to a stale socket. This is
  why `Scripts/android-cdp-eval.py` re-establishes the forward on
  every run rather than assuming one; if you wire up CDP by hand,
  re-run it after every `am force-stop` + `am start`.

- **`KEYCODE_BACK` exits the app** if no modal is open. The first
  time I sent BACK to dismiss what I thought was a stuck dialog,
  the app went to home and the next `adb shell screencap` showed
  the launcher. `am start -n com.swiftpwa.hello/.MainActivity`
  brings it back; `adb forward` needs to be re-run because the
  PID changed.

- **Biometric prompt blanks `screencap`.** Android's secure-overlay
  protection blocks screenshots over `BiometricPrompt` — macOS does
  the same to `screencapture` over a Touch ID sheet, so this is not
  Android being awkward. The black screen is the *right* behaviour,
  not a bug. **`adb shell uiautomator dump` still reads it**, which
  is how you check what the prompt actually offers: with
  `allowDeviceCredential: true` the negative button reads "Use PIN"
  where it otherwise reads "Cancel". Verify the round-trip
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
