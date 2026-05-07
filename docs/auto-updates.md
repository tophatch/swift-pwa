# swift-pwa auto-updates

Opt-in, Tauri-style: a signed JSON manifest tells the running app where
to fetch the next bundle, the runtime downloads + verifies + installs
in place, and the next launch is the new version. The same manifest
format covers every platform — different artifacts under one
`platforms` table.

> **Status:** macOS bundle swap and iOS enterprise / ad-hoc
> (`itms-services://`) ship in `AppleUpdater` (v0.3). The
> `swift-pwa updater keygen / sign / manifest` CLI is landed on `main`
> for the v0.4 release. Linux AppImage and Windows MSIX / portable
> runtime backends are still queued for v0.4.

## Wiring the runtime

Construct a backend `Updater` and install the plugin. macOS uses
`AppleUpdater`; the same type provides an iOS enterprise / ad-hoc path
(pass `nil` for `publicKey` — Apple's signing chain validates the
.ipa). Linux GTK and Windows backends will follow the same shape once
they land.

```swift
import SwiftPWA

let runtime = try SwiftPWA.runtime()
try runtime.run { ctx in
    ctx.use(UpdaterPlugin(AppleUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "BASE64-OF-32-RAW-ED25519-BYTES" // nil on iOS
    )))

    _ = try ctx.createWindow(...)
}
```

`{{target}}` expands to `darwin-aarch64` / `darwin-x86_64` /
`ios-aarch64-enterprise` / `windows-x86_64-msix` /
`linux-x86_64-appimage`; `{{current_version}}` expands to the value of
`CFBundleShortVersionString` in the running bundle (override via the
`currentVersion:` arg).

## JS surface

```js
// Streaming run — typical "show update UI" flow. One subscription
// covers check + download; the UI doesn't have to coordinate two calls.
const unsub = __SWIFT_PWA__.subscribe("updater.run", null, (event) => {
    switch (event.type) {
        case "checking":         /* show spinner */ break;
        case "available":        /* event.info.version, event.info.notes */ break;
        case "upToDate":         /* hide spinner */ break;
        case "downloadProgress": /* event.bytesDownloaded, event.contentLength */ break;
        case "readyToInstall":
            // Prompt the user, then:
            __SWIFT_PWA__.invoke("updater.installAndRelaunch");
            break;
        case "error":            /* event.code, event.message */ break;
    }
});

// One-shot probe — useful for "Check for updates…" menu items.
const info = await __SWIFT_PWA__.invoke("updater.check");
if (info) console.log(`Update available: ${info.version}`);
```

The streaming `updater.run` accepts an optional `info` payload — pass
the result of `updater.check` straight in if you want to gate the
download behind a user prompt without re-fetching the manifest:

```js
const info = await __SWIFT_PWA__.invoke("updater.check");
if (info && confirm(`Install ${info.version}?`)) {
    __SWIFT_PWA__.subscribe("updater.run", { info }, ...);
}
```

## Manifest format (Tauri v1-compatible)

The `endpoint` URL serves a JSON document with one entry per supported
target. Per-target `signature` is base64 of the raw 64-byte Ed25519
signature over the artifact bytes; iOS enterprise leaves it empty
because `itms-services://` delegates trust to Apple's signing chain.

```json
{
  "version": "0.4.0",
  "pub_date": "2026-05-12T10:00:00Z",
  "notes": "Bug fixes and improvements.",
  "platforms": {
    "darwin-aarch64":         { "url": "https://.../HelloPWA-0.4.0-arm64.app.tar.gz", "signature": "RUR..." },
    "darwin-x86_64":          { "url": "https://.../HelloPWA-0.4.0-x86_64.app.tar.gz", "signature": "RUR..." },
    "ios-aarch64-enterprise": { "url": "https://.../HelloPWA-0.4.0-manifest.plist",    "signature": "" },
    "windows-x86_64-msix":    { "url": "https://.../HelloPWA-0.4.0-x64.msix",          "signature": "RUR..." },
    "linux-x86_64-appimage":  { "url": "https://.../HelloPWA-0.4.0-x86_64.AppImage",   "signature": "RUR..." }
  }
}
```

