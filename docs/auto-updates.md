# swift-pwa auto-updates

Opt-in, Tauri-style: a signed JSON manifest tells the running app where
to fetch the next bundle, the runtime downloads + verifies + installs
in place, and the next launch is the new version. The same manifest
format covers every platform — different artifacts under one
`platforms` table.

> **Status:** macOS bundle swap and iOS enterprise / ad-hoc
> (`itms-services://`) ship in `AppleUpdater` (v0.3). The
> `swift-pwa updater keygen / sign / manifest` CLI, the Linux AppImage
> runtime (`LinuxAppImageUpdater`), and the Windows portable + MSIX
> runtime (`WindowsUpdater`) are all landed on `main` for the v0.4
> release. Every supported platform now has both publishing and
> consuming sides of the pipeline.
>
> ⚠️ **The runtime backends ship as preview in v0.4.** Implementation
> complete, 134 unit tests pass, but the OS-level install paths
> (`ditto` swap on macOS, atomic `rename(2)` on Linux, `Move-Item` /
> `Add-AppxPackage` on Windows, `itms-services://` on iOS) haven't
> been walked end-to-end against real bundled artifacts in this
> release. Walk [manual-test-cases.md](manual-test-cases.md) before
> shipping production updates. The publishing CLI is fully tested.

## Wiring the runtime

Construct a backend `Updater` and install the plugin. macOS and iOS
use `AppleUpdater` (pass `nil` for `publicKey` on iOS — Apple's signing
chain validates the .ipa). Linux uses `LinuxAppImageUpdater`. Windows
uses `WindowsUpdater`, which takes an `installMode` of `.portable` or
`.msix` to pick between EXE-replacement and `Add-AppxPackage`.

```swift
import SwiftPWA

let runtime = try SwiftPWA.runtime()
try runtime.run { ctx in
    #if os(macOS) || os(iOS)
    ctx.use(UpdaterPlugin(AppleUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "BASE64-OF-32-RAW-ED25519-BYTES" // nil on iOS
    )))
    #elseif os(Linux)
    ctx.use(UpdaterPlugin(LinuxAppImageUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "BASE64-OF-32-RAW-ED25519-BYTES",
        currentVersion: "0.4.0" // or pull from your own config
    )))
    #elseif os(Windows)
    ctx.use(UpdaterPlugin(WindowsUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "BASE64-OF-32-RAW-ED25519-BYTES",
        installMode: .portable, // or .msix to match how you packaged
        currentVersion: "0.4.0"
    )))
    #endif

    _ = try ctx.createWindow(...)
}
```

`{{target}}` expands to `darwin-aarch64` / `darwin-x86_64` /
`ios-aarch64-enterprise` / `windows-x86_64-msix` /
`windows-x86_64-portable` / `linux-x86_64-appimage` /
`linux-aarch64-appimage` / `android-aarch64-apk` /
`android-x86_64-apk`; `{{current_version}}` expands to the value of
`CFBundleShortVersionString` (or the equivalent per-platform version
string — `BuildConfig.versionName` on Android, override via the
`currentVersion:` arg on every backend).

### Automatic background checks (`auto_check`)

By default the plugin is on-demand — nothing checks for updates until JS
calls `updater.check` / `updater.run`. Opt into background polling by
passing `autoCheck: true` (and, optionally, a `checkInterval` in
seconds — mirroring `pwa.json`'s `updater.auto_check` /
`check_interval_seconds`; the default is 6 hours, floored at 60s):

```swift
ctx.use(UpdaterPlugin(
    AppleUpdater(endpoint: …, publicKey: …),
    autoCheck: true,
    checkInterval: 21600
))
```

The runtime then checks on launch and every `checkInterval` after,
pushing any available update to JS on the **`updater.updateAvailable`**
event-bus channel (transient network failures are swallowed and retried
next tick). The payload is the same `UpdateInfo` `updater.check` returns
— including the `mandatory` flag — and is *retained*, so a listener that
subscribes after a check still receives the latest:

```js
__SWIFT_PWA__.on("updater.updateAvailable", (info) => {
  if (info.mandatory) forceUpdateGate(info);       // kill-switch
  else showUpdateBanner(info);                      // then updater.run
});
```

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
  "min_supported_version": "0.3.0",
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

### Mandatory updates (`min_supported_version` kill-switch)

