# swift-pwa on iOS (WKWebView + UIScene)

Tested target: iOS 26 Simulator and iOS 18.0+ devices, Xcode 26.x on
macOS 15. JS↔Swift bridge round-trip verified end-to-end on the
iPhone 16 Simulator running iOS 26.4.

> iOS builds always go through `xcodebuild`, not `swift build --triple`.
> Apple doesn't ship a Swift SDK that SwiftPM can cross-compile against
> for iOS — the manifest needs to compile for the host (macOS) while
> targets compile for iOS, and only Xcode handles that split cleanly.

## 1. Toolchain + iOS Simulator runtime

You need the full Xcode (not just the command-line tools) **plus** the
matching iOS Simulator runtime. The runtime is what trips most people
up: `xcodebuild` will reject `-destination 'generic/platform=iOS
Simulator'` until it's installed.

```bash
xcodebuild -version                              # expect Xcode 26+
xcrun simctl list runtimes | grep iOS            # at least one row
```

If `simctl list runtimes` returns no iOS rows, install one via
**Xcode → Settings → Platforms → iOS** (or `xcodebuild -downloadPlatform iOS`).

## 2. Build for the simulator

Install the prebuilt CLI from the latest GitHub release if you haven't
already (Apple silicon shown — swap to `swift-pwa-macos-x86_64` on
Intel):

```bash
curl -L https://github.com/tophatch/swift-pwa/releases/latest/download/swift-pwa-macos-arm64 \
    -o /usr/local/bin/swift-pwa
chmod +x /usr/local/bin/swift-pwa
```

Then scaffold and build:

```bash
swift-pwa init MyApp
cd MyApp

# Replace the placeholder dependency with whatever you actually want
# (a path: dependency for local dev, or a github URL with a tag).
$EDITOR Package.swift

swift-pwa build --target ios --simulator
# → build/MyApp.app  (universal arm64 + x86_64 simulator slices)
```

If you're working from a swift-pwa checkout (or pinning to an
unreleased commit) substitute `swift run --package-path
/path/to/swift-pwa swift-pwa …` for `swift-pwa …`.

Under the hood the bundler:

1. Runs `xcodebuild -scheme MyApp -workspace . -destination
   'generic/platform=iOS Simulator' -configuration Release` against
   the SwiftPM-generated workspace.
2. Wraps the resulting Mach-O + SwiftPM resource bundles + your
   `web/` directory into `MyApp.app` with a generated `Info.plist`.
3. Adhoc-codesigns the `.app` so the simulator will accept it.

## 3. Install + launch on the simulator

```bash
# Boot whichever device you want — list them with: xcrun simctl list devices
xcrun simctl boot "iPhone 16" 2>/dev/null || true
open -a Simulator                               # bring up the window
xcrun simctl install booted build/MyApp.app
xcrun simctl launch --console-pty booted com.example.myapp
```

`--console-pty` pipes stdout/stderr from the app back to your terminal,
which is invaluable for debugging the bridge. Drop it once things work.

To watch the WebKit logs live:

```bash
xcrun simctl spawn booted log stream --predicate 'processImagePath CONTAINS "MyApp"'
```

To attach Safari Web Inspector for the page running inside your app:
**Safari → Develop → Simulator → MyApp → index.html**. (Enable Web
Inspector once via Safari → Settings → Advanced → Show features for web
developers.)

## 4. Build for a real device

The current state: `swift-pwa build --target ios --sign <identity>`
will compile + codesign, but **does not embed a provisioning profile or
entitlements** into the `.app`. iOS rejects unprovisioned binaries,
so the resulting `.ipa` won't install via `ideviceinstaller` or Apple
Configurator on its own.

Until the CLI's signing / provisioning path is wrapped (queued for a follow-up), the recommended device path is to run from Xcode directly:

```bash
xed Package.swift                               # opens the SwiftPM project in Xcode
```

Then in Xcode:

1. Pick the `MyApp` scheme and your physical device.
2. **Signing & Capabilities** → enable *Automatically manage signing*
   and select your team. Xcode generates the provisioning profile.
3. *Run*. Xcode builds, signs with a fresh profile, copies the `.app`
   to the device, and launches it.

This is the same xcodebuild path the CLI uses, just with the signing
infrastructure that Xcode bolts on. The command-line equivalent (for
scripting) is `xcodebuild ... -allowProvisioningUpdates -destination
'platform=iOS,id=<UDID>'`, but it still needs you to be logged into
your Apple Developer account in Xcode at least once.

For TestFlight / App Store distribution, `xcodebuild archive` →
`xcodebuild -exportArchive -exportOptionsPlist ...` → `xcrun altool
--upload-app` is the canonical chain. Plumbing this through the
`swift-pwa` CLI is queued for a follow-up.

## 5. Sideloading for personal testing

If you have a paid Apple Developer account but don't want to use Xcode's
Run button (e.g. CI):

```bash
xcodebuild archive \
    -scheme MyApp \
    -workspace . \
    -archivePath build/MyApp.xcarchive \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates

xcodebuild -exportArchive \
    -archivePath build/MyApp.xcarchive \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath build/

# Install via libimobiledevice (`brew install libimobiledevice`).
ideviceinstaller -i build/MyApp.ipa
```

A minimal `ExportOptions.plist` for ad-hoc distribution:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>TEAMID1234</string>
</dict>
</plist>
```

## Known limitations on iOS

- **The CLI's device path is incomplete.** `swift-pwa build --target
  ios --sign <identity>` runs `codesign` but doesn't embed
  `embedded.mobileprovision` or pass entitlements, so its `.ipa`
  output won't install on a real device. Use Xcode for device runs
  for now; full pipeline support is queued.
- **No `--entitlements` flag for iOS.** macOS bundling accepts one;
  iOS doesn't yet. Most apps don't need extra entitlements, but
  things like camera / network extensions / push will require manual
  re-signing for now.
- **No automated TestFlight / App Store upload.** `xcrun altool` and
  `xcrun notarytool` aren't wrapped by the CLI; bring your own
  release script.
- **Multi-scene support is scaffolded but minimal.** The
  `UIApplicationSceneManifest` opts into multiple scenes, but the
  per-scene window plumbing in `IOSWindow` is the bare minimum to
  attach the first scene. iPad multi-window polish lands in a
  follow-up.
- **`pwa.json.icon` only feeds the launch screen on iOS.** When
  set, the bundler generates a minimal `LaunchScreen.storyboard`
  with the icon centered on a black background and compiles it via
  `ibtool` — that handles the launch frame. The home-screen icon
  still falls back to iOS's generic placeholder; full asset-catalog
  generation (sized App Icons, alternate-icon support, dark/tinted
  variants) is queued. To customize the launch screen
  beyond "icon on black", drop your own compiled `LaunchScreen.storyboardc`
  into `<App>.app/` after the build for now.

## Reporting issues

When filing an iOS issue, include:

```bash
sw_vers
xcodebuild -version
xcrun simctl list runtimes | grep iOS
swift --version
```
