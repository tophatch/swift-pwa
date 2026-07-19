# `swift-pwa deploy` — build, install, and launch in one step

`swift-pwa build` produces an artifact; `swift-pwa deploy` carries it the last
mile — **build → package → install → launch** — so the on-device test loop is a
single command instead of `build` plus three by-hand steps.

`deploy` is a **superset of `build`**: it runs the exact same build pipeline
(project preflight, AI gates, `build.prebuild`, the web-bundle check, the
platform bundler, `build.postbuild`), then does the per-platform install/launch
that `build` deliberately leaves out.

```bash
swift-pwa deploy --target android              # cross-compile → APK → adb install -r → am start
swift-pwa deploy --target ios --simulator      # build → boot a simulator → simctl install → launch
swift-pwa deploy --target macos                # build → open the .app
swift-pwa deploy --target linux                # build → run the AppImage
swift-pwa deploy --target windows              # build → run the portable .exe
```

## What each platform does

| Target | package | install | launch |
|---|---|---|---|
| **android** | `./gradlew assembleDebug` (deploy invokes it) | `adb install -r <apk>` | `am start -n <pkg>/.MainActivity` |
| **ios** (`--simulator`) | `xcodebuild` simulator build | `simctl install <udid>` | `simctl launch <udid> <bundleid>` |
| **ios** (device) | signed `xcodebuild` build | `devicectl device install app` | `devicectl device process launch` |
| **macos** | the `.app` bundle | — | `open <app>` |
| **linux** | the `.AppImage` | — | run it |
| **windows** | the portable `.exe` | — | run it |

`build --target android` stays **staging-only** — it emits an offline-complete
Gradle project and never runs it, so it fits CI/signing flows that run Gradle
themselves. `deploy` is the verb that runs `gradlew` for you.

## Flags

| Flag | Meaning |
|---|---|
| `--target <platform>` | `android`, `ios`, `macos`, `linux`, `windows`. Defaults to the host. |
| `--device <id>` | Which device. Android: an adb serial, or an `ip:port` for a wireless device (deploy runs `adb connect` first). iOS device: a UDID or device name. iOS simulator: a simulator name or UDID. |
| `--simulator` | iOS: target a simulator (skips signing) instead of a physical device. |
| `--no-build` | Skip the build/package step and install/launch the artifact already in the output dir — the fast re-test path. |
| `--launch` / `--no-launch` | Launch after installing. On by default. |
| `--reinstall` / `--no-reinstall` | Android: `adb install -r` (replace, keep data). On by default. |
| `--release` | Android: assemble the release variant. (A release APK must be signed to install.) |
| `--android-abis <list>` | Passed through to the build (e.g. `arm64-v8a,x86_64`). |
| `--team`, `--sign`, `--provisioning-profile`, `--entitlements` | iOS device signing, passed through to the build (see [iOS](#ios)). |
| `--manifest`, `--output` | Same as `build`. |

## Android device selection

Selection follows **adb's own rules** — no magic, no guessing:

1. `--device <serial>` (or `--device <ip:port>`, which is `adb connect`-ed first
   and used as the serial), else
2. the `ANDROID_SERIAL` environment variable, else
3. the sole connected device.

If several devices are attached and none is chosen, `deploy` **errors and lists
them** rather than silently picking one:

```text
Error: 2 Android devices are connected: 10.0.0.2:5555, emulator-5554.
Pass --device <serial> (or set ANDROID_SERIAL) to choose one.
```

Wireless adb rotates its port per session, so `--device <ip:port>` is the common
daily case — deploy runs `adb connect <ip:port>` before installing, so you don't
have to.

`adb` must be on `PATH`; deploy fails fast with an install-the-platform-tools
hint if it isn't. The build prerequisites (NDK, JDK, the Swift Android SDK) reuse
`swift-pwa doctor`'s preflight — the same heads-up `build` prints.

## Android cross-compile toolchain — now automatic

Cross-compiling the Android shell requires the Swift compiler to **exactly
match** the Swift release the installed Android SDK was built with; a mismatch
fails deep with `module compiled with Swift 6.2 cannot be imported by the Swift
6.3 compiler`. Previously you had to line them up by hand
(`export TOOLCHAINS=<xctoolchain bundle id>`, or wrapping the build in
`swiftly run +6.2.0`).

Now `build --cross-compile-android` (and therefore `deploy --target android`)
selects it for you: it reads the Swift release the installed Android SDK bundle
needs and finds the matching `swift-<version>-RELEASE.xctoolchain`, exporting its
bundle id as `TOOLCHAINS` for the cross-build. You'll see:

```text
swift-pwa: cross-compile toolchain: org.swift.6200202509111a (swift-6.2-RELEASE.xctoolchain, matched to the Swift 6.2 Android SDK)
```

This is macOS-only (the `TOOLCHAINS` / `.xctoolchain` mechanism is Apple-specific
— on a Linux host, match the toolchain with `swiftly`; see
[android-setup.md](android-setup.md)). It's non-fatal: an explicit `TOOLCHAINS`
(or a `swiftly run +X` wrapper) always wins, and if the SDK/toolchain can't be
resolved deploy prints a hint and continues.

## iOS

### Simulator

```bash
swift-pwa deploy --target ios --simulator
```

Builds, boots a simulator if none is running (an explicit `--device <name|udid>`
is booted on demand; otherwise a booted one is reused, else the first available
iOS simulator is booted), installs, and launches.

### Physical device

```bash
swift-pwa deploy --target ios --team <TEAMID>
swift-pwa deploy --target ios --team <TEAMID> --device "My iPhone"
```

An on-device install needs a **signed** build, so pass the same signing inputs
`swift-pwa build --target ios` takes — `--team <TEAMID>` (the convenience path:
it selects that team's "Apple Development" identity and finds an installed
provisioning profile for the app's bundle id), or the pieces explicitly
(`--sign` + `--provisioning-profile` + `--entitlements`). The profile must
already exist for the bundle id and list the target device's UDID; see
[ios-setup.md](ios-setup.md).

deploy then:

1. **Resolves the device** via `xcrun devicectl list devices` — the sole
   *connected* iOS/iPadOS device by default, `--device <udid|name>` to choose,
   and a clear error (listing what's paired) when none is connected or several
   are. An explicit `--device` is passed through even if it currently shows
   disconnected (`devicectl` brings the connection up).
2. Runs the signed `build`, then **installs** the resulting `.app` with `xcrun
   devicectl device install app`.
3. **Launches** it with `xcrun devicectl device process launch
   --terminate-existing` (unless `--no-launch`).

> **No provisioning profile for the bundle id yet?** That's the one manual
> prerequisite deploy doesn't create — open the app once in Xcode with automatic
> signing (or create a profile at developer.apple.com) so a profile matching the
> bundle id and listing your device exists, then `deploy --team …` finds it.

## The fast re-test loop

`--no-build` skips straight to install + launch using the artifact already in the
output directory — handy when you're only re-testing the install itself, or
iterating on native/packaging behavior without touching the web layer:

```bash
swift-pwa deploy --target android --no-build --device 10.0.0.2:5555
```

Pair with `--no-launch` to install without foregrounding the app.
