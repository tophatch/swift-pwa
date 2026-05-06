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
swift test                                     # 50+ tests including WKWebView integration
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

The fastest path is the prebuilt CLI from the latest GitHub release —
no `swift run` overhead for every command. Pick the asset matching
your arch:

```bash
# Apple silicon:
curl -L https://github.com/tophatch/swift-pwa/releases/latest/download/swift-pwa-macos-arm64 \
    -o /usr/local/bin/swift-pwa
chmod +x /usr/local/bin/swift-pwa

# Intel:
# curl -L https://github.com/tophatch/swift-pwa/releases/latest/download/swift-pwa-macos-x86_64 \
#     -o /usr/local/bin/swift-pwa

swift-pwa init MyApp
cd MyApp
swift-pwa build --target macos
# → build/MyApp.app
open build/MyApp.app
```

If you're hacking on swift-pwa itself (or pinning to a specific
commit), substitute `swift run --package-path /path/to/swift-pwa
swift-pwa …` for the `swift-pwa` invocations above. The rest of the
flags are the same.

The bundler:

1. Runs `swift build -c release`.
2. Lays out `MyApp.app/Contents/{MacOS,Resources}` from the manifest.
3. Writes `Info.plist` from `pwa.json` (bundle ID, version, minimum
   system version, `LSApplicationCategoryType`, `NSHumanReadableCopyright`).
4. Copies the `web/` directory into `Contents/Resources/web`.
5. If `pwa.json.icon` points at a PNG, converts it to `AppIcon.icns`
   via `sips` + `iconutil`.
6. If `pwa.json.description` is set, writes a `Credits.html` so the
   description shows up as the body of the standard About panel.

### About panel

The bundler wires the standard About panel up automatically from
`pwa.json` — no runtime code required. It pulls:

- **App name** from `name` (via `CFBundleName`).
- **Version** from `version` (via `CFBundleShortVersionString`).
- **Icon** from `icon` (via `CFBundleIconFile` → `AppIcon.icns`).
- **Copyright line** under the version from `macos.copyright` (via
  `NSHumanReadableCopyright`).
- **Body text** from `description`, written into a `Credits.html`
  resource that AppKit picks up automatically.

For a richer About panel (formatted text, links), drop your own
`Resources/Credits.html` or `Credits.rtf` into the `.app` after the
build — the bundler-generated one is just plain `description` text.

## 5. Codesigning

For a quick local run you don't need signing — Gatekeeper will warn
once and remember the exception. For anything you'll share, sign with
a Developer ID Application certificate from your Apple Developer
account:

```bash
# List available identities.
security find-identity -v -p codesigning

# Sign during the build.
swift-pwa build --target macos \
    --sign "Developer ID Application: Jane Doe (TEAMID1234)"

# Optionally pass entitlements (e.g. for hardened runtime + camera).
swift-pwa build --target macos \
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

## 7. Auto-updates

Opt-in, signed JSON manifest format (Tauri v1-compatible). One
subscription on the JS side covers the full check + download + install
flow; the runtime handles the bundle swap via a detached `/bin/sh`
helper that waits for the running app to exit, `ditto`s the new bundle
in place of the old one, and re-`open`s it. See
[docs/auto-updates.md](auto-updates.md) for the full JS surface and
manifest format.

Quick wiring:

```swift
import SwiftPWA

ctx.use(UpdaterPlugin(AppleUpdater(
    endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
    publicKey: "BASE64-OF-32-RAW-ED25519-BYTES"
)))
```

The macOS artifact under `darwin-aarch64` (or `darwin-x86_64`) must be
a `.app.tar.gz` — `tar -czf HelloPWA-0.4.0-arm64.app.tar.gz HelloPWA.app`.
The `signature` field in the manifest entry is base64 of the raw
64-byte Ed25519 signature over the gzip bytes (signing tooling
ships with `swift-pwa updater sign` in v0.4 — for now use any
Ed25519 signer that emits raw bytes).

`installAndRelaunch` requires a real bundled `.app`; running from
`swift run` (where `Bundle.main.bundleURL` points at `.build/...`)
returns a clean error explaining how to bundle first.

## Known limitations on macOS

- **Auto-updater install fires no UI before swapping.** The runtime
  hands off to the detached helper as soon as `updater.installAndRelaunch`
  is called. Apps that want a "Restart now / later" dialog should gate
  the call behind their own UI (the `readyToInstall` event from
  `updater.run` is the natural prompt point).
- **Auto-updater download progress is start + end only.** Fine-grained
  `URLSessionDownloadDelegate`-driven streaming progress is queued for
  a follow-up; for now the `downloadProgress` events fire once at zero
  bytes and once at completion.
- **Auto-updater signatures are raw base64 only.** Minisign-format
  parsing (Tauri's preferred form) is queued. For now, the manifest's
  `public_key` is base64 of the raw 32-byte Ed25519 key and per-target
  `signature` is base64 of the raw 64-byte signature.
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
