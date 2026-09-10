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
# → build/macos/MyApp.app
open build/macos/MyApp.app
```

If you're hacking on swift-pwa itself (or pinning to a specific
commit), substitute `swift run --package-path /path/to/swift-pwa
swift-pwa …` for the `swift-pwa` invocations above. The rest of the
flags are the same.

### Updating the CLI

```bash
swift-pwa self-update              # → latest release
swift-pwa self-update --version v0.6.3
```

Prefer this over `cp`-ing a fresh binary over the installed one. On
macOS, overwriting in place reuses the file's inode, and the kernel
caches a code-signing validation against that path/inode — so the new
binary's adhoc signature no longer matches the cache and the process is
`Killed: 9` on first run (it looks exactly like a corrupt download).
`self-update` installs with an atomic rename onto a fresh inode, which
sidesteps the trap; if you must replace the binary by hand, `rm` it
first, then copy (so the new file gets a new inode). If `swift-pwa`
lives somewhere root-owned (e.g. `/usr/local/bin`), run it with `sudo`.

The bundler:

1. Runs `swift build -c release`.
2. Lays out `MyApp.app/Contents/{MacOS,Resources}` from the manifest.
3. Writes `Info.plist` from `pwa.json` (bundle ID, version, minimum
   system version, `LSApplicationCategoryType`, `NSHumanReadableCopyright`),
   then merges any `macos.info_plist` passthrough on top (see below).
4. Copies the `web/` directory into `Contents/Resources/web`.
5. If `pwa.json.icon` points at a PNG, converts it to `AppIcon.icns`
   via `sips` + `iconutil`. The build prints a one-line icon summary —
   `swift-pwa: app icon ← icon.png (7 sizes)` on success, or the reason
   it fell back (no icon set / not a PNG / file missing / tool absent).
6. If `pwa.json.description` is set, writes a `Credits.html` so the
   description shows up as the body of the standard About panel.

### Universal binaries

```bash
swift-pwa build --target macos --arch arm64 --arch x86_64
# swift-pwa: universal binary — x86_64, arm64
```

`--arch` is repeatable and passes straight through to `swift build`,
which lipos the slices itself. Omit it and you get the host
architecture, as before. The build prints the slices it *found in the
binary* (via `lipo -archs`), not the ones you asked for, so a slice
that silently didn't happen shows up as a missing name.

A universal build is worth pairing with a signed one: the reason to
ship both slices is that the app leaves this machine.

### What travels in the `.app`

Everything the runtime needs is inside the bundle — `bridge.js` is
compiled into the binary rather than shipped as a SwiftPM resource
bundle, precisely because a resource bundle can't be reached from
inside a signed `.app` (see *Known limitations*). If your own code
reads resources, read them by path from `Contents/Resources`.

The check worth having in your own pipeline is the blunt one: build the
`.app`, delete `.build/`, and launch it. swift-pwa's CI does exactly
that on a freshly scaffolded app (`bundle-smoke` in
[.github/workflows/ci.yml](../.github/workflows/ci.yml)) — because
before 0.9.10 every bundle read its runtime out of the build
directory, and nothing noticed until an app was moved to another Mac.

### Custom `Info.plist` keys (`macos.info_plist`)

Anything the schema doesn't model goes through a passthrough object that's
merged into the generated plist (passthrough wins on collision). The
canonical case is reaching a local `http://localhost` dev service from the
WebView, which App Transport Security blocks by default:

```json
"macos": {
  "info_plist": {
    "NSAppTransportSecurity": { "NSAllowsLocalNetworking": true },
    "NSCameraUsageDescription": "Scan a code"
  }
}
```