The format is byte-compatible with Tauri v1's updater manifest, so
existing publishing tooling (e.g. `tauri-action`) can produce
swift-pwa manifests as-is.

You can pre-declare the same wiring in `pwa.json` so `keygen` can print
a paste-ready block and the runtime side can read it from one source of
truth:

```json
"updater": {
  "endpoint": "https://updates.example.com/{{target}}/{{current_version}}",
  "public_key": "BASE64-OF-32-RAW-ED25519-BYTES",
  "pubkey_algorithm": "ed25519"
}
```

## Publishing — `swift-pwa updater` CLI

Three subcommands cover the publishing pipeline. They emit the same
wire format the runtime expects, so the round-trip is end-to-end
verified against `AppleUpdater.verifyEd25519` in CI.

### 1. `keygen` — one-time per app

Generates an Ed25519 keypair. The private file is written `0600` so a
stray `cat` from another shell on the dev box doesn't leak it; the
public file is `0644` and is meant to ship in `pwa.json`.

```bash
swift run swift-pwa updater keygen \
    --private-key key.priv \
    --public-key key.pub
```

The command also prints a paste-ready `pwa.json` `updater` block with
the public key already filled in. Pass `--force` to overwrite existing
files.

### 2. `sign` — per release artifact

Signs an artifact with the private key. Default output is
`<artifact>.sig`; pass `--stdout` to print the base64 signature
instead, or `-o <path>` to write somewhere specific.

```bash
swift run swift-pwa updater sign \
    --private-key key.priv \
    ./build/HelloPWA-0.4.0-arm64.app.tar.gz
# → wrote ./build/HelloPWA-0.4.0-arm64.app.tar.gz.sig
```

The signature is base64 of the raw 64-byte Ed25519 signature, byte-
compatible with what `AppleUpdater.verifyEd25519` (and the future
`LinuxAppImageUpdater` / `WindowsUpdater`) accepts.

### 3. `manifest` — assemble the JSON the endpoint URL serves

Each `--platform` spec is one of three forms — pick whichever fits
your release flow. The CLI parser correctly reassembles trailing `==`
base64 padding, so real Ed25519 signatures round-trip cleanly even
though `=` is the field separator.

| Form | When to use |
| :--- | :--- |
| `<target>=<artifact-path>=<download-url>` | One-shot — sign and embed in a single pass with `--private-key`. |
| `<target>=<download-url>=<base64-signature>` | Pre-signed (e.g. signature came out of an earlier `swift-pwa updater sign`, or from CI artefact metadata). |
| `<target>=<download-url>` | iOS enterprise / ad-hoc only — no signature, since `itms-services://` delegates trust to Apple. |

```bash
swift run swift-pwa updater manifest \
    --version 0.4.0 \
    --notes "Bug fixes and improvements." \
    --private-key key.priv \
    --platform darwin-aarch64=./build/HelloPWA-0.4.0-arm64.app.tar.gz=https://updates.example.com/HelloPWA-0.4.0-arm64.app.tar.gz \
    --platform darwin-x86_64=./build/HelloPWA-0.4.0-x86_64.app.tar.gz=https://updates.example.com/HelloPWA-0.4.0-x86_64.app.tar.gz \
    --platform ios-aarch64-enterprise=https://updates.example.com/HelloPWA-0.4.0-manifest.plist \
    --output manifest.json
```

`--pub-date` defaults to the current UTC time in ISO-8601 form; pass
it explicitly if you want the publication date pinned to your build's
timestamp rather than the manifest's. Pass `--force` to overwrite an
existing `manifest.json`.