`min_supported_version` is optional. When present, any running build
*older* than that floor is force-upgraded: `updater.check` (and the
`available` event from `updater.run`) sets **`mandatory: true`** on the
resolved update, so the app can block usage until it installs — a
security kill-switch for retiring a build with a critical bug. Builds
at or above the floor get `mandatory: false` (an ordinary optional
update). Omit the field and every update is optional.

```js
const info = await __SWIFT_PWA__.invoke("updater.check");
if (info?.mandatory) {
  // Don't let the user dismiss — drive straight into the update.
  showBlockingUpdateGate(info);
}
```

The floor is *advisory to the app*: swift-pwa surfaces the flag but
doesn't itself refuse to run (the running build is already launched by
the time it can fetch a manifest). Enforcement is the app's call — gate
your UI on `mandatory`. Publish it with
`swift-pwa updater manifest --min-supported-version 0.3.0 …`.

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
    --platform android-aarch64-apk=./build/android/HelloPWA-android/app/build/outputs/apk/release/app-release.apk=https://updates.example.com/HelloPWA-0.4.0-arm64.apk \
    --output manifest.json
```

Add `--min-supported-version 0.3.0` to stamp the mandatory-update floor
(see [Mandatory updates](#mandatory-updates-min_supported_version-kill-switch)
above); omit it for all-optional releases.

The CLI itself doesn't validate target names — any string the
publisher uses must match what the runtime's `Updater` implementation
computes via `UpdaterTarget.current(packageFormat:)`. Use the keys
listed in §`{{target}}` above; bespoke target strings are fine as
long as both sides agree.

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

### Linux (AppImage)

`LinuxAppImageUpdater` downloads the new AppImage, verifies the Ed25519
signature, `chmod +x`s it, and on `updater.installAndRelaunch`
**atomically renames** the staged file onto the running AppImage's path
— Linux `rename(2)` is atomic within a filesystem and replaces the
destination, while the running process keeps its mmap of the old inode
valid until it exits. Once the rename lands, the updater spawns the
(now-updated) AppImage as a detached child via `setsid` and `exit(0)`s.
Cross-filesystem rename (`EXDEV`) falls back to `copy → rename` via a
temp file in the destination directory so the final swap is still
atomic.

The running AppImage's path is read from the `APPIMAGE` environment
variable that the AppImage runtime sets when launching the embedded
ELF. `installAndRelaunch` returns a clear error if that's unset
(running from `swift run` or `.build/...`); bundle with
`swift run swift-pwa build --target linux` and run from the resulting
`.AppImage` to exercise the full pipeline. Stage by default to
`${XDG_CACHE_HOME:-$HOME/.cache}/<bundle-id>/SwiftPWAUpdates/<version>/`.

The `pwa.json` `updater.linux.appimage_strategy` field (`in_place` /
`side_by_side`) is reserved for a future iteration that writes the new
AppImage alongside the old one and updates a `~/.local/bin` symlink
instead of replacing the file in place; v0.4 is `in_place` only.

### Windows (portable + MSIX)

`WindowsUpdater` covers both formats `swift-pwa build --target windows`
produces. Pick the install mode that matches how you packaged.

**Portable mode** (`installMode: .portable`). `download` fetches the
new EXE, verifies the Ed25519 signature, and stages it under
`%LOCALAPPDATA%\<bundle-id>\SwiftPWAUpdates\<version>\`.
`installAndRelaunch` writes a tiny PowerShell helper, spawns it
detached via `powershell.exe -EncodedCommand …`, and `exit(0)`s. The
helper does `Wait-Process -Id <pid>` (so the running EXE releases the
file lock), `Move-Item -Force` the staged EXE onto the running EXE's
path (resolved with `GetModuleFileNameW`), and `Start-Process`es the
result. We use `-EncodedCommand` rather than dropping a `.ps1` on disk
both to avoid the default Restricted execution policy and to dodge
PowerShell's command-line quoting rules (which break on paths
containing brackets, single quotes, or non-ASCII characters).

**MSIX mode** (`installMode: .msix`). `download` fetches the new
`.msix` and signature-verifies it (Ed25519 is best-effort here:
Authenticode is the real authentication, but our signature pins
*which* signed package this updater channel is allowed to install).
`installAndRelaunch` spawns the same kind of helper, but instead of
`Move-Item` the helper runs `Add-AppxPackage -Path <staged>
-ForceUpdateFromAnyVersion`. The OS validates the chain and updates
the package on disk; the running EXE keeps the old code mapped until
it exits, so `WindowsUpdater` returns control to the helper and the
runtime `exit(0)`s. If you supply `msixIdentityName:` (matching the
`Identity.Name` value in your `AppxManifest.xml` — derived from
`pwa.json`'s `id` if you used `swift-pwa build --target windows
--package-format msix` to package), the helper looks the package up
via `Get-AppxPackage -Name`, resolves the AUMID, and re-launches the
updated app via `Start-Process shell:AppsFolder\<family>!<app-id>` ~500
ms after the install completes. Without `msixIdentityName:` the helper
skips the relaunch line and the user re-launches from Start manually.

For the public-key argument: `.portable` requires it (a swappable EXE
is full code execution; verifying signatures is non-negotiable);
`.msix` accepts `nil` if you want to trust Authenticode unconditionally
and skip Ed25519. Production deployments should set it on both modes.

The `pwa.json` `updater.windows.install_mode` field (`passive` /
`silent`) is reserved for a future iteration — `Add-AppxPackage`
currently runs in its default mode (foreground UI on errors only;
silent on success).

## Minisign-format keys and signatures

Both the runtime verifiers and the publishing CLI accept either raw
base64 (32-byte key / 64-byte signature) *or* the two-line
[minisign](https://jedisct1.github.io/minisign/) `untrusted comment:
…\n<base64>` shape — pick whichever fits your release pipeline. The
runtime detects which form the input is in and falls through cleanly:

- Plain base64 still works as before — no migration needed for v0.3
  pipelines.
- Existing minisign public-key files can be embedded verbatim in
  `pwa.json`'s `updater.public_key` (escape newlines as `\n` so the
  surrounding JSON parses cleanly).
- `swift-pwa updater keygen --minisign` writes the public key in
  minisign format.
- `swift-pwa updater sign --minisign` writes the signature in
  minisign format.

swift-pwa supports the legacy `Ed` algorithm only (pure Ed25519 over
the artifact bytes). The modern prehashed `ED` mode (BLAKE2b-256) is
rejected with a message pointing at `minisign -Sl` to produce a
legacy-mode signature. Tauri's publishing pipelines also use legacy
mode, so swift-pwa apps and Tauri apps can share signing tooling.

The trusted-comment block on minisign signatures is informational —
swift-pwa doesn't verify the global signature over it. Verification
happens against the artifact bytes only.

## Delta (binary-patch) updates

Ship only the **binary diff** between the installed build and the new one
instead of re-downloading the whole artifact. On a typical point release
this cuts the download by one to two orders of magnitude (a multi-MB
artifact with a small change → a patch of a few hundred bytes to a few KB).

**How it stays safe:** the client picks the patch whose `from` matches its
running version, downloads it, **reconstructs the new artifact locally**,
and then runs the **same** Ed25519 signature check against the
*reconstructed* bytes that a full download runs. The delta carries no
signature of its own — trust rests entirely on the reconstructed artifact
verifying against the public key baked into your app. A tampered or corrupt
patch simply produces bytes that fail that check, and the client
**transparently falls back to a full download**. So does a missing patch
(the running version isn't listed) or a base-SHA mismatch (the installed
bytes aren't what the patch was cut against). Deltas are a fast path, never
a hard dependency.

**Supported backends.** Reconstruction needs the *signed artifact bytes* on
disk as the patch base. On Linux/Windows the installed file **is** that
artifact; on macOS it isn't (the installed thing is an extracted `.app`), so
the backend keeps a cached copy of the last verified `.app.tar.gz` to patch
against instead:

| Backend | Delta? | Base the patch applies to |
| :------ | :----- | :-- |
| Linux AppImage | ✅ | the installed AppImage (`$APPIMAGE`) — it *is* the signed artifact |
| Windows portable `.exe` | ✅ | the installed EXE — it *is* the signed artifact |
| macOS `.app` | ✅ | a **cached** copy of the last verified `.app.tar.gz` (see below) |
| Windows MSIX | ❌ | the OS installer owns the package bytes |
| Android APK | ❌ | the system re-derives the installed APK |
| iOS | ❌ | `itms-services://` hands the transfer to Apple |

