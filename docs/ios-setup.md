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

## 6. Auto-updates (enterprise / ad-hoc)

The App Store handles updates for store-distributed apps automatically;
swift-pwa's auto-updater on iOS targets the **enterprise** (Apple
Developer Enterprise Program, `Distribution: <Org Name>` certificate)
and **ad-hoc** (provisioning profile lists specific UDIDs) paths,
which Apple lets users install via `itms-services://` URLs the
system installer trusts.

The contract is: the manifest entry under `ios-aarch64-enterprise`
points at the **install-manifest plist** on your server (not the
`.ipa`). The runtime opens
`itms-services://?action=download-manifest&url=<plist-url>`; the
system pulls the plist, downloads the `.ipa` it references, validates
the signing chain, and installs in place. No Ed25519 key is required
on the swift-pwa side because Apple's signing chain is what's being
trusted.

Wire it the same way as macOS — pass `nil` for `publicKey`:

```swift
import SwiftPWA

ctx.use(UpdaterPlugin(AppleUpdater(
    endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
    publicKey: nil
)))
```

Sample manifest entry your server returns (the JSON manifest fetched
from `endpoint`):

```json
{
  "version": "0.4.0",
  "platforms": {
    "ios-aarch64-enterprise": {
      "url": "https://updates.example.com/HelloPWA-0.4.0-manifest.plist",
      "signature": ""
    }
  }
}
```

And the install-manifest plist that `url` points at (Apple's format):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key><string>software-package</string>
                    <key>url</key>
                    <string>https://updates.example.com/HelloPWA-0.4.0.ipa</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key><string>com.example.hellopwa</string>
                <key>bundle-version</key><string>0.4.0</string>
                <key>kind</key><string>software</string>
                <key>title</key><string>HelloPWA</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
```

Both the JSON manifest and the install-manifest plist must be served
over HTTPS. The `.ipa` itself can be HTTP-redirected from the plist's
`software-package` URL but the plist URL given to `itms-services://`
must be HTTPS — iOS rejects http manifests outright.

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
- **Auto-updater is enterprise / ad-hoc only.** Apps distributed via
  the App Store get updates from the App Store; swift-pwa's
  `AppleUpdater` on iOS targets the `itms-services://` install path,
  which only succeeds when the running build is signed with an
  enterprise distribution certificate or an ad-hoc profile that lists
  the device's UDID. A clean `BridgeError` is returned when the
  system declines to open the URL.
- **`DialogPlugin.saveFile` returns `nil` on iOS.** iOS has no system
  save panel. Apps that need a save flow should call
  `UIDocumentPickerViewController(forExporting:)` directly (which takes
  an already-written file URL) or present a `UIActivityViewController`
  share sheet. The other dialog commands (`message`, `confirm`,
  `openFile`, `openDirectory`) all work — `openFile` and
  `openDirectory` are routed through `UIDocumentPickerViewController`
  in opening / folder mode. `dialog.saveFile` logs a one-shot
  stderr warning the first time it is called.
- **`pwa.json.icon` drives both the home-screen App Icon and the
  launch screen.** From the single 1024×1024 PNG the bundler compiles
  a real `AppIcon` via `actool` (a single "universal" asset — Xcode
  generates the full size set — and the resulting `CFBundleIcons*` keys
  are merged into `Info.plist`), and also generates a minimal
  `LaunchScreen.storyboard` with the icon centered on a black background
  (compiled via `ibtool`). App-icon generation is best-effort: if the
  icon is missing / not a PNG, or `actool` can't run, the build falls
  back to the system default rather than failing. Alternate-icon support
  and dark/tinted icon variants are still queued. To customize the
  launch screen beyond "icon on black", drop your own compiled
  `LaunchScreen.storyboardc` into `<App>.app/` after the build for now.

## Reporting issues

When filing an iOS issue, include:

```bash
sw_vers
xcodebuild -version
xcrun simctl list runtimes | grep iOS
swift --version
```