Use the **exact** `Info.plist` key names (nested objects/arrays are
supported). The same `ios.info_plist` exists for the iOS bundle. This
removes the old need to patch the built plist with `PlistBuddy` in a
post-build step — though [`build.postbuild`](../README.md#configuring-pwajson)
is there if you need to.

The bundle filename and the `CFBundleName` / `CFBundleDisplayName`
Finder/dock label come from `name` (which may contain spaces, e.g.
"My App.app"), while the executable inside `Contents/MacOS/` and
`CFBundleExecutable` are named after the SwiftPM target — which can't
contain spaces. You don't have to keep the two in sync: the bundler
reads the real target name from the package (`swift package describe`),
so a spaced `name` just works. The optional `executable_name` overrides
that only when a package builds more than one executable. See the
[README](../README.md#configuring-pwajson) for the full rationale.

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

### The menu bar

The runtime installs a standard menu bar — app, **Edit** and **Window**
submenus — with no code on your part. You mostly won't think about it,
with one exception worth knowing: **the Edit menu is what makes text
fields work.**

On macOS the editing shortcuts are not a property of a text field.
They are main-menu *key equivalents*, dispatched down the responder
chain as `selectAll:` / `copy:` / `paste:` / `cut:` / `undo:`, and a
key equivalent matching no menu item is never dispatched at all — it
falls off the end of the chain and the app beeps. So an app with no
Edit menu cannot select-all, copy, paste, cut or undo in a text field,
however ordinary the page's HTML. (Before v0.10.4, none could.)

The items carry a `nil` target, which is what lets WebKit enable and
disable them against whatever is focused: Paste greys out when the
focus isn't editable, without swift-pwa knowing anything about your
page. Adding your own menus is a matter of appending to
`NSApp.mainMenu` in `configure(_:)`; the runtime sets it before your
closure runs, so anything you add survives.

### Links out of the app, and JavaScript dialogs

The runtime installs a `WKNavigationDelegate` and a `WKUIDelegate` on
every window, which decide two things a bare `WKWebView` gets wrong for
an app.

**A main-frame navigation that leaves the app's origin opens in the
default browser** instead of loading in place. In place is what a
webview does by default, and it strands the app — an `.app` window has
no address bar and no back button, so a click on someone's link turns
your app into a browser with no way home. Same-origin navigation,
subframes and `about:` / `blob:` / `data:` URLs are untouched; a window
created on `WindowContent.remote` treats *its own site* as the app.
`target="_blank"` goes the same way (there is no second window to give
the page, and `window.open` keeps returning `null`), except
same-origin, which loads in the current window rather than being
dropped.

**`alert()`, `confirm()` and `prompt()` are real sheets** — `NSAlert`
attached to the window that raised them, so one window's `confirm()`
doesn't block the rest of the app. `confirm()` returns the button and
`prompt()` the entered text, with Cancel giving `false` / `null`. A
dialog raised by a cross-origin subframe says which origin raised it.

Which URLs may be handed to the OS is `ctx.externalURLs`, seeded from
`pwa.json`'s `external_urls` — `http`, `https`, `mailto` and `tel`
always, anything else declared. `system.openURL` uses the same policy,
so a page has one answer for both routes out. See
[docs/javascript-api.md](javascript-api.md#systemopenurl--hand-a-url-to-the-operating-system).

> **The other direction isn't wired yet.** An app can declare a custom
> scheme in `macos.info_plist` and open it, but a URL the OS *delivers*
> to the app doesn't reach the page: `application(_:open:)` forwards
> only file URLs, onto `app.openFile`. So a deep link into your own app
> arrives nowhere. Tracked as
> [#177](https://github.com/tophatch/swift-pwa/issues/177).

### What happens when the last window closes (`macos.last_window_closed`)

macOS is the only platform here where an app outlives its windows: the
menu bar stays and the process keeps running. Linux and Windows exit
when the last window closes. Since ⌘W now works, that state is
reachable, so it's configurable:

```json
"macos": { "last_window_closed": "reopen" }
```

| value | behaviour |
| --- | --- |
| `reopen` *(default)* | Stay running, and reopen the window when the app is next activated — a Dock click, ⌘Tab, opening it again. What Finder, Safari and Mail do. |
| `keep-running` | Stay running with no window and don't reopen one. For an app whose real surface is a menu-bar item. |
| `quit` | Terminate once the last window closes, like a single-window utility — and like Linux and Windows already behave. |

The reopened window is rebuilt from the `WindowConfig` it was created
with, so it comes back as the app asked for it, including a remembered
size and position under `remember_state`. Page state is not preserved:
it loads fresh, exactly as a relaunch would.

Like the `window` block, this seeds the generated `App.swift` at
`swift-pwa init` time (`ctx.lastWindowClosed`) rather than being read
at runtime — editing `pwa.json` later means editing the generated
source too. `swift-pwa build` rejects a value that isn't one of the
three rather than ignoring it.

Choose `keep-running` only for an app that has a status item or some
other way back; without one it is the combination that strands a user.

To let a *user* choose — a checkbox in your settings UI — the page can
read and set the policy at runtime with `app.lastWindowClosed`; it
applies to the very next close. Storing their choice is your app's job,
and re-applying it at startup is one `invoke`. See
[docs/javascript-api.md](javascript-api.md#applastwindowclosed--what-closing-the-last-window-does).

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
codesign -dvvv build/macos/MyApp.app
spctl --assess --type execute --verbose build/macos/MyApp.app
```

## 6. Notarization

The bundler can notarize for you. Set up a notary keychain profile once:

```bash
xcrun notarytool store-credentials "<your-profile-name>" \
    --apple-id "you@example.com" --team-id "<TEAMID>"   # prompts for an app-specific password
```

Then pass `--notarize` (alongside `--sign`) and the build signs with a
hardened runtime, submits to Apple, waits for the verdict, and staples
the ticket — all in one step:

```bash
swift-pwa build --target macos \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    --notarize "<your-profile-name>"
```

A rejected submission fails the build. Stapled `.app`s pass
`spctl --assess` on first launch on a fresh machine. (`--notarize`
without `--sign` errors up front — Apple only accepts Developer
ID-signed apps.)

If you'd rather drive it yourself, the manual loop is `ditto -c -k
--keepParent`, `xcrun notarytool submit … --wait`, `xcrun stapler
staple`.

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
- **No Mac App Store flow.** The bundler doesn't build a `.pkg` or
  prepare the App Sandbox / `embedded.provisionprofile` layout that
  Mac App Store submissions require. `--sign` + `--entitlements` is
  geared at Developer ID distribution.
- **`Bundle.module` doesn't work inside a `.app`.** Not swift-pwa's
  runtime (it compiles `bridge.js` in), but your own target or a
  dependency that declares `resources:`. SwiftPM's generated accessor
  looks for the resource bundle beside `Bundle.main.bundleURL` — the
  `.app` **root** — and codesign refuses to seal anything there
  ("unsealed contents present in the bundle root"). The bundler stages
  those bundles into `Contents/Resources` (signable, and where a human
  would look), so read them by path from `Bundle.main.resourceURL`
  rather than through `Bundle.module`.

## Reporting issues

When filing a macOS issue, include:

```bash
sw_vers
xcodebuild -version
swift --version
```