The CLI uses `swift-crypto`'s `Crypto` module rather than `CryptoKit`,
so `keygen` and `sign` work on Linux and Windows release machines too;
on Apple platforms `import Crypto` shadows CryptoKit so signatures
produced under either toolchain are interchangeable.

## Per-platform notes

### macOS

The artifact under `darwin-aarch64` (or `darwin-x86_64`) must be a
`.app.tar.gz` — `tar -czf HelloPWA-0.4.0-arm64.app.tar.gz HelloPWA.app`.
The runtime downloads to
`~/Library/Caches/<bundle-id>/SwiftPWAUpdates/<version>/`, verifies the
Ed25519 signature over the gzip bytes, untars, and on
`updater.installAndRelaunch` spawns a detached `/bin/sh` helper that
waits for the parent PID to exit, `ditto`s the staged bundle in place
of the running one, and re-`open`s it (the standard Squirrel-style
trick).

`installAndRelaunch` requires a real bundled `.app`; running from
`swift run` (where `Bundle.main.bundleURL` points at `.build/...`)
returns a clean error explaining how to bundle first.

### iOS (enterprise / ad-hoc)

The App Store handles updates for store-distributed apps automatically;
`AppleUpdater` on iOS targets the enterprise (Apple Developer
Enterprise Program) and ad-hoc (provisioning profile lists specific
UDIDs) paths, which Apple lets users install via `itms-services://`
URLs the system installer trusts.

The contract is: the manifest entry under `ios-aarch64-enterprise`
points at the **install-manifest plist** on your server (not the
`.ipa`). The runtime opens
`itms-services://?action=download-manifest&url=<plist-url>`; the
system pulls the plist, downloads the `.ipa` it references, validates
the signing chain, and installs in place. No Ed25519 key is required
on the swift-pwa side because Apple's signing chain is what's being
trusted. See [docs/ios-setup.md](ios-setup.md) for a worked example
including the install-manifest plist format.

### Linux (queued for v0.4)

Plan: download + verify Ed25519 + `chmod +x` + atomic-rename onto the
running AppImage's path (the kernel keeps the running mmap valid; new
launches pick up the new file). The `pwa.json`
`updater.linux.appimage_strategy` field (`in_place` / `side_by_side`)
is reserved for that backend.

### Windows (queued for v0.4)

Plan: MSIX targets hand off to `PackageManager.AddPackageAsync` and
let the OS validate the signing chain (so swift-pwa only does Ed25519
over the bytes for tamper detection in transit); portable targets
download + verify + spawn a tiny detached helper that waits for the
parent to exit, replaces the EXE, and relaunches. The `pwa.json`
`updater.windows.install_mode` field (`passive` / `silent`) is
reserved for that backend.

## What's not in the first cut

- **Delta updates** — full-bundle replacement only. The wire format
  reserves room for a future `signature_delta` / `url_delta` per
  platform; bsdiff-style deltas are queued.
- **Mandatory updates / kill-switch** — no `min_supported_version`
  enforcement. Trivially additive — the runtime will refuse to start
  older clients once the field is wired.
- **Minisign-format public keys / signatures** — only raw base64
  (32-byte key, 64-byte signature) for now; minisign's preamble
  parsing is queued (Tauri's preferred format).
- **Fine-grained download progress on macOS** — single start + end
  progress events for now. Switching to `URLSessionDownloadDelegate`
  will give per-chunk progress.
- **macOS install fires no UI before swap** — apps that want a
  "Restart now / later" dialog should gate `updater.installAndRelaunch`
  behind their own prompt UI (the `readyToInstall` event from
  `updater.run` is the natural prompt point).
- **Linux AppImage and Windows MSIX / portable backends** —
  `AppleUpdater` ships in v0.3; `LinuxAppImageUpdater` and
  `WindowsUpdater` are queued for v0.4. The publishing CLI already
  emits manifests for those targets — the missing piece is the
  runtime side that consumes them.