Unsupported backends just full-download, as before.

**macOS specifics.** Because macOS installs the *extracted* `.app` and
discards the signed `.app.tar.gz`, `AppleUpdater` caches the last verified
tarball (one artifact's worth of disk, under
`~/Library/Caches/<bundle-id>/SwiftPWAUpdates/base/`) and patches *that* on
the next update. Two consequences: (1) the **first** update after you adopt
this always full-downloads — there's no cached base yet — and then caches the
base, so updates from that point on can go delta; (2) you publish the macOS
delta exactly like any other, passing the old **`.app.tar.gz`** (not the
`.app`) as the base artifact. gzip is often assumed to be "diff-hostile", but
DEFLATE resynchronizes within a bounded (~32 KB) window, so a localized
change to a `.app` yields a small patch in practice — measured across
incompressible binaries and compressible web bundles alike.

**Publishing.** Add one repeatable `--delta` per prior version you want to
serve a patch for:

```bash
swift-pwa updater manifest \
    --version 0.4.0 \
    --private-key ./release.priv \
    --platform linux-x86_64-appimage=./build/MyApp-0.4.0.AppImage=https://updates.example.com/MyApp-0.4.0.AppImage \
    --delta    linux-x86_64-appimage=0.3.0=./build/MyApp-0.3.0.AppImage=https://updates.example.com/MyApp-0.3.0-to-0.4.0.zstpatch \
    --delta    linux-x86_64-appimage=0.3.1=./build/MyApp-0.3.1.AppImage=https://updates.example.com/MyApp-0.3.1-to-0.4.0.zstpatch \
    --output ./manifest.json
```

