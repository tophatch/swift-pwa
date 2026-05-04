# swift-pwa on macOS (WKWebView)

Tested target: macOS 15 (Sequoia) on Apple silicon, Xcode 26.x. Should
work on Intel via the universal toolchain too — nothing in the package
is arch-specific.

## 1. Toolchain

`swift-pwa` requires Swift 6.0+ and macOS 15+ headers, so the simplest
setup is the full Xcode install.

```bash
# Full Xcode (recommended — also gives you Simulator / iOS support).
xcode-select --install        # if you only want the command-line tools
xcodebuild -version           # expect Xcode 26+
swift --version               # expect 6.0+
```

If you have multiple Xcodes installed, point `xcode-select` at the one
you want SwiftPM to use:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 2. Clone and build

```bash
git clone https://github.com/tophatch/swift-pwa
cd swift-pwa

swift build                                    # Core, WebKit backend, CLI, examples
swift test                                     # 80+ tests including WKWebView integration
```

The `WKWebViewTests` suite spins up a real `WKWebView` in-process and
exercises the bridge end-to-end, so it needs a logged-in graphical
session — `ssh` without `-Y` won't work for that suite, but the rest
of the test matrix runs fine headless.

## 3. Run the example

```bash
swift run --package-path Examples/HelloPWA HelloPWA
```

A `WKWebView` window opens loading `pwa://localhost/index.html`. Click
the buttons; the JS console should round-trip through `BridgeRuntime`.

## 4. Bundle a `.app`

```bash
swift run swift-pwa init MyApp
cd MyApp
swift run swift-pwa build --target macos
# → build/MyApp.app
open build/MyApp.app
```

The bundler:

1. Runs `swift build -c release`.
2. Lays out `MyApp.app/Contents/{MacOS,Resources}` from the manifest.
3. Writes `Info.plist` from `pwa.json` (bundle ID, version, minimum
   system version).
4. Copies the `web/` directory into `Contents/Resources/web`.
5. If `pwa.json.icon` points at a PNG, converts it to `AppIcon.icns`
   via `sips` + `iconutil`.

## 5. Codesigning

For a quick local run you don't need signing — Gatekeeper will warn
once and remember the exception. For anything you'll share, sign with
a Developer ID Application certificate from your Apple Developer
account:

```bash
# List available identities.
security find-identity -v -p codesigning

# Sign during the build.
swift run swift-pwa build --target macos \
    --sign "Developer ID Application: Jane Doe (TEAMID1234)"

# Optionally pass entitlements (e.g. for hardened runtime + camera).
swift run swift-pwa build --target macos \
    --sign "Developer ID Application: Jane Doe (TEAMID1234)" \
    --entitlements MyApp.entitlements
```

Verify the signature:

```bash
codesign -dvvv build/MyApp.app
spctl --assess --type execute --verbose build/MyApp.app
```

## 6. Notarization

The bundler doesn't run notarization itself — you have to invoke it
separately on the signed `.app`. Set up a notary keychain profile
once with `xcrun notarytool store-credentials`, then per build:

```bash
# Zip the .app for submission (notarytool wants a flat archive).
ditto -c -k --sequesterRsrc --keepParent build/MyApp.app build/MyApp.zip

# Submit and wait for the verdict.
xcrun notarytool submit build/MyApp.zip \
    --keychain-profile "<your-profile-name>" \
    --wait

# On success, staple the ticket into the .app so Gatekeeper
# accepts it offline.
xcrun stapler staple build/MyApp.app
xcrun stapler validate build/MyApp.app
```

Stapled `.app`s pass `spctl --assess` on first launch on a fresh
machine.

## Known limitations on macOS

- **Notarization is pass-through, not automated.** The bundler stops
  at codesign. Wire the `notarytool` step into your release script
  or CI.
- **No Mac App Store flow.** The bundler doesn't build a `.pkg` or
  prepare the App Sandbox / `embedded.provisionprofile` layout that
  Mac App Store submissions require. `--sign` + `--entitlements` is
  geared at Developer ID distribution.
- **Universal binaries aren't built for you.** `swift build` uses
  the host arch; if you need x86_64 + arm64, build twice and `lipo
  -create` the binaries yourself before bundling.

## Reporting issues

When filing a macOS issue, include:

```bash
sw_vers
xcodebuild -version
swift --version
```
