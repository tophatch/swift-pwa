# swift-pwa on Android (android.webkit.WebView via JNI)

The Android backend compiles your Swift code to a shared object (`.so`)
that a Kotlin `Activity` loads via `System.loadLibrary`. The Activity
hosts a stock `android.webkit.WebView` (Chromium-backed since Android
7.0) and exposes a JS↔Swift bridge through `addJavascriptInterface` +
`evaluateJavascript`. The CLI's `swift-pwa build --target android`
emits a Gradle project that wraps the `.so`, your web bundle, and a
generated `MainActivity` + `SwiftPWABridge`.

> **Status: v0.5.0 — plugin set at desktop parity, verified
> end-to-end on-device** (reproducible — see
> [docs/android-on-device-testing.md](android-on-device-testing.md)
> for the loop). Full pipeline (`swift-pwa build --target
> android --cross-compile-android` → `./gradlew assembleDebug` →
> `adb install` → launch) on a Samsung Galaxy Tab S10+ (Android 16,
> arm64): `Examples/HelloPWA` loads, the WebView renders the demo
> from `assets/web/`, and the Swift→Kotlin RPC channel round-trips
> every new plugin — `clipboard.writeText` + `clipboard.readText`,
> `dialog.confirm` (custom labels), `dialog.openFile` (SAF Documents
> UI returning a `content://` URI), `notifications.send` (visible in
> the system shade with the right channel + silent flag),
> `biometric.canAuthenticate` and `biometric.authenticate` (system
> prompt rendered, face unlock observed). Tray remains a no-op stub
> (Android has no system-tray surface in the desktop sense). The
> cross-compile + `assembleDebug` step additionally runs in CI via
> the `android` job in `.github/workflows/ci.yml` — every push
> surfaces toolchain or Gradle drift before it reaches a developer's
> machine.

## 1. Toolchain

The cross-compile path verified against this repo's `Examples/HelloPWA`:

