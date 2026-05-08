# swift-pwa on Android (android.webkit.WebView via JNI)

The Android backend compiles your Swift code to a shared object (`.so`)
that a Kotlin `Activity` loads via `System.loadLibrary`. The Activity
hosts a stock `android.webkit.WebView` (Chromium-backed since Android
7.0) and exposes a JS↔Swift bridge through `addJavascriptInterface` +
`evaluateJavascript`. The CLI's `swift-pwa build --target android`
emits a Gradle project that wraps the `.so`, your web bundle, and a
generated `MainActivity` + `SwiftPWABridge`.

> **Status: v0.5.x — plugin set caught up to desktop parity, verified
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
| JDK 17 *(for `assembleDebug`)*       | any 17.x                   | `brew install openjdk@17` and set `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home` |
| Android SDK Platform-Tools (`adb`)   | latest                     | Bundled with Android Studio, or `sdkmanager "platform-tools"`                                          |
| Gradle wrapper                       | **8.10.2 (vendored)**      | Shipped inside the generated scaffold (`gradlew`, `gradlew.bat`, `gradle/wrapper/*`); no separate install needed. AGP 8.5 + Kotlin 2.0 dependencies are resolved on first wrapper run. |

> **Why `swift install 6.2.0` and not just `6.2`.** The SDK bundle's
> Swift modules were built with Swift 6.2 (i.e. 6.2.0). Swift's
> `.swiftmodule` format isn't ABI-stable across patch versions yet, so
> a 6.2.4 compiler refuses to import 6.2.0 modules with `module
> compiled with Swift 6.2 cannot be imported by the Swift 6.2.4
> compiler`. `swiftly install 6.2` resolves to the latest patch (which
> at time of writing is 6.2.4); use `6.2.0` explicitly.

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
            └── assets/
                ├── web/                                # copied from ../web/
                └── swift_pwa/bridge.js                 # injected at page-start
```

The `swift_pwa` namespace is reserved — don't put your own assets in
it; the bundler manages it.

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

> Why a manual `@_cdecl` instead of a generated wrapper? Because the
> exported symbol's name has to embed the user's Java package id,
> which the Swift target itself doesn't know about. Codegen for this
> is on the v0.5.x roadmap; for now, the boilerplate is one file.

## 4. Cross-compile + bundle

Two paths:

**A. Generate scaffold only** (default; works on any host):

```bash
swift-pwa build --target android
# Built: build/MyApp-android
# Next: cd 'build/MyApp-android' && ./gradlew assembleDebug
```

You'll see a note that `jniLibs/` is empty. Drop your built `.so`s in
manually (note: pass the triple as `--swift-sdk <triple>`, not as
`--triple` — see §1's API 28 footnote for why):

```bash
swiftly run +6.2.0 swift build -c release --swift-sdk aarch64-unknown-linux-android28
mkdir -p build/MyApp-android/app/src/main/jniLibs/arm64-v8a
cp .build/aarch64-unknown-linux-android28/release/MyApp \
   build/MyApp-android/app/src/main/jniLibs/arm64-v8a/libMyApp.so
```

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

The bundler also drops a vendored Gradle 8.10.2 wrapper into the
generated project (`gradlew`, `gradlew.bat`, `gradle/wrapper/*`) so
`./gradlew assembleDebug` works straight out of the scaffold — no
separate Gradle install required, just JDK 17. The wrapper itself
fetches Gradle 8.10.2 from `services.gradle.org` on first run; cache
hits are zero-cost thereafter.

```bash
cd build/MyApp-android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
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
- **Multi-window is not supported in v0.5.** Android's
  Activity-per-window model doesn't map cleanly onto desktop multi-
  window UX, and `Activity.startActivity` plumbing is queued for
  v0.5.x. Calling `context.createWindow` more than once replaces the
  active window's content rather than spawning a second Activity.
- **Most `Window` shape APIs are no-ops** (`setSize`, `setPosition`,
  `minimize`, `maximize`, `focus`). The platform owns those decisions
  on Android. `Window.setFullscreen(true)` is a stub — wiring
  `WindowInsetsControllerCompat` is on the v0.5.x list. See
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
| `SystemDialog`        | `AlertDialog.Builder` for message / confirm; Storage Access Framework (`OPEN_DOCUMENT` / `CREATE_DOCUMENT` / `OPEN_DOCUMENT_TREE`) for file pickers  | **SAF returns `content://` URIs, not filesystem paths.** Apps that need bytes should resolve via `ContentResolver`. `DialogFileFilter.extensions` map to MIME types via a small built-in table; unknown extensions fall back to `*/*`.                                                             |
| `SystemBiometricAuth` | `androidx.biometric.BiometricPrompt`                                                                                                                 | The host `MainActivity` extends `AppCompatActivity` (a `FragmentActivity` subclass) so the prompt can attach. `BiometricKind` is always `.unknown` when available — Android's `BiometricManager` doesn't distinguish fingerprint / face / iris at the API level.                                  |
| `AndroidUpdater`      | `PackageInstaller.Session`                                                                                                                           | Self-installing APKs requires the `REQUEST_INSTALL_PACKAGES` manifest permission **plus** the per-app "Install unknown apps" toggle — the system installer surfaces a dialog routing the user to settings if the toggle is off. The plugin still verifies Ed25519 over the artifact bytes itself. |
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
inline before gradle sees them. The bundler resolves
`llvm-strip` from `$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/<host>/bin/`
— necessary because AGP's own `stripDebugDebugSymbols` task only finds
the strip tool when an SDK-manager-installed NDK lives at
`$ANDROID_HOME/ndk/<version>/`, and the Swift-on-Android dev setup
pins a standalone NDK at `$ANDROID_NDK_HOME` instead. The unstripped
binary stays in `.build/<triple>/release/<Name>` for `swift symbolicate`
to consume during crash triage.

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

## 7. Known limitations (v0.5.x)

- **SAF dialog results are `content://` URIs, not filesystem paths.**
  See §6.1's `SystemDialog` row. Apps written against the
  cross-platform `Dialog` API expecting `[String]` of paths will
  receive URI strings on Android. Transparent URI → cache-file
  resolution is queued for v0.5.x once the `Fs` plugin grows URI
  support.
- **Updater install result isn't observable.** `PackageInstaller.Session`
  reports accept / reject via a `BroadcastReceiver`; the bundler's
  receiver logs the result to logcat but doesn't surface it through
  the `Updater` protocol's stream. `installAndRelaunch` returns once
  the session has been committed; the user accepting / rejecting
  the system prompt happens after this method returns. Apps that
  need to act on success / failure should listen for
  `PackageInstaller.STATUS_*` broadcasts via their own receiver.
- **`swift-pwa init MyApp` doesn't generate the Android boilerplate.**
  The `@_cdecl("Java_..._swiftPwaMain")` entry point is described
  in §3 but not auto-emitted by `swift-pwa init`; v0.5.x will add it.
- **No code-signing wiring.** `--sign` is a Mac/iOS flag today.
  Android signing goes through Gradle's `signingConfigs`; until
  the bundler emits one, `assembleRelease` requires the user to
  edit `app/build.gradle.kts` and add their keystore manually.
- **API 28 floor.** Driven by the Swift Android SDK 6.2's
  `targetTriples` map, which only declares triples for API 28–36.
  See §1's "Why the API 28 floor" callout.
- **Tray is a no-op stub.** Android has no system-tray surface
  analogous to macOS' menu bar / Windows' notification area; the
  closest equivalent (a foreground service with a persistent
  notification) would be a heavy and Android-specific UX, not a
  drop-in for the desktop tray API.

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
