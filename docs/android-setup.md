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

### There is no project-wide Swift version

**The Swift Android SDK you install decides the Swift release, per machine.**
There is no number this project pins, and deliberately so — the hosts that
build it cannot agree on one. From Xcode 27 a Mac has no choice at all (see the
Xcode callout below); a Linux or Windows box is free to sit on whatever its
toolchain manager gave it. Forcing one release across a fleet buys nothing the
matching doesn't already do, and CI cannot enforce it either way: the `android`
CI job is scaffold-only on purpose, because a hosted runner can't cross-compile
this reliably. Device verification happens on real hardware instead.

So the rule is per-host, and the CLI does the matching:

- the installed SDK bundle's name carries the release it needs
  (`swift-6.4.0-RELEASE_android` → Swift 6.4);
- `swift-pwa build --cross-compile-android` selects a toolchain for it — via
  `TOOLCHAINS` on macOS, `swiftly run +<release>` elsewhere — and prints which;
- `swift-pwa doctor --target android` reports whether this host has one
  *before* you spend a cross-compile finding out, e.g.

  ```text
  ✓ Android SDK / toolchain match: swift-6.4.0-RELEASE_android needs Swift 6.4 — swift-6.4.0-RELEASE.xctoolchain is installed
  ✓ Android SDK / toolchain match: swift-6.2-RELEASE-android-0.1 needs Swift 6.2; the ambient swift is 6.3, so the cross-compile runs under `swiftly run +6.2`
  ```

Version numbers below are examples of the shape, not a supported set. The one
check that *does* run everywhere is `ManifestDependencyDriftTests`, and it is
about declared dependencies, not toolchains.

### What you need

The cross-compile path verified against this repo's `Examples/HelloPWA`:

