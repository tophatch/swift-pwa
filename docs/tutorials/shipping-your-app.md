# Shipping your app

**Who this is for:** you've built your app with [swift-pwa](https://github.com/tophatch/swift-pwa) — it runs, the window opens, you're happy — and now you want to get it into other people's hands. A `.app` a friend can double-click, an `.AppImage` on your download page, something in the App Store, an APK for your Android testers. This guide walks the "ship it" step for each platform.

You don't need to know Swift. Everything here is `swift-pwa` CLI commands plus, for the app stores, the platform's own signing bits (which you'd need with any tool). We keep the beginner path front-and-centre and tuck the "if you already know the ecosystem" notes into asides.

> **The honest version up front:** iOS and macOS App Store *submission* isn't automated yet — swift-pwa gets you a signed, notarized app, but the final store upload is still your own step (details in each section). Everything else — direct downloads, sideloading, Play Store AABs, MSIX — is a single command away.

> Uses the flags from swift-pwa **0.8+**. Most existed earlier; if a flag is missing, `swift-pwa build --help` shows what your version supports.

---

## The big picture

Shipping is the same three steps everywhere — only the details change per platform:

```
  1. BUILD      swift-pwa build --target <platform>   →  an artifact in build/
  2. SIGN       prove it's really from you             →  so the OS will run it
  3. DISTRIBUTE hand it to users                       →  download, store, or sideload
```

What comes out of step 1, per platform:

| Platform | Artifact | Signing needed to run elsewhere? |
|---|---|---|
| macOS   | `build/MyApp.app`              | Yes — Developer ID + notarization (or Gatekeeper blocks it) |
| iOS     | `build/MyApp.ipa`             | Yes — provisioning profile + Apple identity |
| Linux   | `build/MyApp-x86_64.AppImage` | No — runs as-is |
| Windows | `build/MyApp/` folder or `.exe` (portable), or an `.msix` | Optional for portable; signing recommended for MSIX |
| Android | `build/MyApp-android/` Gradle project → APK / AAB | Yes — a keystore, for release builds |

Everything lands in `build/`. Let's do each one.

> **Before you start:** you need the `swift-pwa` CLI and the toolchain for whichever platform you're targeting (Xcode for macOS/iOS, GTK + `linuxdeploy` for Linux, Visual Studio Build Tools + the WebView2 SDK for Windows, the Android SDK/NDK for Android). Each platform's [`docs/*-setup.md`](../) has the full prerequisite list, and `swift-pwa doctor --target <platform>` tells you what's missing with a copy-paste fix for each gap. Run that first.

---

## macOS

### Just try it locally

```sh
swift-pwa build --target macos
open build/MyApp.app
```

That's a real `.app`. It'll run on **your** machine. But if you send it to a friend, macOS Gatekeeper will refuse to open it ("can't be verified") — because it isn't signed and notarized yet. That's step 2.

### Sign it so other Macs will run it

You need an **Apple Developer account** ($99/yr) and a "Developer ID Application" certificate (create it in Xcode → Settings → Accounts, or the Developer portal). Then:

```sh
swift-pwa build --target macos --sign "Developer ID Application: Jane Doe (TEAMID1234)"
```

> Not sure of the exact name? `security find-identity -v -p codesigning` lists the identities installed on your machine — copy one verbatim.

### Notarize it (the step that kills the scary warning)

Signing isn't quite enough on modern macOS — Apple also wants to "notarize" the app (a quick automated malware scan). Do the one-time credential setup:

```sh
xcrun notarytool store-credentials "my-notary-profile" \
  --apple-id you@example.com --team-id TEAMID1234
```

Then build, sign, and notarize in one go:

```sh
swift-pwa build --target macos \
  --sign "Developer ID Application: Jane Doe (TEAMID1234)" \
  --notarize "my-notary-profile"
```

`--notarize` submits the app to Apple and waits for the thumbs-up (a minute or two), then staples the result to the bundle. Now anyone can open it with no warning. (`--notarize` needs `--sign` — it'll tell you if you forget.)

### Getting it to users

Zip the `.app` (`ditto -c -k --keepParent build/MyApp.app MyApp.zip`) or wrap it in a `.dmg`, then put it on your download page or a GitHub Release. That's the whole flow for direct distribution.

> **Custom entitlements?** Pass `--entitlements MyApp.entitlements` alongside `--sign`.

> **Mac App Store:** not automated yet — the bundler doesn't produce the `.pkg` / App Sandbox / `embedded.provisionprofile` layout the Store requires. Direct distribution (signed + notarized) is the supported path today.

> **Universal (Intel + Apple Silicon) binary:** not built for you automatically — build once per arch and `lipo -create` the two together if you need one download for both.

---

## iOS

**You need a Mac with Xcode** for any iOS build — that's Apple's rule, not ours.

### Run it in the Simulator (no account needed)

```sh
swift-pwa build --target ios --simulator
```

This gives you an `.app` you can drag onto a running Simulator. Great for checking it works before you deal with signing.

### Build a real `.ipa` for a device

For a physical iPhone/iPad you need an Apple identity and a **provisioning profile** (the file that says "this app is allowed to run on these devices"). If you have a profile installed, the easy path is:

```sh
swift-pwa build --target ios --team ABCDE12345
```

`--team` fills in your signing identity, profile, and entitlements for you. Prefer to be explicit?

```sh
swift-pwa build --target ios \
  --sign "Apple Development: you@example.com (TEAMID)" \
  --provisioning-profile path/to/app.mobileprovision \
  --entitlements path/to/app.entitlements
```

Either way you get `build/MyApp.ipa`.

> **No paid account?** You can use a **free personal team**: make a throwaway app target in Xcode once, let Xcode create a personal-team profile, then reuse it here. Apps signed this way expire after 7 days but are perfect for trying it on your own phone. Full recipe in [docs/ios-setup.md](../ios-setup.md).

### Getting it to users

Install on a tethered device with:

```sh
xcrun devicectl device install app build/MyApp.ipa
```

For wider testing (TestFlight) or the App Store, you take the `.ipa` (or an `xcodebuild archive`) through Apple's upload tooling yourself — **swift-pwa doesn't automate the store upload yet**. [docs/ios-setup.md](../ios-setup.md) has the archive/export commands.

> On iOS, use `dialog.exportFile` (not `dialog.saveFile`, which is a no-op there) for saving — see the [file tutorial](saving-and-loading-files.md).

---

## Linux

The easiest platform to ship: **no signing, no store, no account.** One command, one file, put it on the internet.

```sh
swift-pwa build --target linux
```

Out comes `build/MyApp-x86_64.AppImage` — a single self-contained file that runs on most modern distros (Ubuntu 22.04+, Fedora 36+). Make it executable (`chmod +x`) and double-click, or ship it on your download page / GitHub Release. Done.

> **Prerequisite:** `linuxdeploy` and `linuxdeploy-plugin-appimage` need to be on your `PATH` (they assemble the AppImage). `swift-pwa doctor --target linux` checks for them.

> **GTK3 vs GTK4:** swift-pwa defaults to GTK3 + WebKitGTK 4.1, which works on the widest range of distros. To build against GTK4 + WebKitGTK 6.0 instead, set `SWIFT_PWA_GTK4=1` **before** `swift build` (and `rm -rf .build` when switching, since the manifest cache doesn't notice env-var-only changes). Details + known limitations in [docs/linux-setup.md](../linux-setup.md).

> **Give it a real icon:** point `pwa.json`'s `icon` at an actual PNG — without one the AppImage silently embeds a transparent placeholder.

---

## Windows

First, a one-time thing: **run your build inside a Visual Studio Developer Shell** (`Launch-VsDevShell.ps1`), so the compiler and the Windows SDK tools are on the path. Do that once per terminal session, then:

### Portable — the no-installer option

```powershell
swift-pwa build --target windows                 # → build\MyApp\  (a folder you can zip and share)
swift-pwa build --target windows --single-file   # → build\MyApp.exe  (one file, web assets embedded)
```

The portable build runs on any Windows 10 21H2+/Windows 11 box — **as long as the WebView2 Runtime is installed** (it ships with recent Windows and Edge, so most machines have it). To be safe, bundle a self-installer:

```powershell
swift-pwa build --target windows --single-file --bootstrap-webview2
```

`--bootstrap-webview2` embeds Microsoft's ~1.7 MB Evergreen Bootstrapper, which fetches the runtime on first launch if it's missing.

### MSIX — the installable / Store-adjacent package

```powershell
swift-pwa build --target windows --package-format msix
swift-pwa build --target windows --package-format msix --sign <thumbprint-or-pfx>
```

Signing (`--sign`) matters for MSIX: an **unsigned** MSIX only installs on machines with Developer Mode on; a **signed** one installs on any Windows 10 1809+. The signing uses `makeappx` + `signtool` from the Windows SDK — no extra tools once you're in the Developer Shell.

### Getting it to users

Portable: zip the folder (or hand over the single `.exe`) and put it on your download page. MSIX: distribute the `.msix` for a real install/uninstall experience, or use it as the basis for a Microsoft Store submission.

> **Building for Windows on ARM (`--arch arm64`):** cross-compiling isn't supported yet — the `--arch` flag sets the package identity, but the actual binary is whatever architecture your Swift toolchain is. To ship both x64 and arm64, build each on a matching machine. (And `--single-file` can't be combined with `--package-format msix` — the CLI will tell you.)

> Full toolchain setup (Swift for Windows, VS Build Tools, WebView2/WIL NuGet) is in [docs/windows-setup.md](../windows-setup.md).

---

## Android

`swift-pwa build --target android` produces a standard **Gradle project** under `build/MyApp-android/`, and you finish the build with Gradle — the same as any Android app. The one-time toolchain setup (a specific Swift version, the Android SDK/NDK, JDK 17) is exact and load-bearing; get it from [docs/android-setup.md](../android-setup.md) before your first build.

### Build a debug APK to try on a device

```sh
swift-pwa build --target android --cross-compile-android --android-abis arm64-v8a,x86_64
cd build/MyApp-android
./gradlew assembleDebug          # → app/build/outputs/apk/debug/app-debug.apk
adb install app/build/outputs/apk/debug/app-debug.apk
```

`--cross-compile-android` compiles the Swift side and stages the native `.so` libraries into the project for you (without it you'd get an empty scaffold to wire up by hand).

### Sign a release build

Play Store and real distribution need a **keystore** (your app's signing key — guard it; lose it and you can't update your Play listing). Make one once:

```sh
keytool -genkeypair -keystore release.jks -alias upload-key \
  -keyalg RSA -keysize 2048 -validity 36500 -storetype pkcs12
```

Point swift-pwa at it (via `pwa.json`'s `android.signing` block, or CLI flags), and pass the passwords through environment variables so they're never in a file:

```sh
export SWIFT_PWA_ANDROID_STORE_PASSWORD='…'
export SWIFT_PWA_ANDROID_KEY_PASSWORD='…'
swift-pwa build --target android --cross-compile-android \
  --sign /path/to/release.jks --android-key-alias upload-key
cd build/MyApp-android
./gradlew bundleRelease          # → an .aab for the Play Store
./gradlew assembleRelease        # → a signed .apk for direct/sideload distribution
```

### Getting it to users

Upload the `.aab` to the Google Play Console for the Play Store, or hand out the `.apk` directly for sideloading / your own testers.

> **Talking to a device on your LAN over plain `http://`?** Android blocks cleartext by default — opt specific hosts in with `android.network.cleartext_domains` in `pwa.json`. See [docs/android-setup.md](../android-setup.md).

---

## Ship everything at once, from a tag (CI)

You don't have to build on five machines by hand. `swift-pwa init` drops a **GitHub Actions release workflow** into `.github/workflows/release.yml` (add it to an existing project with `swift-pwa generate-ci`). Push a version tag and it builds the three desktop platforms in the cloud and attaches them to a GitHub Release:

```sh
git tag v1.0.0
git push --tags        # → CI builds macOS, Linux, Windows and publishes a Release
```

No local Swift / MSVC / GTK toolchains required — GitHub's runners have them. **iOS and Android are left as commented-out opt-in stubs** in the workflow, because they need your signing material (Apple identity) or a heavy cross-compile SDK (Android) that can't be wired generically — uncomment and fill in your secrets when you're ready.

> If your `pwa.json` has a `build.prebuild` step that needs Node or another toolchain, add a setup step to the relevant CI jobs — the hook runs on every `swift-pwa build`.

---

## Auto-updates (a heads-up)

swift-pwa ships an updater: you publish a signed manifest, and the app checks it and updates itself. The **publishing** side is solid and fully tested:

```sh
swift-pwa updater keygen  --private-key key.priv --public-key key.pub    # one-time keypair
swift-pwa updater sign    --private-key key.priv build/MyApp.AppImage     # per-artifact signature
swift-pwa updater manifest --version 1.0.1 --platform linux=…=<url> --output manifest.json
```

The **runtime** side — download, verify, swap, relaunch — is verified end-to-end on **macOS, Linux (AppImage), Windows (portable), and Android**. Windows MSIX and iOS are still preview (they need a signed package / distribution cert respectively). It also supports background auto-checks, a mandatory-update kill-switch, and **delta (binary-diff) updates** that ship a tiny patch instead of the whole artifact on all three desktop backends (macOS, Linux AppImage, Windows portable). See the **[Auto-updates tutorial](auto-updates.md)** for the full walkthrough (wiring, JS, `min_supported_version`, deltas) and [docs/auto-updates.md](../auto-updates.md) for the reference.

---

## Where to go next

- Per-platform prerequisites, codesigning deep-dives, and the full list of known limitations: the [`docs/*-setup.md`](../) files.
- The auto-update system end to end: [docs/auto-updates.md](../auto-updates.md).
- Add native features before you ship: the other [tutorials](README.md).
