# Auto-updates

**Who this is for:** you ship a desktop (or Android) build and want it to update itself — check a URL you control, download the new version, verify it's really from you, swap it in, and relaunch. No app store required.

Assumes you've shipped a build once — see [Shipping your app](shipping-your-app.md).

> Uses swift-pwa **0.9+**. Verified end-to-end on macOS, Linux (AppImage), Windows (portable), and Android. Windows MSIX and iOS are preview (see [Platform status](#platform-status)). This is the guided tour; the exhaustive reference — every manifest field, target key, and per-backend knob — lives in [docs/auto-updates.md](../auto-updates.md).

---

## How it works, in one breath

You publish a small **signed JSON manifest** at a URL. Your app fetches it, compares the advertised version against its own, and — if there's a newer build — downloads the artifact, **verifies its Ed25519 signature against a public key baked into your app**, swaps it onto the running executable, and relaunches. The signature is what makes this safe: without your private key, nobody can push a build your app will install.

Two sides to set up: **publishing** (sign + serve the manifest) and the **runtime** (wire the plugin, drive it from JS).

---

## 1. Make a signing key (once per app)

```bash
swift run swift-pwa updater keygen \
    --private-key ./release.priv --public-key ./release.pub
```

Keep `release.priv` **secret** (a CI secret, a password manager — never in the repo). The public key is safe to ship; paste the printed block into `pwa.json`:

```json
"updater": {
  "endpoint": "https://updates.example.com/{{target}}/{{current_version}}",
  "public_key": "PASTE-THE-PRINTED-BASE64-HERE",
  "pubkey_algorithm": "ed25519"
}
```

`{{target}}` and `{{current_version}}` are expanded at check time (e.g. `darwin-aarch64` / `0.3.0`) so one endpoint can serve every platform.

---

## 2. Wire the runtime

Install `UpdaterPlugin` with the backend for your platform. It's opt-in — you decide when updates happen:

```swift
import SwiftPWA

try runtime.run { ctx in
    #if os(macOS) || os(iOS)
    ctx.use(UpdaterPlugin(AppleUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "YOUR-BASE64-PUBLIC-KEY" // nil on iOS — Apple's chain validates the .ipa
    )))
    #elseif os(Linux)
    ctx.use(UpdaterPlugin(LinuxAppImageUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "YOUR-BASE64-PUBLIC-KEY"
    )))
    #elseif os(Windows)
    ctx.use(UpdaterPlugin(WindowsUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "YOUR-BASE64-PUBLIC-KEY",
        installMode: .portable // or .msix, to match how you packaged
    )))
    #endif

    _ = try ctx.createWindow(...)
}
```

That's it for Swift — everything else is driven from your web UI.

---

## 3. Drive it from JS

The typical "Check for updates…" flow is one streaming subscription — `updater.run` composes *check + download* and reports progress:

```js
const unsub = __SWIFT_PWA__.subscribe("updater.run", null, (event) => {
  switch (event.type) {
    case "checking":    showSpinner(); break;
    case "upToDate":    toast("You're on the latest version."); break;
    case "available":   showBanner(`Update to ${event.info.version}`); break;
    case "downloadProgress":
      setProgress(event.bytesDownloaded, event.contentLength); break;
    case "readyToInstall":
      // Prompt, then apply — this replaces the running process.
      if (confirm("Restart to finish updating?"))
        __SWIFT_PWA__.invoke("updater.installAndRelaunch");
      break;
    case "error": showError(event.code, event.message); break;
  }
});
```

Prefer a quiet probe for a menu item? `const info = await __SWIFT_PWA__.invoke("updater.check")` returns the `UpdateInfo` (or `null` when up to date) without downloading anything.

`readyToInstall` is your prompt point — the download is verified and staged, but nothing is swapped until you call `updater.installAndRelaunch`. Gate that behind your own "Restart now / later" UI.

---

## 4. Check in the background (optional)

Want the app to notice updates on its own instead of waiting for a click? Turn on `autoCheck`:

```swift
ctx.use(UpdaterPlugin(
    AppleUpdater(endpoint: …, publicKey: …),
    autoCheck: true,
    checkInterval: 21600 // seconds; default 6h, minimum 60s
))
```

The runtime then checks on launch and every `checkInterval` after, pushing any available update to JS on the **`updater.updateAvailable`** channel. The payload is retained, so a listener that subscribes late still gets the latest:

```js
__SWIFT_PWA__.on("updater.updateAvailable", (info) => {
  showBanner(`Update to ${info.version} is available`);
  // then, when the user agrees, kick off updater.run to download + install.
});
```

(These mirror `pwa.json`'s `updater.auto_check` / `check_interval_seconds` — pass those values through.)

---

## 5. Force a critical update (kill-switch)

Shipped a build with a bad bug? Add a floor to the manifest and older builds learn they *must* upgrade. Publish it with `--min-supported-version`, and the update arrives with **`mandatory: true`**:

```js
const info = await __SWIFT_PWA__.invoke("updater.check");
if (info?.mandatory) {
  // Don't let the user dismiss this one.
  showBlockingUpdateGate(info);
} else if (info) {
  showDismissibleBanner(info);
}
```

`mandatory` is `true` whenever the running build is *older* than `min_supported_version`; builds at or above the floor (and manifests without one) report `false`. swift-pwa surfaces the flag — **enforcing** it (blocking the UI until the update installs) is your app's call.

---

## 6. Publish a release

When you cut a new version, sign the artifact(s) and assemble the manifest in one pass:

```bash
swift run swift-pwa updater manifest \
    --version 0.4.0 \
    --notes "Bug fixes and improvements." \
    --min-supported-version 0.3.0 \
    --private-key ./release.priv \
    --platform darwin-aarch64=./build/MyApp-0.4.0-arm64.app.tar.gz=https://updates.example.com/MyApp-0.4.0-arm64.app.tar.gz \
    --output ./manifest.json
```

Upload the artifact(s) and `manifest.json` to the URL your `endpoint` points at, and existing installs pick it up on their next check. (Drop `--min-supported-version` for an ordinary optional release.) The manifest is Tauri-v1-compatible, so CI tooling like `tauri-action` can produce it too — full field reference in [docs/auto-updates.md](../auto-updates.md).

---

## Platform status

| Platform | Status |
| :------- | :----- |
| macOS (`.app`) | Verified end-to-end (ad-hoc + codesigned) |
| Linux (AppImage) | Verified end-to-end (incl. cross-filesystem staging) |
| Windows (portable `.exe`) | Verified end-to-end |
| Android (APK, `PackageInstaller`) | Verified end-to-end |
| Windows MSIX | Preview — install logic compile-verified; needs a signed package + trusted cert |
| iOS | Preview — uses `itms-services://`, needs an enterprise/ad-hoc distribution cert |

Before relying on it in production, walk the Updater cases in [docs/manual-test-cases.md](../manual-test-cases.md) for your platform.

---

## Where to go next

- [docs/auto-updates.md](../auto-updates.md) — the complete reference: every manifest field, target-key derivation, minisign-format keys, and per-backend behavior/caveats.
- [Shipping your app](shipping-your-app.md) — building and distributing the releases auto-updates consume.
- [JavaScript API](../javascript-api.md) — the full `updater.*` surface.