Each `--delta` (`<target>=<from-version>=<old-artifact-path>=<patch-url>`)
diffs the old artifact against the target's new artifact (which must be
supplied via a matching `--platform` that references a **local** new-artifact
path), writes a `.zstpatch` next to `--output`, and embeds a delta entry
with its size + base SHA-256. Upload the `.zstpatch` files alongside the full
artifact; older clients and non-delta backends ignore them. This needs the
[`zstd`](https://github.com/facebook/zstd) CLI on `PATH`. Standalone
`swift-pwa updater diff` / `updater patch` expose the engine for scripting.

macOS is identical — the base artifact is the old **`.app.tar.gz`** (the same
signed tarball you published for that version), not the `.app`:

```bash
    --platform darwin-aarch64=./build/MyApp-0.4.0-arm64.app.tar.gz=https://updates.example.com/MyApp-0.4.0-arm64.app.tar.gz \
    --delta    darwin-aarch64=0.3.0=./build/MyApp-0.3.0-arm64.app.tar.gz=https://updates.example.com/MyApp-0.3.0-to-0.4.0.zstpatch \
```

The resulting `deltas` array is additive (Tauri readers ignore it):

```json
"linux-x86_64-appimage": {
  "url": "https://updates.example.com/MyApp-0.4.0.AppImage",
  "signature": "…",
  "deltas": [
    { "from": "0.3.0", "url": "…/MyApp-0.3.0-to-0.4.0.zstpatch", "size": 214512, "base_sha256": "…" }
  ]
}
```

**No packaging burden.** The zstd decompressor is vendored and compiled into
the runtime from source (a single-file decoder amalgamation), so there's no
system library to install, no DLL to ship next to your app, and nothing to
configure — delta support is simply present on the supported backends above.

**JS.** No API change: `updater.run` / `updater.check` behave identically; a
delta is chosen and applied under the hood, and the `downloadProgress` events
just report the (much smaller) patch transfer.

## What's not in the first cut

- **Delta updates on Android / MSIX / iOS** — the three desktop backends
  (Linux AppImage, Windows portable, macOS) ship deltas (see above); Android
  delta is the store's job, MSIX stays full-only (the OS installer owns the
  bytes), and iOS hands the transfer to Apple. Tracked in
  [docs/proposals/delta-updates.md](proposals/delta-updates.md).
- **Prehashed minisign (`ED` mode)** — only legacy `Ed` (pure Ed25519
  over the artifact bytes) is supported. Adding `ED` means vendoring
  BLAKE2b — not in CryptoKit / swift-crypto out of the box.
- **macOS install fires no UI before swap** — apps that want a
  "Restart now / later" dialog should gate `updater.installAndRelaunch`
  behind their own prompt UI (the `readyToInstall` event from
  `updater.run` is the natural prompt point).

## Pre-release verification

Per-platform install machinery (`ditto` on macOS, atomic `rename(2)`
on Linux, `Move-Item` / `Add-AppxPackage` on Windows,
`itms-services://` on iOS) is the part of the updater that no test
process can usefully exercise. Walk the **Updater** module of
[manual-test-cases.md](manual-test-cases.md) before tagging — eight
human-driven cases covering every install path, signature failure
modes, the v0.4 MSIX post-install relaunch, and `minisign(1)`
interop.