| Component                            | Version                    | Install                                                                                                |
|--------------------------------------|----------------------------|--------------------------------------------------------------------------------------------------------|
| Swift toolchain                      | **exactly the SDK's release** | `brew install swiftly && swiftly init && swiftly install <version>` — must match the SDK exactly (see §2) |
| Swift Android SDK                    | e.g. swift-6.4.0-RELEASE_android | `swift sdk install <bundle-url> --checksum <sha>` — take both from the "Swift SDK for Android" download link on <https://www.swift.org/install/macos/> (the path is not guessable from `releases.json`) |
| Android NDK                          | **r27d**                   | <https://dl.google.com/android/repository/android-ndk-r27d-darwin.zip> (or the linux/windows variant)  |
| Setup script                         | (run once, older SDKs)     | `ANDROID_NDK_HOME=~/android-ndk-r27d ~/Library/org.swift.swiftpm/swift-sdks/<bundle>.artifactbundle/swift-android/scripts/setup-android-sdk.sh` |
| JDK 17 *(for `assembleDebug`)*       | any 17.x                   | `brew install openjdk@17` — no `JAVA_HOME` export needed, see [§Toolchain discovery](#toolchain-discovery) |
| Android SDK *(for `assembleDebug`)*  | latest                     | Android Studio, or the command-line tools. Found automatically in the standard location; else set `ANDROID_HOME` |
| Android SDK Platform-Tools (`adb`)   | latest                     | Bundled with Android Studio, or `sdkmanager "platform-tools"`                                          |
| Gradle wrapper                       | **8.10.2 (vendored)**      | Shipped inside the generated scaffold (`gradlew`, `gradlew.bat`, `gradle/wrapper/*`); no separate install needed. AGP 8.5 + Kotlin 2.0 dependencies are resolved on first wrapper run. |

> **Install the exact patch version, not the `major.minor`.** Swift's
> `.swiftmodule` format isn't ABI-stable across patch versions, so a compiler
> one patch ahead of the SDK refuses to import its modules — `module compiled
> with Swift 6.2 cannot be imported by the Swift 6.2.4 compiler`. `swiftly
> install <major.minor>` resolves to the *latest* patch, which is how you end
> up there; name the SDK's own version.

> **On a Mac, the toolchain also has to satisfy Xcode's SDK.** From Xcode 27
> (Swift 6.4), the macOS SDK passes `-target-arch-variant`, which earlier
> compilers reject — measured on 6.2 and 6.3.3, both of which then fail to
> compile *any* `Package.swift` with the misleading `cannot find 'Data' in
> scope`. So the Android SDK has to be one whose release matches the host
> Xcode's Swift, and that toolchain installed alongside it. Two traps getting
> there: `swiftly install 6.4.0` fails on a URL it builds wrong for `x.y.0`
> releases (install the `.pkg` from download.swift.org directly —
> `installer -pkg … -target CurrentUserHomeDirectory`, no sudo), and **Xcode's
> own Swift is a different build from the swift.org release of the same
> number**, so it cannot load the SDK's prebuilt modules. Use the swift.org
> toolchain, via `TOOLCHAINS=<its bundle id>`.

The bundler smooths over the toolchain-selection part of that pin:

> **The bundler selects the matching toolchain for you.** You don't need to
> wrap `swift-pwa build --cross-compile-android` in `swiftly run +<version>` —
> the bundler parses the SDK's version and, when the ambient `swift` isn't
> already that release, runs the inner `swift build --swift-sdk` under
> `swiftly run +<major.minor>` itself, which overrides any repo
> `.swift-version` (this repo pins `6.0`, which would otherwise mispin the
> Android build). When the ambient toolchain *does* match — the normal case on
> a Mac, where the matching release may be one swiftly cannot serve — it is
> used directly, because `swiftly run` refuses outright for a toolchain it
> doesn't have rather than falling back. If a requested ABI can't be built, the
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

`swift-pwa doctor --target android` prints where each piece was found — plus
whether this host has a toolchain for the installed Swift Android SDK's release
(see [§There is no project-wide Swift version](#there-is-no-project-wide-swift-version)) —
and `deploy` fails up front, before the multi-minute cross-compile, when the JDK
or SDK is missing, rather than letting Gradle report it at the end.

A second pin worth knowing about, derived from the SDK's own metadata:

> **Why the API 28 floor.** This is swift-pwa's clamp, not the SDK's any
> more. It started as the SDK's: the 6.2 distribution's `swift-sdk.json`
> declared target triples for API 28–36 only, having dropped the older API 24
> floor, and SwiftPM silently resolves to a wrong-arch resource path when
> asked for a triple that isn't declared. The 6.4 SDK declares API **23**–36
> again (measured against the installed bundle), so the bundler's clamp to 28
> — applied with a warning when `pwa.json`'s `android.min_sdk` is lower — is
> now a swift-pwa floor rather than a toolchain limit. Lowering it needs a
> verified build and an on-device run at the lower API, so it stays until
> someone needs it.

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

When `pwa.json`'s icon (`android.icon` when set, else the top-level
`icon`) is a PNG, the bundler copies it to
`res/mipmap/ic_launcher.png` and wires `android:icon="@mipmap/ic_launcher"`
into the manifest; aapt/Gradle scale it per density at build time (a
single source PNG is enough); adaptive-icon artwork — a separate
foreground and background layer — isn't modelled, so the launcher icon is
one flattened image. Without an icon, the platform default
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
swiftly run +<sdk-version> swift build -c release --swift-sdk aarch64-unknown-linux-android28
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
swift run --package-path /path/to/swift-pwa swift-pwa \
    build --target android --cross-compile-android --android-abis arm64-v8a,x86_64
```

The CLI runs `swift build --swift-sdk <android-triple>` for each
requested ABI (clamping API to ≥28 to match the SDK's
`targetTriples` map), then copies the resulting Swift binary into
`app/src/main/jniLibs/<abi>/libMyApp.so` (renaming from SwiftPM's
default `MyApp` output name to the JNI loader's `lib*.so`
convention). An ABI that fails to build is a **hard error**: an APK without a
Swift `.so` installs fine and then crashes at launch with
`UnsatisfiedLinkError`, so it is not something to warn about and continue past.

The link also runs with `-Xlinker --no-undefined`. An Android product is linked
`-shared`, and a shared object is *allowed* to have undefined symbols — so a
dependency missing from the link produces a green build and an app that dies at
load with `cannot locate symbol "…"`. That is exactly how a `Crypto` edge
missing from `SwiftPWACore`'s manifest shipped a crashing APK under Swift 6.4's
`swiftbuild` engine, which builds link lists from declared edges. The flag turns
it into a link error naming the symbol.

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

### Vendoring a native library (`android.native_library_dirs`)

If your app links a native library the NDK doesn't ship — SQLite built for
Android, say, because GRDB needs one — name the directory holding its headers
and the directory holding its binaries, and the build finds both:

```json
"android": {
  "abis": ["arm64-v8a", "x86_64"],
  "native_include_dirs": ["Vendor/sqlite/include"],
  "native_library_dirs": ["Vendor/sqlite/<abi>"]
}
```

**Both keys, and the header one matters first.** `native_include_dirs` goes on
the header search path of every C compile and clang-module build in your
package (`-Xcc -I<dir>`), which is what lets a C shim's `#include <sqlite3.h>`
resolve — GRDB's `GRDBSQLite/shim.h` is exactly that one line. Without it the
build stops at the first Swift module importing that shim, with
`'sqlite3.h' file not found`, long before any of the library half below is
reached. They're separate keys because they're separate directories in the
usual layout: the library is per-ABI and the header, being
architecture-independent, is not. `<abi>` is substituted in both, for the
layouts where the headers really are per-ABI.

**`<abi>` is substituted per ABI**, and that is the point. The bundler
cross-compiles every ABI in one process, so a global search path — the
workaround you'd otherwise be left with — can only ever carry one ABI's copy of
the library; a multi-ABI build with a vendored library simply isn't expressible
that way. Each resolved directory goes on that ABI's link search path, and
every `.so` in it is staged into `jniLibs/<abi>/` beside the app's own binary.
The second half matters as much as the first: the Gradle scaffold is
regenerated on every build, so a `.so` you copy in by hand is gone next time,
and the APK then installs and dies at launch with `UnsatisfiedLinkError`.

Paths are relative to the project root (the directory holding `pwa.json`); an
absolute path is used as given. A directory that isn't there fails the build,
naming the entry — rather than reaching the linker as
`unable to find library -lsqlite3`, which names neither. Everything shared in
the directory is staged, not just what the built `.so`'s `DT_NEEDED` list
mentions, because a library the app `dlopen`s by name is in neither list and
its absence would only show up on a device.

**Build the library 16 KB page-aligned** — `-Wl,-z,max-page-size=16384` on the
link. Android 15+ requires it, and a `.so` without it is refused outright on a
16 KB-page device. Everything swift-pwa stages beside your library is already
aligned (the Swift Android SDK's runtime, `libc++_shared.so`, and your app's own
`.so`); a hand-built vendored library is the one that usually isn't, because a
bare `clang -shared` still defaults to 4 KB. A debuggable build tells you on
launch — Android pops an *"App Compatibility"* dialog listing what failed the
check — but a release build does not, so it's worth checking with
`llvm-readelf -lW <lib> | grep LOAD` (the alignment column should read `0x4000`).

Both keys exist for [Linux](linux-setup.md) and [Windows](windows-setup.md)
(without `<abi>` — they link one architecture per build). On Apple, use a
`.binaryTarget` xcframework, which SwiftPM resolves for you and which carries
the code-signing and rpath details a directory of loose dylibs does not.

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

The other backends resolve the same pair at runtime rather than at build
time, each against its platform's appearance signal — `UIColor` /
`NSColor` dynamic providers on Apple,
`GtkSettings:gtk-application-prefer-dark-theme` on Linux,
`AppsUseLightTheme` on Windows — and re-resolve it
when the user switches themes under a running app. See
[README.md](../README.md#configuring-pwajson). Device-verified on a Galaxy
Tab S10+: `prefers-color-scheme` reports `dark` in night mode and `light`
otherwise, tracking the system toggle.

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

### Deep links (`url_schemes`)

Declare the URL schemes your app handles and a `myapp://…` link — tapped in a
browser, a mail client, a chat app, or fired from `adb` — opens your app, with
the URL delivered on the `app.openURL` event channel (see
[javascript-api.md](javascript-api.md#appopenurl--inbound-deep-links)). The key
is **top level**, not under `android`, because a URL scheme is the same string
on every platform:

```json
"url_schemes": ["myapp"]
```

> **An OAuth callback arrives on this same channel**, which is how
> `auth.authorize` catches it on Android: the redirect is an `ACTION_VIEW` intent
> on the app's declared scheme, and the flow resolves on the first URL whose
> `state` matches while everything else stays an ordinary deep link. Declare the
> provider's scheme here — for Google that's the *reversed client ID* from the
> Android OAuth client, which is also why `redirect: 'auto'` won't guess it. See
> [docs/auth.md](auth.md).

Each scheme becomes a `<data android:scheme="…"/>` spec on one generated
`ACTION_VIEW` intent-filter carrying both `DEFAULT` and **`BROWSABLE`**
categories. `BROWSABLE` is the load-bearing one: without it the filter matches
an intent another app builds by hand but *not* a link tapped in a browser or a
mail client — which is where deep links actually come from — and the failure is
silent (the link just doesn't open the app).

`MainActivity` routes the arriving intent by the URI's scheme: `content:` and
`file:` are documents and go to `app.openFile`, anything else is a deep link
and goes to `app.openURL`. A share-sheet stream is always a document, so
`ACTION_SEND` never routes to the URL channel.

Try it with:

```bash
adb shell am start -a android.intent.action.VIEW -d "myapp://hello"
```

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

### Declaring an Android permission (`android.permissions`)

`permissions.web` in `pwa.json` declares capabilities the *web platform* has a
name for — camera, microphone, geolocation — and the bundler maps each onto
whatever Android calls it, and `permissions.device` covers the two the runtime
knows by name without a web counterpart (`bluetooth`, `allFiles`). Anything
else can't come through either door: before this key, the only way to declare
an OEM permission or a platform one swift-pwa doesn't model was hand-editing
the generated `AndroidManifest.xml`, which the next `swift-pwa build`
overwrites.

```json
"android": {
  "permissions": ["com.samsung.android.permission.SSENSOR"]
}
```

> For All-files access, prefer
> [`permissions.device: ["allFiles"]`](#all-files-access). It emits the same
> `<uses-permission>` element, and it is the spelling `swift-pwa build`
> cross-checks against `ctx.permissions.declare(.allFiles)` — the ceiling the
> runtime reads before it will ask the user for anything.

Each entry is emitted verbatim as a `<uses-permission>` element, after the
built-in and web-derived ones, with duplicates dropped — so naming something
swift-pwa already declares is a no-op. Give the fully-qualified name Android
uses (`android.permission.X`, or an OEM's own
`com.samsung.android.permission.X`); a bare `MANAGE_EXTERNAL_STORAGE` is
refused at build time, before anything is compiled. There is deliberately **no
allowlist** of known permissions: OEMs define their own and new platform
releases add more, so a list here would go stale and start refusing valid
declarations.

Declaring grants nothing. A *dangerous* permission still needs its runtime
request, and a *special* one like All-files access needs a hand-off to Settings
— the declaration is only what makes that request possible. Some permissions
carry store-policy consequences; that is the app's call to make, and not a
reason the manifest can't express it.

### Where an app's own files go, and what that needs (nothing)

**Start here before reaching for All-files access.** Since Android 11 an app can
create, list and read **its own** files in shared storage by path, with no
permission at all. All-files access is only what lets it see what *everything
else* put there. That changes the shape of a default install: the app's library
can be an ordinary folder in Documents, needing no grant and surviving
uninstall.

`app.documentsDir` (`ctx.documentsDirectory()` in Swift) resolves to
`/sdcard/Documents/<App>` and creates it:

```js
const { path, survivesUninstall } = await __SWIFT_PWA__.invoke('app.documentsDir');
await __SWIFT_PWA__.invoke('fs.writeText', { path: path + '/book.txt', contents });
```

Because it is a **real path**, `ctx.serveDirectory(ctx.documentsDirectory(), at: "/library")`
mounts it and a `Range` request streams from it — so a reader opens a 400 MB PDF
without loading it. It is visible in the Files app, and its contents outlive the
app: measured on a Fold7 (Android 16), the file was still there after
`adb uninstall`, while `Android/data/<id>/files` was gone.

> **A file the app may not read still answers `fs.exists`.** Measured on a
> Fold7 with the permission denied, against a file another uid had put in the
> app's *own* Documents folder, the three questions gave three different
> answers:
>
> | | Result |
> | --- | --- |
> | `fs.readDir` on the folder | the file is **not in the listing** |
> | `fs.exists` on its exact path | **`true`** |
> | `fs.readBinary` / `readText` | **denied** |
>
> So an app that checks `exists` before reading gets a yes and then fails, and
> an app that scans a folder it may not read draws an **empty shelf** rather
> than an error and concludes the user has no books. Neither reads as a
> permission problem. If a scan comes back empty, check whether the folder is
> one the app itself wrote.

Ownership goes with the uid, not the path: after an uninstall and reinstall the
app sees none of its old files again, even though they are still on the device
and still visible in Files. Treat the folder as the *user's*, and re-import
rather than assuming continuity.

### All-files access

All-files access is the **upgrade**, not the price of entry: it is what lets an
app read the books that were already on the device, in folders it didn't write.
An app whose library is the user's own existing folders needs *paths* — a
`FileManager` walk, a rescan, a sidecar file beside the original — and on
Android those mean `MANAGE_EXTERNAL_STORAGE`. Declare it by name and the runtime
handles both the manifest entry and the request:

```json
"permissions": { "device": ["allFiles"] }
```

```js
const { state } = await __SWIFT_PWA__.invoke('permissions.status', { name: 'allFiles' });
if (state === 'denied') {
    await __SWIFT_PWA__.invoke('permissions.request', { name: 'allFiles' });
}
```

The Swift form is `ctx.permissions.declare(.allFiles)` plus
`await ctx.permissions.status(.allFiles)` / `.request(.allFiles)`, and both work
on all five platforms — see [permissions.md](permissions.md#asking-for-the-capability-no-web-api-asks-for)
for what the other four answer. Three Android-specific things:

- **There is no dialog.** From API 30 this is a *special* permission granted
  only from a Settings screen; `request` sends the user to the per-app screen
  (`ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`) and resolves when they come
  back, whether or not they granted it. Below 30 it is the ordinary runtime
  storage pair and raises a normal prompt, so the app's own code doesn't branch
  on the OS version.
- **Undeclared reads as `unavailable`, not `denied`.** The Settings screen shows
  nothing for an app whose manifest never asked, so a hand-off there would be a
  button that visibly does nothing.
- **Play may refuse the declaration.** All-files access is restricted to apps
  whose core function needs it, and a rejected app ships without the permission
  — where the runtime again reports `unavailable`. The fallback is a **SAF
  tree**: `dialog.openDirectory` takes a grant that survives a relaunch, and
  `fs.readDir` walks it in place, so the library is still the user's own folder
  rather than a copy. See [Walking a folder the user
  picked](#walking-a-folder-the-user-picked). What it costs is paths — every
  file is a `content://` URI — and the ability to write beside the original
  without asking again.

### Walking a folder the user picked

`dialog.openDirectory` opens `ACTION_OPEN_DOCUMENT_TREE` and the runtime takes
a **persistable** grant, so the folder is still readable after a relaunch. The
piece that used to be missing was the one that makes the grant worth anything:
`fs.readDir` now answers for a `content://` tree, returning the same `FsEntry`
shape a filesystem path does, each entry's `path` being its own document URI —
which is exactly what `fs.readBinary` already accepts.

```js
const { path: tree } = await __SWIFT_PWA__.invoke('dialog.openDirectory', {});
const entries = await __SWIFT_PWA__.invoke('fs.readDir', { path: tree });
for (const entry of entries) {
    if (entry.isDir) continue;                       // descend with the same call
    const book = await __SWIFT_PWA__.invoke('fs.readBinary', { path: entry.path });
}
```

Recursion is the caller's business, exactly as it is for a path. `fs.metadata`
answers for these URIs too, and reports `isDir` honestly — through 0.11.1 it
claimed every content URI was a file, which was harmless only while nothing
could produce a directory one.

**This is the route when All-files access isn't available**, and it covers
three cases at once:

- **The Play Store** restricts `MANAGE_EXTERNAL_STORAGE` to apps whose core
  function needs it. A SAF tree needs no such approval.
- **SD cards and USB-OTG**: everything outside the app-specific directory on a
  removable volume needs All-files access or SAF, and SAF is the one a store
  won't argue with.
- **Google Drive, OneDrive and Dropbox are `DocumentsProvider`s on Android**,
  not synced folders — so a Drive folder picked through SAF is the *same code
  path* as an SD card picked through SAF. No OAuth, no API client, no
  per-provider adapter. On desktop the equivalent is an ordinary filesystem
  path, which is why the cross-platform shape holds.

Two things to expect from the platform rather than from us. A network-backed
provider is entitled to omit a row's size and modification time, so
`fs.metadata` reports **no `size` and no `modified`** for a Drive file that is
neither empty nor undated — test with `m.size == null` rather than `!m.size`,
or a genuinely empty file reads as unknown. And listing is a
`ContentResolver.query` per directory — cheap locally, a network round trip on
Drive — so walk lazily rather than eagerly for a deep tree.

### Which device is this?

`ProcessInfo.processInfo.hostName` is `localhost` on every Android device, and
that string is what an app writes into any "which device is this" field — where
it shows up on another device as "continue reading from localhost". Read
`__platform.info`'s **`deviceName`** instead: the model (`SM-F966B`) on Android,
the device's own name on iOS, the hostname on the three desktops, never empty.

```js
const { deviceName } = await __SWIFT_PWA__.invoke('__platform.info');
```

### The Activity lifecycle reaches Swift

`onResume` and `onPause` surface as the window's `WindowEvent.didFocus` /
`.didBlur` — the same events the desktop backends emit when their window gains
or loses focus, so Swift written against them is correct on every platform:

```swift
Task {
    for await event in window.eventStream() {
        switch event {
        case .didFocus: await library.rescanFolders()   // no recursive watch here
        case .didBlur: lock.engage()
        default: break
        }
    }
}
```

`.didBlur` is pushed *before* `super.onPause()`, so a handler is queued while
the process is still scheduled. A spawned secondary Activity doesn't report —
it doesn't own the runtime, and its lifecycle would otherwise read as the
primary's. JS sees the same events through `window.events`.

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
- **Your own `@MainActor` code works.** `MainActor` here is backed by
  libdispatch's main queue, and nothing drained it: the UI thread
  belongs to the JVM's `Looper`. So a command handler that touched a
  `@MainActor` class simply never returned — no error, no timeout, and
  Android discards stderr, so not even a diagnostic (#216). The runtime
  now adds libdispatch's main-queue eventfd to the UI thread's native
  `ALooper`, which `Looper.loop()` already polls, and drains it when it
  signals; `DispatchQueue.main.async` works for the same reason. The
  `@_cdecl` entry point in your app still has to call
  `AndroidAppRuntime().run(configure)` directly rather than through
  `SwiftPWA.runtime()`, because it runs on the *worker* thread the
  Activity spawned and the protocol's `@MainActor` witness would want a
  hop before the watch exists. `Scripts/verify-android-main-actor.sh`
  is the device check for all of this; it passes on a Fold7, with
  every probe answering in 1-3 ms.
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
| `SystemBiometricAuth` | `androidx.biometric.BiometricPrompt`                                                                                                                 | The host `MainActivity` extends `AppCompatActivity` (a `FragmentActivity` subclass) so the prompt can attach. `BiometricKind` is always `.unknown` when available — Android's `BiometricManager` doesn't distinguish fingerprint / face / iris at the API level. `allowDeviceCredential: true` requests `BIOMETRIC_WEAK \| DEVICE_CREDENTIAL` — the one device-credential combination androidx supports at every API level from 28 (`BIOMETRIC_STRONG \| DEVICE_CREDENTIAL` throws at `PromptInfo.build()` on API 28–29, and `DEVICE_CREDENTIAL` alone throws below 30), and `BIOMETRIC_STRONG` is a subset of `BIOMETRIC_WEAK` so nothing is lost. The prompt's negative button is omitted in that mode — the system puts "Use PIN" in the slot, and setting both makes `build()` throw.                                  |
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

**A real backend (`MobileSAMBackend`, `SwiftPWASegmentation`, behind the ONNX
Runtime tier — depending on the product is enough, and `ai.local_onnx_runtime:
true` in `pwa.json` is the explicit form; either way `swift-pwa build` sets
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
  found at cross-compile link time via a per-ABI `-Xlinker -L` search path,
  the exact mechanism [docs/ai-plugin.md](ai-plugin.md#available-backend-llamacpp)
  already describes for Linux's llama.cpp build (no `unsafeFlags`).

Cross-compiling anything against the installed Android Swift SDK **requires
the host toolchain of the SDK's own Swift release** — and specifically the
swift.org build of it, since Xcode's Swift of the same version number is a
different build and can't load the SDK's prebuilt modules. A mismatch is
"module compiled with Swift X cannot be imported by the Swift Y compiler".

`swift-pwa build --cross-compile-android` (and `swift-pwa deploy --target
android`) **selects it for you** on a macOS host: it reads the Swift release
the installed Android SDK bundle needs and exports the matching
`~/Library/Developer/Toolchains/swift-<version>-RELEASE.xctoolchain` bundle id
as `TOOLCHAINS` for the cross-build (printing which one it picked). An explicit
`TOOLCHAINS` in your environment still wins, so you can override it.

You only need to set `TOOLCHAINS` by hand when invoking `swift build
--swift-sdk` **directly** (the CLI's auto-selection doesn't reach a raw
`swift build`), as the spike's verification did. The value is the
`CFBundleIdentifier` of the `.xctoolchain` matching your installed SDK's
release — read it off your own machine rather than copying one from here:

```bash
# Whatever swift-<release>-RELEASE.xctoolchain your Android SDK needs:
tc=~/Library/Developer/Toolchains/swift-<release>-RELEASE.xctoolchain
export TOOLCHAINS=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$tc/Info.plist")
export SWIFT_PWA_ONNXRUNTIME=1
swift build --swift-sdk aarch64-unknown-linux-android28 \
  --target SwiftPWAONNXRuntimeAndroidSmoke \
  -Xlinker -L"$(pwd)/Vendor/onnxruntime-android/arm64-v8a"
```

(`LIBRARY_PATH` used to do that last part and no longer can: Swift 6.4's
`swiftbuild` engine doesn't pass it to the link task, and the build then fails
as `unable to find library -lonnxruntime`.)

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
`TOOLCHAINS`/search-path/`--swift-sdk` invocation, links successfully
with `OrtGetApiBase@VERS_<ort version>` showing as an undefined symbol resolving
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

## 7.5 Links out of the app

A main-frame navigation that leaves the app's own origin is handed to the
system (`Intent.ACTION_VIEW`) instead of loading in place — an app window has
no address bar and no back button, so in place means the app is gone. Same
shared policy as every other backend (`ctx.externalURLs`, seeded from
`pwa.json`'s `external_urls`); `system.openURL` takes the same route out. See
[the JS API](javascript-api.md#systemopenurl--hand-a-url-to-the-operating-system).

Android makes this the least fiddly of the five: `shouldOverrideUrlLoading`
carries **`request.isForMainFrame`**, so a cross-origin `<iframe>` is told
apart from the app navigating away for free — no heuristics, unlike
WebKitGTK. Device-verified: an embedded `example.com` iframe still renders
while a link to the same site opens Chrome and leaves the page where it was.

> **The one synchronous seam in this backend.** `shouldOverrideUrlLoading`
> must answer *before* the load proceeds, so it calls into Swift through a
> blocking JNI entry rather than the async RPC everything else here uses. That
> is only safe because the decision is a lock-guarded pure function in Core —
> no I/O, no actor hop. Keep it that way.

`alert()`, `confirm()` and `prompt()` need nothing from the runtime: Android's
WebView shows its own dialog when the `WebChromeClient` doesn't override
`onJsAlert`. Measured on a device — `alert()` blocks the page and renders
*"The page at …/ says:"* with an OK button.

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

- **A served file answers a `Range` request with a `200`, not a `206`.** A
  `206 Partial Content` returned from `WebViewClient.shouldInterceptRequest` is
  rejected by the WebView *before the page sees it* — the fetch fails with
  `TypeError: Failed to fetch` and nothing is logged anywhere, by us or by
  Chromium. Measured on a Fold7 against a correct 206 (right `Content-Range`,
  right body, bounded stream). What Chromium does instead is range the stream
  itself: given a plain `200` it seeks to the requested start offset and serves
  **to the end of the file**, reporting `200` with no `Content-Range`. So
  seeking works — which is what a `<video>` scrub and a range-fetching reader
  need — but the end of the range is not honoured and no `Accept-Ranges: bytes`
  is advertised, deliberately: claiming it would tell a client a `206` is
  coming when none ever is, and a client that checks (pdf.js does) would pick
  the range path and be wrong about what it got. `build.serve` mounts have
  always behaved this way; runtime `ctx.serveDirectory` mounts now match them.

  **The end of the range is honoured to the extent that the body stops there.**
  Chromium reports `Content-Length` as the length that was *asked for* while
  reading the stream to EOF, so a `bytes=100-199` over a 12,270-byte file
  announced 100 bytes and delivered 12,170 (#244). The runtime now caps the
  stream at the end of the range, which makes the header and the body agree and
  stops a large file paying for its whole tail on every request. It does not
  skip to the start offset — Chromium already does that, and doing it twice
  would deliver the wrong bytes.

- **`ctx.frame` falls back to `.unknown` on a very old System WebView.** The
  inbound bridge channel is `WebViewCompat.addWebMessageListener`, which reports
  which frame called (`isMainFrame` plus the sending document's origin) and is
  scoped to the app's own origin, so a cross-origin iframe never receives the
  bridge object at all. Where `WebViewFeature.WEB_MESSAGE_LISTENER` is missing
  (WebView older than ~85) the runtime falls back to `addJavascriptInterface`,
  which reports nothing about the caller — `ctx.frame` is then `.unknown` there,
  and a guard that narrows a permission on it must treat that as "I can't tell"
  rather than "the app's own page". The fallback logs one line under the
  `swift-pwa` tag at startup. See
  [docs/swift-api.md](swift-api.md#which-frame-is-calling).

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
  tree). `fs.mkdir` / `remove` / `copy` / `rename` deliberately reject
  `content://` URIs with a clear error (`SAF doesn't expose this operation`)
  rather than silently misbehaving — SAF doesn't have directory-style POSIX
  semantics for content providers. **`fs.readDir` is the exception**, and the
  reason it is has a section of its own: [Walking a folder the user
  picked](#walking-a-folder-the-user-picked).
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
- **API 28 floor.** Originally the Swift Android SDK 6.2's `targetTriples`
  map, which declared triples for API 28–36 only; the 6.4 SDK declares 23–36,
  so this is now swift-pwa's own clamp and is unverified below 28. See §1's
  "Why the API 28 floor" callout.
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
  any Swift `configure()` runs — so a mount that must answer a request the
  page makes before `configure()` returns has to be declared in `pwa.json`'s
  `build.serve` (`{ "mount": "/packs", "from": "data/packs" }`, rooted at the
  app's `filesDir` / `cacheDir`); the bundler wires each into the
  generated Activity as an `addPathHandler`. A runtime
  `ctx.serveDirectory(_:at:)` works for any other prefix, from any root the
  app can read — see the Range note below for the one way it differs from
  desktop. The `fs.extractZipProgress` / `fs.createZipProgress` streams emit a
  single terminal progress tick on Android (the unary JNI RPC has no per-entry
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
