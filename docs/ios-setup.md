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

A device install needs two things a simulator build doesn't: an embedded
**provisioning profile** (`embedded.mobileprovision`) whose
`ProvisionedDevices` lists your device's UDID, and a code signature carrying
**entitlements** (`application-identifier`, `get-task-allow`, …). Without
both, the install succeeds but launch is denied (*"invalid code signature,
inadequate entitlements or its profile has not been explicitly trusted"*).

So `swift-pwa build --target ios` for a device **fails fast** unless you sign
it — it won't emit an `.ipa` that looks installable but can't launch. Pass
`--sign`, plus a profile and entitlements:

```bash
swift-pwa build --target ios \
  --sign "Apple Development: you@example.com (TEAMID)" \
  --provisioning-profile path/to/app.mobileprovision \
  --entitlements path/to/app.entitlements
# → build/MyApp.ipa  (profile embedded, signed with entitlements)
```

The bundler runs the `xcodebuild` phase **unsigned** (`CODE_SIGNING_ALLOWED=NO`)
and does *all* signing afterward on the assembled `.app`: it embeds the
profile, signs the nested resource bundles, then signs the app with your
entitlements (`--generate-entitlement-der`). Building unsigned matters — the
product is a SwiftPM target, which `xcodebuild` can't auto-provision, so
passing a signing identity to the build phase would fail with *"requires a
development team"* before the post-assembly signing runs. Because we sign
after assembly, **no `DEVELOPMENT_TEAM` or `.xcodeproj` is needed** — a
free-personal-team identity works. Run `swift-pwa doctor --target ios` first —
it checks for a valid signing identity and flags the classic missing **Apple
WWDR intermediate** (a cert that's present but untrusted won't sign).

### `--team`: fewer flags when you already have signing set up

If you've already got Xcode-managed signing (an identity in your keychain and
an installed provisioning profile for the app's bundle id — see below), pass
just your 10-character **Team ID** and swift-pwa fills in the rest:

```bash
swift-pwa build --target ios --team ABCDE12345
# → selects that team's "Apple Development" identity,
#   finds a matching installed .mobileprovision,
#   derives entitlements from it, then signs as usual.
```

It only fills the inputs you didn't pass — any explicit `--sign` /
`--provisioning-profile` / `--entitlements` wins. For a **paid** team it finds an
installed portal profile; if none matches it says so and you fall back to the
explicit flags. Find your Team ID with `security find-identity -v -p codesigning`
(the `(……)` suffix) or in the Apple Developer portal.

#### Free personal teams

A **free personal team** has no portal profile to find. Add
`--allow-provisioning-registration` and swift-pwa mints one for you:

```bash
swift-pwa build --target ios --team ABCDE12345 --allow-provisioning-registration
# or, in one step onto the device:
swift-pwa deploy --target ios --team ABCDE12345 --allow-provisioning-registration
```

When `--team` finds no installed profile, this builds a **throwaway one-file app
project** with your app's bundle id against a target device (the sole connected
one, or `--device <udid|name>`) using `xcodebuild -allowProvisioningUpdates
-allowProvisioningDeviceRegistration` — so Xcode registers the device, creates
the App ID, and emits a profile — then signs your real app with it. The flag name
echoes `xcodebuild`'s own consent flag; it's the one step that touches Apple's
portal, so it's opt-in. Free-team profiles expire after 7 days, so re-run when it
lapses. macOS-only. First time on a new Apple ID, you may need to accept the
free-team agreement by building any app to the device from Xcode once.

### Getting a profile + entitlements

A SwiftPM executable target isn't an app product type, so `xcodebuild`
won't auto-provision it. Two ways to obtain the profile:

- **Paid team / CI:** download a profile from the Apple Developer portal (or
  `fastlane sigh`), and extract its entitlements:
  `security cms -D -i app.mobileprovision > p.plist && /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' p.plist > app.entitlements`.
- **Personal (free) team:** let swift-pwa mint the profile —
  `--team <TEAMID> --allow-provisioning-registration` (see
  [Free personal teams](#free-personal-teams) above). After the first install, trust the developer profile on the device
  once (Settings → General → VPN & Device Management). If you'd rather do it by
  hand, build a one-file throwaway app target with the **same bundle id** in
  Xcode once with *Automatically manage signing* and reuse the emitted
  `embedded.mobileprovision` with the explicit flags.

Then install with `xcrun devicectl device install app build/MyApp.ipa` (or
`swift-pwa deploy --target ios …`). Alternatively, just run from Xcode
(`xed Package.swift` → pick your device → *Run*) and let it manage signing.

For TestFlight / App Store distribution, `xcodebuild archive` →
`xcodebuild -exportArchive -exportOptionsPlist ...` is still the canonical
chain (a CLI wrapper is a later follow-up).

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

- **On-device install needs a provisioning profile — the CLI can mint one for
  free teams.** `swift-pwa build --target ios --sign <identity>` alone runs
  `codesign` but embeds no profile, so its `.ipa` won't install on a device.
  Provide a profile (`--provisioning-profile` + `--entitlements`), let `--team`
  find an installed one (paid teams), or add
  `--allow-provisioning-registration` to mint one for a free personal team (see
  [Free personal teams](#free-personal-teams)). `swift-pwa deploy --target ios`
  then installs + launches via `devicectl`.
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
- **Use `dialog.exportFile` — not `dialog.saveFile` — to save on iOS.**
  `saveFile` returns a *destination path the caller writes to*, which iOS
  has no panel for; it returns `nil` (and logs a one-shot stderr warning
  the first time). `dialog.exportFile` is the content-first primitive
  that *does* work: pass the bytes (`dataBase64`) or a source file
  (`path`), and the runtime materializes the content, presents
  `UIDocumentPickerViewController(forExporting:)`, and returns the
  location the user chose (or `nil` if cancelled). It's the same command
  everywhere — desktop and Android implement it too — so a save flow
  written against `exportFile` is portable. The other dialog commands
  (`message`, `confirm`, `openFile`, `openDirectory`) all work —
  `openFile` and `openDirectory` route through
  `UIDocumentPickerViewController` in opening / folder mode. See
  [docs/javascript-api.md](javascript-api.md#dialog).
- **`pwa.json.icon` drives both the home-screen App Icon and the
  launch screen.** From the single 1024×1024 PNG the bundler compiles
  a real `AppIcon` via `actool` (a single "universal" asset — Xcode
  generates the full size set — and the resulting `CFBundleIcons*` keys
  are merged into `Info.plist`), and also generates a minimal
  `LaunchScreen.storyboard` with the icon centered on a black background
  (compiled via `ibtool`). App-icon generation is best-effort: if the
  icon is missing / not a PNG, or `actool` can't run, the build falls
  back to the system default rather than failing — the build prints a
  one-line icon summary either way (`swift-pwa: app icon ← icon.png`, or
  the fallback reason). Alternate-icon support
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