| Component                            | Pinned version             | Install                                                                                                |
|--------------------------------------|----------------------------|--------------------------------------------------------------------------------------------------------|
| Swift toolchain                      | **6.2.0 exactly**          | `brew install swiftly && swiftly init && swiftly install 6.2.0` — must match the SDK exactly (see §2)  |
| Swift Android SDK                    | swift-6.2-RELEASE-android-0.1 | `swift sdk install <bundle-url> --checksum <sha>` (URL + checksum from <https://github.com/swift-android-sdk/swift-android-sdk/releases/tag/6.2>) |
| Android NDK                          | **r27d**                   | <https://dl.google.com/android/repository/android-ndk-r27d-darwin.zip> (or the linux/windows variant)  |
| Setup script                         | (run once)                 | `ANDROID_NDK_HOME=~/android-ndk-r27d ~/Library/org.swift.swiftpm/swift-sdks/swift-6.2-RELEASE-android-0.1.artifactbundle/swift-android/scripts/setup-android-sdk.sh` |
| JDK 17 *(for `assembleDebug`)*       | any 17.x                   | `brew install openjdk@17` — no `JAVA_HOME` export needed, see [§Toolchain discovery](#toolchain-discovery) |
| Android SDK *(for `assembleDebug`)*  | latest                     | Android Studio, or the command-line tools. Found automatically in the standard location; else set `ANDROID_HOME` |
| Android SDK Platform-Tools (`adb`)   | latest                     | Bundled with Android Studio, or `sdkmanager "platform-tools"`                                          |
| Gradle wrapper                       | **8.10.2 (vendored)**      | Shipped inside the generated scaffold (`gradlew`, `gradlew.bat`, `gradle/wrapper/*`); no separate install needed. AGP 8.5 + Kotlin 2.0 dependencies are resolved on first wrapper run. |

> **Why `swift install 6.2.0` and not just `6.2`.** The SDK bundle's
> Swift modules were built with Swift 6.2 (i.e. 6.2.0). Swift's
> `.swiftmodule` format isn't ABI-stable across patch versions yet, so
> a 6.2.4 compiler refuses to import 6.2.0 modules with `module
> compiled with Swift 6.2 cannot be imported by the Swift 6.2.4
> compiler`. `swiftly install 6.2` resolves to the latest patch (which
> at time of writing is 6.2.4); use `6.2.0` explicitly.

The bundler smooths over the toolchain-selection part of that pin:

> **The bundler selects the matching toolchain for you.** You don't need to
> wrap `swift-pwa build --cross-compile-android` in `swiftly run +6.2.0` — when
> swiftly is installed, the bundler parses the SDK's version and runs the inner
> `swift build --swift-sdk` under `swiftly run +<major.minor>` itself, which
> overrides any repo `.swift-version` (this repo pins `6.0`, which would
> otherwise mispin the Android build). If a requested ABI can't be built, the
> command now **fails with a non-zero exit** rather than emitting a scaffold
> with empty `jniLibs/` — a hollow APK would crash at launch with
> `UnsatisfiedLinkError`. If you see `'stddef.h' file not found` during the
> cross-compile, the SDK's NDK clang link went stale (e.g. after moving the
> NDK): re-run the setup script above.

### Toolchain discovery

You don't have to export `ANDROID_HOME`, `ANDROID_NDK_HOME`, or `JAVA_HOME` for a
standard install. The CLI locates each piece itself — environment variable first
(so an explicit export always wins), then the platform's normal install locations:

| Piece | Looked for at |
|---|---|
| **Android SDK** | `$ANDROID_HOME` · `$ANDROID_SDK_ROOT` · `~/Library/Android/sdk` (macOS) · `~/Android/Sdk` (Linux) · `%LOCALAPPDATA%\Android\Sdk` · `/usr/local/lib/android/sdk` (GitHub runners) |
| **NDK** | `$ANDROID_NDK_HOME` · `$ANDROID_NDK_ROOT` · `$NDK_HOME` · `<sdk>/ndk/<version>` (newest) · `<sdk>/ndk-bundle` |
| **JDK** | `$JAVA_HOME` · a working `java` on `PATH` · `/Library/Java/JavaVirtualMachines/*` · Homebrew's keg-only `openjdk*` · `/usr/lib/jvm/*` · Android Studio's bundled JBR · `%ProgramFiles%` vendors |
| **swiftly** (for the toolchain pin, §2) | `$SWIFTLY_BIN_DIR` · `$SWIFTLY_HOME_DIR/bin` · `~/.swiftly/bin` (swiftly 1.x's default home) · `~/.local/share/swiftly/bin` · `~/Library/Application Support/swiftly/bin` |

Notes on the two that bite:

- **`java` on `PATH` is not evidence of a JDK on macOS.** `/usr/bin/java` is a
  *stub* that exists on every Mac and exits with "Unable to locate a Java
  Runtime" when nothing is installed. The CLI runs it rather than looking it up,
  so `doctor` tells you the truth, and Homebrew's `openjdk@17` — keg-only, so
  never linked where `/usr/libexec/java_home` can see it — is found and handed to
  Gradle via `JAVA_HOME`.
- **Multiple JDKs**: the generated project pins AGP 8.5 / Gradle 8.10 and
  compiles to Java 17, so 17 is preferred, then the newest JDK in Gradle's
  supported 17–22 range. A JDK below 17 is never selected.

`swift-pwa build --target android` also writes the resolved SDK path into the
generated project's `local.properties`, so `cd build/<Name>-android && ./gradlew
assembleDebug` and opening the project in Android Studio both work on a machine
that never exported anything. (Only `sdk.dir` — an `ndk.dir` AGP doesn't need
gets version-matched against its own default and warns `CXX1104` on every module
task.)

`swift-pwa doctor --target android` prints where each piece was found, and
`deploy` fails up front — before the multi-minute cross-compile — when the JDK or
SDK is missing, rather than letting Gradle report it at the end.

A second pin worth knowing about, derived from the SDK's own metadata:

> **Why the API 28 floor.** The Swift Android SDK 6.2 distribution's
> `swift-sdk.json` only declares target triples for API 28–36. The
> older API 24 floor was dropped in that release. The CLI's bundler
> clamps to API 28 even when `pwa.json`'s `android.min_sdk` is lower,
> with a warning, since SwiftPM otherwise silently resolves to a
> wrong-arch resource path.

## 2. Project layout

A swift-pwa Android project on disk looks the same as the desktop
projects:

```
MyApp/
├── pwa.json                 # source of truth for app metadata
├── Package.swift            # depends on SwiftPWA umbrella
├── Sources/MyApp/main.swift # uses SwiftPWA.runtime().run { ... }
└── web/                     # web bundle (HTML/JS/CSS)
```

Building for Android emits a Gradle project alongside it:

```
build/
└── MyApp-android/
    ├── settings.gradle.kts
    ├── build.gradle.kts
    ├── gradle.properties
    └── app/
        ├── build.gradle.kts
        └── src/main/
            ├── AndroidManifest.xml
            ├── java/<package>/MainActivity.kt          # generated
            ├── java/dev/swiftpwa/runtime/SwiftPWABridge.kt
            ├── jniLibs/<abi>/libMyApp.so               # from `swift build --triple ...`
            ├── res/mipmap/ic_launcher.png              # from pwa.json `icon` (if a PNG)
            └── assets/
                ├── web/                                # copied from ../web/
                └── swift_pwa/bridge.js                 # injected at page-start
```

The `swift_pwa` namespace is reserved — don't put your own assets in
it; the bundler manages it.

When `pwa.json`'s `icon` is a PNG, the bundler copies it to
`res/mipmap/ic_launcher.png` and wires `android:icon="@mipmap/ic_launcher"`
into the manifest; aapt/Gradle scale it per density at build time (a
single source PNG is enough). Without an icon, the platform default
launcher icon is used. The build prints a one-line icon summary either
way (`swift-pwa: app icon ← icon.png`, or the fallback reason — no icon
set / not a PNG / file missing).

## 3. Building your app's `.so`

Your Swift package needs to compile to a shared library on Android,
not an executable. Add this to your `Package.swift`:

```swift
.executableTarget(
    name: "MyApp",
    dependencies: [.product(name: "SwiftPWA", package: "swift-pwa")],
    linkerSettings: [
        // `-no-pie` cancels the toolchain's default `-pie` (mutually
        // exclusive with `-shared` under `lld`); `-shared` then
        // produces an actual .so that `System.loadLibrary` accepts.
        // Without `-no-pie`, the link fails with
        // `ld.lld: error: -shared and -pie may not be used together`.
        .unsafeFlags(
            ["-Xlinker", "-no-pie", "-Xlinker", "-shared"],
            .when(platforms: [.android])
        )
    ]
)
```

> The Swift binary lands at `.build/<triple>/release/MyApp` (no `lib`
> prefix, no `.so` suffix) even though it's a real ELF shared object —
> SwiftPM uses the executable target's product naming convention. The
> CLI's `AndroidBundler` knows to look for both `MyApp` and
> `libMyApp.so` and renames on copy when staging into
> `app/src/main/jniLibs/<abi>/`.

Then provide the `swiftpwa_android_main` C-callable entry point that
the generated `MainActivity` JNI-calls into:

```swift
// Sources/MyApp/AndroidEntry.swift
#if os(Android)
import SwiftPWA

@_cdecl("Java_<your_package_with_underscores>_MainActivity_swiftPwaMain")
public func swiftpwa_android_main() {
    do {
        try SwiftPWA.runtime().run { context in
            try context.createWindow(WindowConfig(
                title: "My App",
                size: Size(width: 360, height: 640),
                content: .bundled(
                    directory: URL(fileURLWithPath: "/android_asset/web"),
                    entry: "index.html"
                )
            ))
        }
    } catch {
        // run() returns Never; we get here only on a configure error.
    }
}
#endif
```

The JNI symbol mangling — `Java_<package>_<class>_<method>` with dots
replaced by underscores — is what links the Kotlin `external fun
swiftPwaMain()` declaration to your Swift function. If you change
`pwa.json`'s `android.package_id`, regenerate the scaffold and update
the `@_cdecl` to match.

**Drift is caught for you.** `swift-pwa build --target android` (and
`swift-pwa doctor --target android`) compare the `@_cdecl` symbol in
`AndroidEntry.swift` against the manifest's `package_id` and **warn** if
they disagree, before you get the runtime `UnsatisfiedLinkError`. The fix
it prints: set the `@_cdecl` to the mangled current package, or delete
`AndroidEntry.swift` and re-run `swift-pwa init <name> --in-place`.

> Why a manual `@_cdecl` instead of a generated wrapper? Because the
> exported symbol's name has to embed the user's Java package id,
> which the Swift target itself doesn't know about. `swift-pwa init`
> emits this file pre-populated with the right mangled symbol for the
> chosen `--bundle-id` (Sources/&lt;name&gt;/AndroidEntry.swift); apps
> that change `pwa.json`'s `android.package_id` after the fact must
> update the `@_cdecl` string in lockstep, since the Activity
> surfaces `UnsatisfiedLinkError: Native method not found` at startup
> if the two drift.

## 4. Cross-compile + bundle

Two paths:

**A. Generate scaffold only** (default; works on any host):

```bash
swift-pwa build --target android
# Built: build/android/MyApp-android
# Next: cd 'build/android/MyApp-android' && ./gradlew assembleDebug
```

You'll see a note that `jniLibs/` is empty. Drop your built `.so`s in
manually (note: pass the triple as `--swift-sdk <triple>`, not as
`--triple` — see §1's API 28 footnote for why):

```bash
swiftly run +6.2.0 swift build -c release --swift-sdk aarch64-unknown-linux-android28
mkdir -p build/android/MyApp-android/app/src/main/jniLibs/arm64-v8a
cp .build/aarch64-unknown-linux-android28/release/MyApp \
   build/android/MyApp-android/app/src/main/jniLibs/arm64-v8a/libMyApp.so
```

**You must also stage the Swift runtime + C++ shared libraries into the same
`jniLibs/<abi>/`** — copying only the app `.so` launches to
`UnsatisfiedLinkError: dlopen failed: library "libswiftCore.so" not found`,
because nothing else carries the Swift standard library or the NDK's
`libc++_shared.so`:

```bash
# Swift stdlib .so's (path is inside your installed Swift Android SDK bundle):
cp <swift-android-sdk>/swift-resources/usr/lib/swift-aarch64/android/*.so \
   build/android/MyApp-android/app/src/main/jniLibs/arm64-v8a/
# NDK C++ runtime:
cp <ndk>/toolchains/llvm/prebuilt/<host>/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so \
   build/android/MyApp-android/app/src/main/jniLibs/arm64-v8a/
```

This staging is precisely what **Option B (`--cross-compile-android`) does for
you** (`stageSwiftRuntime`) — prefer it unless you specifically need the manual
two-step.

Then `./gradlew assembleDebug` produces `app/build/outputs/apk/debug/app-debug.apk`.

**B. Cross-compile + stage in one step** (requires Swift Android SDK installed; the bundler preflights `swift sdk list` and bails with a clean diagnostic if none is installed):

```bash
swiftly run +6.2.0 swift run --package-path /path/to/swift-pwa swift-pwa \
    build --target android --cross-compile-android --android-abis arm64-v8a,x86_64
```

The CLI runs `swift build --swift-sdk <android-triple>` for each
requested ABI (clamping API to ≥28 to match the SDK's
`targetTriples` map), then copies the resulting Swift binary into
`app/src/main/jniLibs/<abi>/libMyApp.so` (renaming from SwiftPM's
default `MyApp` output name to the JNI loader's `lib*.so`
convention). Failures per ABI are reported but don't abort the
bundle — the scaffold still emits so you can fix the toolchain and
re-stage by hand.

> **Wrap with `swiftly run +6.2.0`.** The CLI itself shells out to
> bare `swift build`, picking up whatever's on PATH. If your default
> toolchain is not 6.2.0, run the whole thing under `swiftly run
> +6.2.0` so the inner build sees the matching compiler. Cross-compile
> against a 6.2 SDK with a 6.3 compiler fails with a `module compiled
> with Swift 6.2 cannot be imported by the Swift 6.3 compiler` error.

One more automatic safeguard runs on the way in:

> **Stale-cache guard (automatic).** Before each ABI's `swift build`, the
> bundler fingerprints two things — the swift-pwa runtime sources and the host
> toolchain (resolved NDK path + Swift Android SDK bundle id) — and wipes
> `.build/<triple>` when either moved since that triple was last built. It
> covers two failure modes that both present as something other than their
> cause:
>
> - a **changed runtime ABI** → a startup `SIGSEGV` (a `swift_retain` fault in a
>   type's value-witness copy), which SwiftPM's incremental Android build can
>   produce when a core type's stored fields change — most commonly after you
>   bump the swift-pwa dependency;
> - a **moved or upgraded NDK** → `error: module '_Builtin_stddef' is defined in
>   both …-12XADZNGFAU7K.pcm and …-SRKHNJT8UHKO.pcm`, because the cached clang
>   modules embed the NDK's header paths and the same module then resolves
>   through two of them.
>
> When it fires you get one line naming the culprit — `note: cleaned
> .build/<triple> — the Android toolchain changed: ndk=<old> → ndk=<new>` — and
> an unchanged tree keeps the fast incremental path. The fingerprint lives in
> `.build/<triple>/.swiftpwa-abi-fingerprint` (two readable lines). On a build
> predating this guard, `rm -rf .build/*android*` and rebuild.

The bundler also drops a vendored Gradle 8.10.2 wrapper into the
generated project (`gradlew`, `gradlew.bat`, `gradle/wrapper/*`) so
`./gradlew assembleDebug` works straight out of the scaffold — no
separate Gradle install required, just JDK 17. The wrapper itself
fetches Gradle 8.10.2 from `services.gradle.org` on first run; cache
hits are zero-cost thereafter.

```bash
cd build/android/MyApp-android
# The SDK path is already in the generated local.properties. A JDK still has to
# be on PATH or in JAVA_HOME for a by-hand run — `swift-pwa deploy` sets it for
# you, a bare `./gradlew` can't.
./gradlew --version       # confirms wrapper bootstraps cleanly
./gradlew assembleDebug    # produces app/build/outputs/apk/debug/app-debug.apk
```

## 5. Configuration

`pwa.json`'s `android` section:

```json
{
  "id": "com.example.myapp",
  "name": "MyApp",
  "version": "1.0.0",
  "web": { "directory": "web" },
  "window": { "title": "MyApp" },
  "android": {
    "package_id": "com.example.myapp",
    "min_sdk": 26,
    "target_sdk": 34,
    "abis": ["arm64-v8a", "x86_64"],
    "version_code": 1
  }
}
```

All fields are optional; sensible defaults are derived from the
top-level keys. The CLI flag `--android-abis` overrides
`android.abis` when both are set.

### `window.background_color`

Setting the top-level `window.background_color` makes the Android build
paint its native surface to match before the page's first paint — the
same option honoured on every other backend. It accepts either a single
hex string (`"#F4F7F5"`, used for both light and dark) or a light/dark
pair:

```json
"window": { "background_color": { "light": "#F4F4F2", "dark": "#0C0D0E" } }
```

On Android it drives three things, generated only when the field is set
(omit it to keep the stock theme):

- **Launch window (DayNight)** — the bundler emits a `Theme.SwiftPWA`
  descended from **`Theme.AppCompat.DayNight.NoActionBar`** whose
  `android:windowBackground` is the configured colour, and points the
  manifest's `<application>` at it. It writes the theme **twice**:
  `res/values/swift_pwa_theme.xml` with the light colour and
  `res/values-night/swift_pwa_theme.xml` with the dark colour, so Android
  resolves the right one per system setting. A single-string colour writes
  the same value to both. This removes the white flash between launch and
  the WebView's first paint.

  The DayNight parent matters beyond the launch colour: `MainActivity` is
  an `AppCompatActivity`, and inflating a `*.Light.*` theme pins its
  context to light `uiMode` — which the `WebView` inherits, so
  **`prefers-color-scheme: dark` never matched inside the page** regardless
  of the device setting (the v0.7.5–0.7.7 behaviour). With the DayNight
  parent the WebView tracks the system theme, and toggling it at runtime
  updates the page's media queries live.
- **System bars** — `android:statusBarColor` and
  `android:navigationBarColor` are set to the mode's colour, and
  `android:windowLightStatusBar` / `windowLightNavigationBar` are chosen
  per mode from the colour's relative luminance (dark glyphs on a light
  fill, light glyphs on a dark one) so the bar icons stay legible.
- **WebView surface** — the generated `MainActivity` calls
  `webView.setBackgroundColor(...)`, covering the gap between view
  inflation and the page's first paint. For a light/dark pair this
  branches on the active night mode (`UI_MODE_NIGHT_MASK`) so a dark-mode
  user gets the dark pre-paint colour, not a light flash.

The other backends (macOS / iOS / Linux / Windows) aren't system-theme-
aware at runtime yet, so they paint a **single** launch colour; given a
pair they use its **dark** value (a dark pre-paint flash is preferable to
blinding a dark-mode user with the light colour). Device-verified on a
Galaxy Tab S10+: `prefers-color-scheme` reports `dark` in night mode and
`light` otherwise, tracking the system toggle.

### `window.remember_state`

`window.remember_state` (window size / position memory across launches) is
a **desktop-only** feature — a no-op on Android, where the app window is
full-screen and the OS owns its geometry. The key is accepted in `pwa.json`
(so one manifest can drive every target) but has no effect on an Android
build. See [README.md](../README.md#configuring-pwajson).

### File associations (`android.document_types`)

Declare the file types your app opens and it appears in Android's **Open
with** chooser and **share sheet**; when a user picks a matching file, its
URI is delivered to the web app on the `app.openFile` event channel (see
[javascript-api.md](javascript-api.md#appopenfile--os-open-with--launch-with-file)).
This is the Android counterpart to Apple's `CFBundleDocumentTypes` (declared
there via the `ios`/`macos` `info_plist` passthrough).

```json
"android": {
  "document_types": [
    { "mime_types": ["image/png", "image/jpeg", "image/webp"] }
  ]
}
```

Each entry's `mime_types` become `<data android:mimeType="…"/>` specs on two
generated intent-filters on the launcher activity: one `ACTION_VIEW` ("Open
with") and one `ACTION_SEND` / `ACTION_SEND_MULTIPLE` (share sheet). A
MIME-type-only data spec matches both `content:` and `file:` URIs, which is
exactly the local-file open case. Wildcards work (`"image/*"`). Unset → no
association (the app only opens from the launcher).

The file arrives as a **`content://` URI** (the SAF form), delivered to JS as
`{ paths: ["content://…"] }`; read it with `fs.readBinary` (the same
content-URI path `dialog.openFile` uses — see §8). The URI carries a temporary
read grant scoped to the launching activity, so no extra permission step is
needed. Both cold launch (the file starts the app) and warm delivery (the app
is already running) are handled; device-verified on a Galaxy Tab S10+.

### Cleartext HTTP to LAN endpoints (`android.network.cleartext_domains`)

Android blocks plain-`http://` (cleartext) traffic by default
(`usesCleartextTraffic="false"`), enforced by the OS's Network Security Config
regardless of which HTTP client makes the call. So an app can't reach a
local-network appliance such as a ComfyUI instance on
`http://192.168.x.x:8188` — or any plain-http dev server — until you opt the
specific host back in. HTTPS endpoints are unaffected and need nothing here.

```json
"android": {
  "network": { "cleartext_domains": ["nas.local", "192.168.1.50", "*.local"] }
}
```

The bundler generates `res/xml/network_security_config.xml` whose global
`base-config` keeps cleartext **off** and a scoped `domain-config` permits it
**only** for the listed hosts, and references it from the manifest. This is the
least-broad fix and the shape least likely to draw Play Store scrutiny — a
blanket `usesCleartextTraffic="true"` is deliberately not offered. Entries are
network-security-config *domains*: a concrete hostname or an mDNS-style
`"*.local"` suffix (→ `local` with `includeSubdomains`); bare CIDR ranges aren't
expressible, so list the concrete host(s). Omitting the key leaves the manifest
unchanged. This governs both the `net.*` plugin and any remote `AIBackend`
talking to a plain-http endpoint. See [net-plugin.md](net-plugin.md).

## 6. Architecture notes

The Android backend differs from the desktop ones in a few important
ways. These shape the public API surface and what to expect:

- **`AppRuntime.run(_:)` doesn't drive a UI loop.** Android's UI
  thread belongs to the JVM. Swift code is loaded as a `.so` by the
  Activity and `swiftpwa_android_main` runs on a worker thread; the
  runtime's `run` method registers handlers, executes the user's
  `configure` closure on the worker, then blocks on a semaphore until
  `quit(exitCode:)` is invoked.
- **`MainThread.run` hops through `Handler(Looper.getMainLooper()).post`.**
  Same shape as Windows' message-only dispatcher window and GTK's
  `g_idle_add` — defined in `AndroidAppRuntime.installMainThreadHook`.
- **Multi-window via Activity-per-window.** The first
  `context.createWindow(...)` call binds to the foreground Activity
  the JNI runtime entry-point already owns. Subsequent calls
  JNI-launch a fresh `MainActivity` instance with the configured
  content URL in an `swift-pwa.config-json` intent extra — the
  spawned Activity loads that URL into its own WebView and pushes
  onto the current task's back stack, so the system back gesture
  returns to the originating Activity (Android-native "open detail
  view" UX). Each Activity has its own `SwiftPWABridge` and its own
  JS runtime; the C shim's single-slot bridge ref always points at
  whichever Activity is foreground (managed via `onResume` /
  `onPause` re-attach in the generated `MainActivity`). The
  `AndroidWindow` returned for a secondary spawn has
  `role == .secondary`: `setTitle`, `setFullscreen`, and `close()`
  intentionally don't reach across Activities (they'd target
  whichever Activity is foreground instead of the spawned one), so
  cross-Activity Swift→OS calls aren't supported — apps that need
  to mutate a secondary window should do it from JS inside that
  Activity. `title()` / `isFullscreen()` continue to report the
  most-recent caller intent for the returned `Window`.
- **Most `Window` shape APIs are no-ops** (`setSize`, `setPosition`,
  `minimize`, `maximize`, `focus`). The platform owns those decisions
  on Android. `Window.setFullscreen(true)` hides the system status +
  navigation bars via `WindowInsetsControllerCompat` and lets the
  WebView draw edge-to-edge, with transient bars on swipe so system
  gestures stay reachable; `setFullscreen(false)` restores the
  default fitted-system-windows layout. See
  [AndroidWindow.swift](../Sources/SwiftPWAAndroid/AndroidWindow.swift)
  for the full list.
- **DevTools is remote-only.** Android WebView has no programmatic
  `openDevTools()` window; `chrome://inspect` on a host connected
  via `adb` is the only path. Calling `webView.openDevTools()` logs
  a hint via `Log.i("swift-pwa", ...)` to make the call visibly
  effective.

## 6.1. System plugins — Android specifics

The `System*` plugins on Android are driven through a generic
Swift→Kotlin RPC channel (`swiftpwa_android_rpc` on the C side,
`SwiftPWABridge.rpcCall` + `SwiftPWASystemPlugins.dispatch` on the
Kotlin side). One plugin = one `when` branch in
`SwiftPWASystemPlugins.kt`; the bundler regenerates that file from
the templates under `Sources/SwiftPWACLISupport/Bundlers/AndroidTemplates.swift`,
so apps shouldn't edit it by hand.

| Plugin                | Backing API                                                                                                                                          | Notes                                                                                                                                                                                                                                                                                              |
|-----------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `SystemClipboard`     | `ClipboardManager`                                                                                                                                   | `clear()` falls back to `setPrimaryClip(empty)` on API 26 / 27 (the explicit `clearPrimaryClip` only landed in P / API 28).                                                                                                                                                                        |
| `SystemNotifications` | `NotificationManagerCompat` + a single `swift-pwa.default` channel                                                                                   | API 33+ requires the `POST_NOTIFICATIONS` runtime permission; `requestAuthorization` shows the system prompt the first time.                                                                                                                                                                       |
| `SystemDialog`        | `AlertDialog.Builder` for message / confirm; Storage Access Framework (`OPEN_DOCUMENT` / `CREATE_DOCUMENT` / `OPEN_DOCUMENT_TREE`) for file pickers  | **SAF returns `content://` URIs, not filesystem paths.** Apps that need bytes should resolve via `ContentResolver`. `DialogFileFilter.extensions` map to MIME types via a small built-in table; unknown extensions fall back to `*/*`. `dialog.exportFile` runs `CREATE_DOCUMENT` **and writes** the supplied content into the chosen document (via `ContentResolver`), returning the destination `content://` URI — unlike `dialog.saveFile`, which returns the URI for the app to write itself. |
| `SystemBiometricAuth` | `androidx.biometric.BiometricPrompt`                                                                                                                 | The host `MainActivity` extends `AppCompatActivity` (a `FragmentActivity` subclass) so the prompt can attach. `BiometricKind` is always `.unknown` when available — Android's `BiometricManager` doesn't distinguish fingerprint / face / iris at the API level.                                  |
| `AndroidUpdater`      | `PackageInstaller.Session` + `BroadcastReceiver` for install status                                                                                  | Self-installing APKs requires the `REQUEST_INSTALL_PACKAGES` manifest permission **plus** the per-app "Install unknown apps" toggle — the system installer surfaces a dialog routing the user to settings if the toggle is off. The plugin still verifies Ed25519 over the artifact bytes itself. The streaming `updater.install` JS command surfaces the platform's `STATUS_*` broadcasts as `installCommitted` / `installSucceeded` / `installFailed` events — see §6.3. |
| `SystemTray`          | — (no-op stub)                                                                                                                                       | Android has no system-tray surface analogous to macOS' menu bar / Windows' notification area.                                                                                                                                                                                                      |

### 6.1.1. Wiring up

```swift
#if os(Android)
    import SwiftPWA

    // Inside your configure closure:
    context.use(ClipboardPlugin(SystemClipboard()))
    context.use(NotificationsPlugin(SystemNotifications()))
    context.use(DialogPlugin(SystemDialog()))
    context.use(BiometricAuthPlugin(SystemBiometricAuth()))
    context.use(UpdaterPlugin(AndroidUpdater(
        endpoint: URL(string: "https://example.com/updates/manifest.json")!,
        publicKey: "<base64-ed25519-pubkey>",
        currentVersion: "1.0.0"
    )))
#endif
```

The Gradle scaffold's `AndroidManifest.xml` declares all four
permission strings (`POST_NOTIFICATIONS`, `USE_BIOMETRIC`,
`USE_FINGERPRINT`, `REQUEST_INSTALL_PACKAGES`); apps that don't
ship a particular plugin can drop the corresponding line in a
manual post-bundler edit.

### 6.1.2. Observing the updater install result

The cross-platform `updater.installAndRelaunch` invoke commits a
`PackageInstaller.Session` and returns. The user accept / reject UI
that follows is *asynchronous* — on desktop platforms the running
process is replaced before the call returns, so there's nothing to
observe; on Android the system installer's confirmation prompt fires
later via a `BroadcastReceiver`, which `installAndRelaunch` cannot
wait on without changing the cross-platform contract.

The streaming `updater.install` subscription surfaces that lifecycle.
The Kotlin scaffold's receiver pushes each `PackageInstaller.STATUS_*`
intent into the `AndroidHostEventRouter`, which routes it to the
in-flight stream:

```js
const unsub = __SWIFT_PWA__.subscribe("updater.install", null, (event) => {
    switch (event.type) {
        case "installCommitted":
            // Session committed; the OS install prompt is on screen.
            showHint("Tap Install in the system prompt to continue.");
            break;
        case "installSucceeded":
            // Fires only briefly before the system replaces the
            // running app — useful mostly for telemetry, not UI.
            break;
        case "installFailed":
            // event.code is the platform constant name, e.g.
            // "STATUS_FAILURE_ABORTED" when the user rejected the
            // prompt, "STATUS_FAILURE_STORAGE" when there's no room,
            // "STATUS_FAILURE_BLOCKED" when policy denies the install.
            // event.message is the system reason string if present.
            showError(`Install blocked: ${event.code} (${event.message ?? "no detail"})`);
            break;
        case "error":
            // The commit itself failed (no staged APK, I/O error
            // copying bytes into the session, etc.).
            showError(`Install commit failed: ${event.message}`);
            break;
    }
});
```

Stream lifetime: the first terminal event (`installSucceeded` or
`installFailed`) finishes the stream. Apps that need to retry after
a failure should re-`subscribe` rather than expecting the prior
stream to deliver further events.

A separate `updater.installAndRelaunch` invoke is still wired —
existing call sites keep working — but only `updater.install`
reaches the broadcast result.

## 6.2. APK size

Two bundler passes shrink the APK from a 131 MB unstripped wholesale
build down to ~76 MB on `Examples/HelloPWA` (arm64-v8a, debug):

| Configuration                                   | jniLibs   | APK     |
|-------------------------------------------------|-----------|---------|
| baseline (no prune, AGP can't strip)            | 124 MB    | 131 MB  |
| `--prune-android-runtime` only                  | 113 MB    | 121 MB  |
| **always-on strip (default)**                   | 73 MB     | 80 MB   |
| **strip + `--prune-android-runtime` (default + opt-in)** | 68 MB | **76 MB** |

The always-on strip step runs `llvm-strip --strip-unneeded` on every
staged `.so` (the user's binary plus the bundled Swift runtime libs)
inline before gradle sees them. The bundler resolves `llvm-strip` from
the NDK's `toolchains/llvm/prebuilt/<host>/bin/` (wherever the NDK was
[discovered](#toolchain-discovery)) — necessary because AGP's own
`stripDebugDebugSymbols` task only finds the strip tool when an
SDK-manager-installed NDK lives at `$ANDROID_HOME/ndk/<version>/`, and the
Swift-on-Android dev setup pins a standalone NDK at `$ANDROID_NDK_HOME`
instead. A bare `strip` on `PATH` is only accepted on Linux/Windows: on
macOS that is always Xcode's Mach-O `strip`, which rejects
`--strip-unneeded` on every ELF file it's handed. If no usable tool is
found, the step is skipped with a `warning:` and the APK is ~40% larger —
it never silently reports a 0% saving. The unstripped binary stays in
`.build/<triple>/release/<Name>` for `swift symbolicate` to consume during
crash triage.

The `--prune-android-runtime` flag drops 10 unused stdlib `.so`s
(`_Differentiation`, `_StringProcessing` build artifacts not in the
chain, `RegexBuilder`, `Distributed`, `FoundationXML`, `Testing`,
`XCTest`, `Observation`, `_Volatile`, `_SwiftOnoneSupport`) from the
26-file wholesale set. The marginal saving on top of strip is small
(~5 MB) because the dominating size after stripping is the
Foundation+ICU stack the binary genuinely pulls in:

| File                         | Stripped size |
|------------------------------|---------------|
| `lib_FoundationICU.so`       | 37 MB (ICU i18n data — load-bearing for `URL` / `Locale`) |
| `libswiftCore.so`            | 7 MB |
| `libFoundation.so`           | 6 MB |
| `libFoundationEssentials.so` | 6 MB |
| `libHelloPWA.so` (app)       | 4 MB |
| `libFoundationNetworking.so` | 3 MB |

Apps that don't need internationalisation can in principle drop ICU
(36 MB win) by avoiding any `Foundation` API path that touches
`Locale` / `URL` parsing — that's a non-trivial refactor in practice
and isn't something the bundler can prune automatically.

## 7. Code signing

`assembleDebug` builds with the Android-supplied debug keystore — fine
for sideloading via `adb install`, but the Play Store and most enterprise
distribution paths require a `release`-signed APK / AAB. The bundler
wires release signing into the generated `app/build.gradle.kts` when
configured; passwords are read from the environment, so `pwa.json`
stays committable without leaking secrets.

### 7.1. Generate a keystore

`keytool` (bundled with JDK 17) produces a PKCS#12 keystore that AGP
accepts directly:

```bash
keytool -genkeypair \
    -keystore release.jks \
    -alias upload-key \
    -keyalg RSA -keysize 2048 -validity 36500 \
    -storetype pkcs12
# (prompt for store password and key password — keep them in a password
#  manager; the generated Gradle scaffold reads them from env vars at
#  build time, never from disk.)
```

Stash `release.jks` somewhere outside the project tree, or inside it
behind `.gitignore` (`*.jks`, `*.keystore`, `*.p12`, `keystore.properties`
— the entries `swift-pwa init` pre-populates). Lose this file and you
**cannot push updates** to the Play Store under the same listing —
Google's app-signing keys can be reset via support, but the upload key
that signs *your* uploads is yours to manage.

### 7.2. Wire it up

Two surfaces, pick whichever matches your release pipeline.

**`pwa.json` (recommended for one-keystore projects):**

```json
"android": {
  "package_id": "com.example.myapp",
  ...
  "signing": {
    "keystore": "release.jks",
    "key_alias": "upload-key",
    "store_type": "pkcs12"
  }
}
```

The bundler resolves `keystore` against the project root (the directory
holding `pwa.json`), bakes the absolute path into the generated Gradle
script, and applies `signingConfigs.release` to the release build type.
`store_type` defaults to `"jks"`; set it to `"pkcs12"` if `keytool` was
run with the modern format (the JDK 9+ default).

**CLI overrides (recommended for CI matrices that vary the keystore per
target):**

```bash
swift-pwa build --target android \
    --sign /etc/secrets/release.jks \
    --android-key-alias upload-key
```

`--sign` overrides `pwa.json`'s `android.signing.keystore`;
`--android-key-alias` overrides `android.signing.key_alias`. Either
flag without the corresponding `pwa.json` setting is sufficient as
long as both keystore + alias resolve from somewhere.

### 7.3. Run the release build

Set the two password env vars and invoke `assembleRelease` (or
`bundleRelease` for an AAB):

```bash
export SWIFT_PWA_ANDROID_STORE_PASSWORD=...
export SWIFT_PWA_ANDROID_KEY_PASSWORD=...
cd build/android/MyApp-android
./gradlew assembleRelease
# app/build/outputs/apk/release/app-release.apk
```

Either env var missing fails Gradle's configure step with a clear
error pointing at the variable name — silent fallback to a debug-key
or unsigned APK would be a pit of failure for distribution pipelines.

### 7.4. CI patterns

GitHub Actions / CircleCI / similar — store the keystore as a
base64-encoded secret and decode it before the build:

```yaml
- name: Decode keystore
  run: echo "$ANDROID_KEYSTORE_B64" | base64 -d > release.jks
  env:
    ANDROID_KEYSTORE_B64: ${{ secrets.ANDROID_KEYSTORE_B64 }}
- name: Build signed APK
  run: ./gradlew assembleRelease
  working-directory: build/android/MyApp-android
  env:
    SWIFT_PWA_ANDROID_STORE_PASSWORD: ${{ secrets.ANDROID_STORE_PASSWORD }}
    SWIFT_PWA_ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
```

The `pwa.json` `android.signing.keystore` path resolves relative to
the project root, so `release.jks` decoded into the project root works
without further configuration.

## 9. On-device AI: Gemini Nano

The `ai.*` plugin's Android platform built-in is **Gemini Nano**, via
[ML Kit GenAI's Prompt API](https://developers.google.com/ml-kit/genai/prompt/android)
(backed by AICore) — the counterpart to Apple Foundation Models. See
[docs/ai-plugin.md](ai-plugin.md#available-backend-android-gemini-nano) for the
cross-platform contract; this section is the Android specifics.

Turn it on in `pwa.json` and wire the backend (which ships inside
`SwiftPWAAndroid`, so it's reachable via `import SwiftPWA`):

```json
{ "ai": { "gemini_nano": true } }
```

```swift
import SwiftPWA

runtime.run { ctx in
    #if os(Android)
        ctx.use(AIPlugin(GeminiNanoBackend()))
    #endif
}
```

`swift-pwa build --target android` then adds the
`com.google.mlkit:genai-prompt` (+ `kotlinx-coroutines-android`) Gradle
dependency and splices the `ai.gemini.*` Kotlin dispatch into the generated
`SwiftPWASystemPlugins.kt`. The Swift `GeminiNanoBackend` is a thin client:
each `ai.*` call RPCs into that Kotlin, which drives the ML Kit
`GenerativeModel`. Token streaming (`ai.generateStream`) flows back as host
events on a per-call channel — the same `nativeHostEvent` mechanism the updater
uses for `PackageInstaller` status (§6.1.2).

**Model download.** No weights ship in the APK — AICore manages the model and
fetches it on demand. `ai.info` reports `available: true` even before that
one-time download (so the page can route on it), and the page triggers the
fetch with `ai.ensureModel`, which streams coarse progress and a terminal
`done`. A device without AICore / Gemini Nano reports `available: false` and
the app falls back to its own tier.

**Device support.** The Prompt API runs best on the Pixel 10 series (Nano-v3);
it also runs on the Pixel 9 series, Galaxy Z Fold7, Galaxy S25/S26, Xiaomi 15,
and other AICore-capable devices (on the less-capable Nano-v2 there). A device
without AICore simply reports unavailable. Debug on-device the same way as any
WebView content — `adb forward` + `chrome://inspect` (§6 architecture notes).

**Beta caveat.** `genai-prompt` is a beta dependency; the generated Kotlin
targets `1.0.0-beta2` and uses fully-qualified ML Kit symbol names so the only
imports it adds are `kotlinx.coroutines`. If a future ML Kit beta renames a
symbol, the generated `SwiftPWASystemPlugins.kt` is plain Kotlin you can adjust
in place (it's regenerated on each `swift-pwa build`, so fold the fix back into
your build flow). Structured output (`ai.generateJSON`) uses the shared
prompt-and-validate fallback for now (`structuredOutput: false`).

## 9.1. On-device segmentation (`ai.vision.*`) — ONNX Runtime + `MobileSAMBackend`

**A real backend (`MobileSAMBackend`, `SwiftPWASegmentation`, gated behind
`ai.local_onnx_runtime: true` in `pwa.json` — `swift-pwa build` sets
`SWIFT_PWA_ONNXRUNTIME=1` for you) exists on Android**, verified against real
MobileSAM weights — see
[docs/proposals/segmentation-plugin.md](proposals/segmentation-plugin.md)
for the full design and current 0.8 status. `swift-pwa build --target
android --cross-compile-android` resolves + stages the vendored
`libonnxruntime.so` into `jniLibs/<abi>/` for you (`OnnxRuntimeAndroidArtifact`,
checksum-verified per ABI — only `arm64-v8a` is published today; an
unpublished ABI fails the build with an actionable message rather than
shipping a `.so`-less APK). An app opts in to the *model* with
`ctx.use(VisionPlugin(MobileSAMBackend(...)))`, either bundling weights or —
preferably on Android — using the **downloadable tier**:
`MobileSAMBackend(cacheDirectory:)` plus `ai.vision.ensureModel` fetches the
three ONNX files from the `mobilesam-vendor` release on first use
(checksum-pinned) straight to a real filesystem path. That sidesteps the "an
APK asset isn't a file ONNX Runtime can open" problem entirely — no
`fs.writeBinary` materialization step, no ~60 MB of weights in the APK.
`Examples/CritterFacts` uses this tier (device-verified on a Galaxy Z Fold7).

> **Downloads on Android don't use `URLSession`.** swift-corelibs-foundation's
> `URLSession` here is libcurl + BoringSSL with no injectable CA trust store —
> `libFoundationNetworking` only reads a fixed list of read-only Linux CA
> paths (`/etc/ssl/certs/ca-certificates.crt`, …) that don't exist on Android,
> and neither `CURL_CA_BUNDLE` nor `SSL_CERT_FILE`/`SSL_CERT_DIR` is honored,
> so any HTTPS download from Swift fails with "unable to get local issuer
> certificate". The on-device model backends (`MobileSAMBackend`,
> `LaMaBackend`, `StableDiffusionBackend`) therefore download through a Kotlin
> `net.downloadFile` RPC (`HttpURLConnection`, the platform's own system TLS),
> which mirrors `ModelDownloader`'s cache-reuse + streamed SHA-256
> verification + atomic rename. If you write an Android backend that needs to
> fetch over HTTPS, route it through the shared `AndroidFileDownload.download(…)`
> helper (or your own Kotlin HTTP), not `URLSession`.
>
> **Progress is byte-level, not per-file.** `net.downloadFile` takes an
> optional host-event `channel`; when set, the Kotlin read loop pushes
> throttled (~1 MiB) `{ bytesDone, totalBytes }` frames on it, and
> `AndroidFileDownload` forwards them to the backend's `ensureModel` stream —
> so a multi-GB, multi-file model (e.g. the ~2 GB LCM weights, 83% of which is
> one 1.7 GB UNet) reports a smoothly-advancing bar rather than freezing per
> file, matching the Apple/desktop `ModelDownloader` byte callback. An
> absent/empty `channel` keeps the plain request/response behavior.
>
> **WebSockets go through OkHttp.** `HttpURLConnection` has no WebSocket (and
> `java.net.http` isn't on Android), so `NetworkClient.openWebSocket` — used by
> the remote-AI workflow provider for per-step ComfyUI `/ws` progress — routes
> through a `net.ws.open` / `net.ws.close` Kotlin RPC backed by OkHttp, pushing
> each inbound frame to Swift as a host-event on a per-socket `channel` (the
> same side-channel shape as `net.downloadFile`). HTTPS/WSS trust is the
> system's. A live run streams fine (frames every sampling step keep the socket
> busy — device-verified, a 15-step run reported `1/15`…`15/15`), but note that
> some mobile radios reap a fully **idle** LAN socket within seconds, so a
> fast/cached run that never sustains traffic can lose it between events; the
> provider treats `/ws` progress as best-effort and reconnects, with coarse
> `queued`→`running` polling as the floor.

This section documents the packaging spike this was built on plus the
Android-specific plumbing, so anyone reproducing the toolchain locally knows
where things stand.

**No CoreGraphics/ImageIO on Android**, so `ImagePreprocessing`'s Android
half (`Sources/SwiftPWASegmentation/AndroidImagePreprocessing.swift`)
doesn't decode/resize in Swift at all — it RPCs a new `vision.
preprocessImage` method (in the generated `SwiftPWASystemPlugins.kt`) that
decodes via `android.graphics.BitmapFactory` (`decodeFile` for a plain
path, `decodeStream` off a `ContentResolver` for a `content://` SAF pick,
`decodeByteArray` for inline `dataBase64`), resizes with
`Bitmap.createScaledBitmap` to match the same resize-longest-side-to-1024
math the Apple side uses, and returns the raw RGB bytes base64-encoded —
same generic JNI RPC bridge (`AndroidRPC.call`, now `public` so a
cross-module target can reach it) `AndroidArchiveExtractor` uses for zip
work. `MobileSAMBackend` itself, `OrtRuntime`, and `OrtModelSession` are
otherwise identical Swift on both platforms — only the image-decode step
differs.

Unlike llama.cpp (no Android backend at all in this repo), Microsoft ships
a usable prebuilt Android artifact for ONNX Runtime — the
`onnxruntime-android` Maven AAR bundles the plain C API headers plus a
per-ABI `libonnxruntime.so` directly, so Swift can call the C API without
any JNI glue. `Scripts/vendor-onnxruntime-android.sh` downloads +
sha1-verifies it (against Maven's own published sidecar) and vendors:

- `Vendor/onnxruntime-android-headers/` — **committed**, a plain
  `.systemLibrary` (`ONNXRuntimeAndroid` in `Package.swift`, gated behind
  `SWIFT_PWA_ONNXRUNTIME`).
- `Vendor/onnxruntime-android/<abi>/libonnxruntime.so` — **gitignored**;
  found at cross-compile link time via `LIBRARY_PATH`, the exact mechanism
  [docs/ai-plugin.md](ai-plugin.md#available-backend-llamacpp) already
  describes for Linux's llama.cpp build (no `unsafeFlags`).

Cross-compiling anything against the installed Android Swift SDK on this
toolchain **requires the matching Swift 6.2 host toolchain**, not Xcode's
newer default, or you'll hit "module compiled with Swift 6.2 cannot be
imported by the Swift 6.3.x compiler" errors.

`swift-pwa build --cross-compile-android` (and `swift-pwa deploy --target
android`) **selects it for you** on a macOS host: it reads the Swift release
the installed Android SDK bundle needs and exports the matching
`~/Library/Developer/Toolchains/swift-<version>-RELEASE.xctoolchain` bundle id
as `TOOLCHAINS` for the cross-build (printing which one it picked). An explicit
`TOOLCHAINS` in your environment still wins, so you can override it.

You only need to set `TOOLCHAINS` by hand when invoking `swift build
--swift-sdk` **directly** (the CLI's auto-selection doesn't reach a raw
`swift build`), as the spike's verification did — set
`TOOLCHAINS=org.swift.6200202509111a` (or whatever id
`~/Library/Developer/Toolchains/swift-6.2-RELEASE.xctoolchain` resolves to on
your machine):

```bash
export TOOLCHAINS=org.swift.6200202509111a
export SWIFT_PWA_ONNXRUNTIME=1
export LIBRARY_PATH="$(pwd)/Vendor/onnxruntime-android/arm64-v8a"
swift build --swift-sdk aarch64-unknown-linux-android28 --target SwiftPWAONNXRuntimeAndroidSmoke
```

Verified end-to-end, including on an actual device: a throwaway executable
linked against the vendored `.so` this way, then pushed via `adb push` +
run via `adb shell` (with `LD_LIBRARY_PATH` pointed at the pushed `.so`,
the Swift Android runtime libs from the SDK artifact bundle, and the
NDK's `libc++_shared.so`) on a Galaxy Tab S10+ — printed the real ONNX
Runtime version string. `SwiftPWAONNXRuntimeAndroidSmoke` itself (the
committed target) is a plain library with no product forcing a real link
yet, so `swift build --target` against it only proves compile +
module-resolution; the link+runtime proof lives in that throwaway
executable, not in anything committed to this repo.

The real `MobileSAMBackend` (`SwiftPWASegmentation` target) is verified the
same way at the link level — a throwaway executable depending on the
`SwiftPWASegmentation` product, built with the same
`TOOLCHAINS`/`LIBRARY_PATH`/`--swift-sdk` invocation, links successfully
with `OrtGetApiBase@VERS_1.27.0` showing as an undefined symbol resolving
against the real vendored `.so` (`nm` on the resulting binary, not a stub).

Beyond that, a **full on-device `openSession`/`segment` round trip through
the `vision.preprocessImage` RPC bridge is verified**, using
`Examples/CritterFacts` (a real `swift-pwa build --target android`
app, not a throwaway executable) on a Galaxy Z Fold7 against a real photo:
`ai.vision.openSession` on a 6018×4024 kitten photo (fetched from the
app's own bundled web asset, base64'd to `dataBase64`) succeeded, and
`ai.vision.segment` with a point prompt + `multimask: true` returned 4
ranked masks (best IoU ~0.99) whose decoded RLE, rendered back onto the
source photo, precisely outlined the prompted kittens — visually confirmed,
not just checked by shape. See `Examples/CritterFacts/Sources/CritterFacts/
CritterFacts.swift`'s `configure(_:)` and `web/mobilesam.js` for the
bundled-weights + on-device-materialize pattern this used (also documented
in the proposal doc). At the time of that round trip, `swift-pwa build
--target android` didn't yet stage the vendored `libonnxruntime.so` into
`jniLibs/`, requiring a manual `cp` before `./gradlew assembleDebug` (or
`UnsatisfiedLinkError: ... library "libonnxruntime.so" not found` at
launch) — `OnnxRuntimeAndroidArtifact` + `AndroidBundler.stageJniLibs` now
do this automatically, the same way the Swift runtime stdlib libs are
staged.

## 8. Known limitations

- **Camera, microphone and location need a declaration in two places.**
  `permissions.web` in `pwa.json` emits the `uses-permission` entries;
  `ctx.permissions.declare(…)` is the runtime ceiling. `swift-pwa build`
  cross-checks them on host builds and says so when cross-compiling (it
  can't run the app to compare). Undeclared requests are refused and the
  reason goes to `adb logcat` under the `swift-pwa` tag — an app process's
  stderr goes to `/dev/null` on Android, so that's the only place it can
  surface. Full API: [docs/permissions.md](permissions.md). Note a
  microphone declaration emits **`MODIFY_AUDIO_SETTINGS` as well as
  `RECORD_AUDIO`**, because Chromium's audio manager needs both — with only
  the latter, `getUserMedia` fails `NotReadableError` ("Could not start
  audio source") *after* the user grants the permission.

- **`dialog.openDirectory` multi-select is desktop-only.** The
  cross-platform `multiple` flag (added in 0.7.7) is honored on macOS /
  Windows / GTK / iOS, but Android's `ACTION_OPEN_DOCUMENT_TREE` grants
  one directory tree per launch — there's no multi-tree SAF picker. On
  Android `multiple` is ignored and the result carries at most one path
  (`paths` has 0–1 entries; `path` is the first or `null`). Apps that
  need several trees prompt the user once per folder.

- **SAF dialog results are `content://` URIs, not filesystem paths.**
  The cross-platform `Dialog` API returns these URI strings in the
  same `[String]` slot the desktop backends fill with paths. **The
  `Fs` plugin handles them transparently** — `fs.readBinary` /
  `writeBinary` / `metadata` / `exists` route URI-shaped paths
  through `AndroidContentResolver` (a `FsContentResolver` registered
  process-wide by `AndroidAppContext`), so apps can pass a
  `dialog.openFile` result straight to `fs.readBinary` without
  branching on prefix. `fs.listZip` / `fs.extractZip` likewise accept a
  `content://` archive as their `from`: the SAF pick is read off-bridge via
  the `ContentResolver` (a `ZipInputStream`), so a user-picked pack imports
  directly with no `readBinary`→`writeBinary` materialize — though the
  extract **destination** must still be a real path (SAF exposes no writable
  tree). `fs.mkdir` / `remove` / `readDir` / `copy` /
  `rename` deliberately reject `content://` URIs with a clear error
  (`SAF doesn't expose this operation`) rather than silently
  misbehaving — SAF doesn't have directory-style POSIX semantics for
  content providers. Apps that need to walk a tree URI from
  `OpenDocumentTree` should drive the `DocumentFile` /
  `DocumentsContract` API directly (out of scope for the cross-
  platform `Fs` surface).
- **A picked URI only survives a relaunch as a bookmark.** SAF's grant
  from a picker lasts as long as the task, so a `content://` URI stashed
  in `localStorage` throws the next time the app starts. The runtime asks
  for a *persistable* grant
  (`ContentResolver.takePersistableUriPermission`) for every pick and
  returns the URI as a token in `bookmarks` / `bookmark`; hand that to
  `dialog.resolveBookmark` on a later launch and it verifies the grant is
  still held (the user can revoke it in Settings → the app's permissions)
  and that the document still exists, then hands the URI back — or `null`
  when either check fails. A tree pick takes read+write; a read-only
  document pick that refuses the write flag falls back to read rather than
  losing the grant altogether. Android's per-app cap on persisted grants
  (a few hundred) is the practical limit on how many locations an app can
  remember. Cross-platform contract:
  [docs/javascript-api.md](javascript-api.md#dialog).
- **Delta / split APKs not supported.** Only single-APK updates
  work through `AndroidUpdater`; AAB / split-by-density support is
  on the roadmap. The Ed25519 signature pins the artifact identity
  separately from the platform's same-key check on the APK signing
  cert (see `AndroidUpdater`'s type docstring for why both).
- **API 28 floor.** Driven by the Swift Android SDK 6.2's
  `targetTriples` map, which only declares triples for API 28–36.
  See §1's "Why the API 28 floor" callout.
- **Tray is unimplemented, indefinitely.** Android has no system-tray
  surface analogous to macOS' menu bar / Windows' notification area;
  the closest equivalent (a foreground service with a persistent
  notification) would be a heavy and Android-specific UX, not a
  drop-in for the desktop tray API. Revisit if Android's rumored
  ChromeOS crossover lands and brings a real desktop shell with it.
  Until then `TrayPlugin` isn't registered on Android — calls to
  `tray.*` reject with `E_NO_HANDLER`. Cross-platform code should
  gate on `__platform.info.commands` (see `Examples/HelloPWA`'s
  `data-requires="tray.setMenu"` capability gating for the pattern).
- **Content packs: extraction/creation are `java.util.zip`, served mounts
  are declared in `pwa.json`.** `fs.extractZip` / `fs.listZip` /
  `fs.createZip` work on Android, but **not** via ZIPFoundation — it can't
  build against Bionic libc (`lstat` / `errno` / `S_IF*` / `mode_t`
  mismatches), so the Android backend routes extraction *and creation* to
  Kotlin's `java.util.zip` over the JNI bridge (`AndroidArchiveExtractor`,
  with the traversal / symlink / zip-bomb guards enforced Kotlin-side).
  `extractZip` / `listZip` also take a `content://` source directly (a SAF
  pick) — see the SAF `content://` note above — so importing a user-picked
  pack needs no materialize step. One create caveat: `compression: "stored"` maps to a single-pass
  deflate-level-0 entry (java.util.zip's true STORED method needs a CRC
  pre-pass — a second read of every file — which a multi-GB export can't
  afford); the output is a valid zip either way. Apps select it per
  platform: `#if os(Android) AndroidArchiveExtractor() #else
  ZIPExtractor() #endif` (see `Examples/HelloPWA`). For **serving**,
  the `WebViewAssetLoader` is built at `Activity.onCreate` — *before*
  any Swift `configure()` runs — so a mount that must exist at startup
  has to be declared in `pwa.json`'s `build.serve`
  (`{ "mount": "/packs", "from": "data/packs" }`, rooted at the
  app's `filesDir` / `cacheDir`); the bundler wires each into the
  generated Activity as an `addPathHandler`. A runtime
  `ctx.serveDirectory(_:at:)` for an *undeclared* prefix is a desktop
  capability and won't take effect on Android. The
  `fs.extractZipProgress` / `fs.createZipProgress` streams emit a single
  terminal progress tick on Android (the unary JNI RPC has no per-entry
  channel), then `done`.

## 8. Troubleshooting

- **`UnsatisfiedLinkError: Native method not found: ...swiftPwaMain`**
  — your `@_cdecl` symbol name doesn't match the Java package +
  class. The expected name is
  `Java_<package>_MainActivity_swiftPwaMain` with dots replaced by
  underscores. Double-check `pwa.json`'s `android.package_id`.
- **`assembleDebug` fails on `jniLibs is empty`** — see §4 above;
  either re-run with `--cross-compile-android` or drop the `.so`s
  in by hand.
- **Page loads but `__SWIFT_PWA__.invoke` rejects with
  `native message handler unavailable`** — the
  `addJavascriptInterface(JsBridge(...), "__SwiftPWA__post")` call
  is missing. Most likely the generated `SwiftPWABridge.kt` was
  edited; re-running the bundler restores it.
