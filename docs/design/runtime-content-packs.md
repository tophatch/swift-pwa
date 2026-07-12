# Design: runtime import of large content packs

**Status:** approved; implementing · **Target:** v0.6.x · **Author:** design pass from adopter feedback round 3

> **Decisions (round-3 review).** All five open questions are resolved — see
> [Decisions](#decisions-round-3-review) at the end. Headlines: the ZIP engine is an
> **isolated `SwiftPWAArchive` target** (not a new plugin — `fs.extractZip` stays a
> `fs.*` command, registered only when an extractor is injected); the served-mount
> **prefix is fully app-chosen**; we ship **both `app.dataDir()` and `app.cacheDir()`**;
> **GTK range is attempted now** (not punted to a limitation); and **de-risk spikes run
> first** (Phase 0). Pre-1.0, rapidly developing — this lands in the 0.6.x line.

## Motivation

Adopters want end users to import **content packs** at runtime: a user downloads
a pack authored by another user and installs it into the running app. Packs are
**data-only** — a manifest plus media (images, `.webm` video) validated against a
fixed vocabulary. They reskin / reweight the app but cannot add code, so the trust
model does **not** widen: the new surface is untrusted *file input*, not untrusted
logic.

The catch is scale: packs are shipped as **zips that can be gigabytes and contain
video**. The desired flow:

1. `dialog.openFile` → user picks a `.zip`
2. **extract the zip to a writable app-data dir** ← needs new capability
3. validate the manifest with `fs.readText`
4. **reference the extracted media by URL, streamed with range requests** ← needs new capability

Steps 2 and 4 are where today's primitives run out. `fs.readBinary`/`writeBinary`
marshal bytes as base64 across the JS↔Swift bridge (`dataBase64`), so a GB of video
becomes a ~1.33 GB base64 string per file — a non-starter. And the WebView can only
load media over its internal scheme; an arbitrary `file://` path is blocked by CSP,
and `data:` URIs both blow up memory and can't satisfy the HTTP range requests video
seeking needs.

Three new capabilities, ordered by how blocking they are:

| # | Capability | Blocker? | Effort |
|---|------------|----------|--------|
| 1 | `fs.extractZip` (native, path-to-path) | yes | medium |
| 2 | serve a writable dir on the bundle origin, with range requests | yes | large |
| 3 | `app.dataDir()` canonical app-data path | convenience | small |

## Current architecture (what we're extending)

- **`AssetProvider`** ([Sources/SwiftPWACore/Assets/AssetProvider.swift](../../Sources/SwiftPWACore/Assets/AssetProvider.swift)) is a `Sendable` **value type** with a single immutable `root: URL`, a `resolve(_:) -> Resolved?` that maps `pwa://localhost/<path>` to a file under `root` (with a `hasPrefix(rootStd)` traversal guard), and a `mimeType(for:)` table. One instance per window, created from `WindowContent.bundled(directory:)`.
- **Per-backend serving** (full map in the recon notes):
  - **Apple** ([WKSchemeHandler.swift](../../Sources/SwiftPWAWebKit/Shared/WKSchemeHandler.swift)) — `WKURLSchemeHandler`; reads the whole file with `Data(contentsOf:)` and returns **200 only**. Scheme `pwa://localhost`.
  - **GTK3 / GTK4** (`WebKitGTKAdapter.swift` `SchemeBox.handle`) — `webkit_web_context_register_uri_scheme`; wraps the whole file in `g_memory_input_stream_new_from_data`, **200 only**. Scheme `pwa://localhost`.
  - **Windows** ([WebView2Adapter.swift](../../Sources/SwiftPWAWindows/WebView2Adapter.swift)) — `SetVirtualHostNameToFolderMapping` on host `swift-pwa.local`; **native range support**, single host→folder. A `WebResourceRequested` interception path already exists in the shim (`swiftpwa_w2_view_intercept_resources` / `swiftpwa_w2_resource_respond`) but is unused for the bundle.
  - **Android** (`AndroidTemplates.swift` Kotlin) — `WebViewAssetLoader` on `swift-pwa.local`, `addPathHandler("/", AssetsPathHandler)`; **native range support**; supports chaining more `addPathHandler` calls.
- **`WindowContent`** ([WindowConfig.swift](../../Sources/SwiftPWACore/Window/WindowConfig.swift)) is `.bundled(directory:entry:)` | `.remote(URL)`.
- **`FsPlugin` / `Fs` / `SystemFs`** — `Fs` is a protocol; `SystemFs` is the single portable implementation (`FileManager.copyItem` etc.). `fs.copy`/`fs.rename` are path-to-path and never touch JS with bytes — `fs.extractZip` is the same shape.
- **Dependencies** — `Package.swift` has only `swift-argument-parser` and `swift-crypto`, **both used CLI-side only**. There is no runtime third-party dependency and no compression code anywhere.

## Cross-cutting decision: the served-URL origin

The bundle origin already differs by platform (`pwa://localhost` on Apple/GTK,
`https://swift-pwa.local` on Windows/Android). Page JS that references served content
must work unchanged on all of them. **Resolution: served mounts live on the same
origin as the bundle, under a reserved path prefix**, so page code uses an
origin-relative URL:

```js
// Works on every backend regardless of scheme/host:
videoEl.src = `/packs/${packId}/clip.webm`;
```

We reserve a configurable prefix (default `/packs`, but any non-bundle prefix). The
mount maps that prefix to a writable directory. Page JS never needs the absolute
origin; if it does, `__platform.info` will be extended to report served mounts (see
§3).

This keeps existing CSP (`img-src`/`media-src 'self'` or the bundle origin) working
with **no changes** — the whole point of staying same-origin.

---

## Request 3 — `app.dataDir()` (do first; unblocks the rest)

A per-user writable directory, created if absent, returned as a path. It's the `to:`
for extraction and the root for serving.

### API

```text
app.dataDir()   ->  { path: string }     // persistent per-app data (survives, backed up)
app.cacheDir()  ->  { path: string }     // disposable per-app cache (OS may evict)
```

Both ship from the start. `dataDir` is the persistent root (the `to:` for pack
extraction); `cacheDir` is for disposable derived artifacts (thumbnails, transcodes)
the OS is free to reclaim. Swift: `ctx.dataDirectory()` / `ctx.cacheDirectory()` on
`AppContext`.

### Per-platform resolution

| Platform | `dataDir` | `cacheDir` |
|----------|-----------|-----------|
| macOS / iOS | `.applicationSupportDirectory`/`<bundle-id>` | `.cachesDirectory`/`<bundle-id>` |
| Linux | `$XDG_DATA_HOME` ?? `~/.local/share`/`<app-id>` | `$XDG_CACHE_HOME` ?? `~/.cache`/`<app-id>` |
| Windows | `%APPDATA%`/`<app-id>` | `%LOCALAPPDATA%`/`<app-id>\Cache` |
| Android | Activity `filesDir` | Activity `cacheDir` |

- `<bundle-id>` from `Bundle.main.bundleIdentifier`; falls back to the app name
  (`AppPlugin.appName()`) when nil (Linux/unbundled).
- **Android needs a backend hook**: `filesDir` comes from the Java `Context`, not
  Foundation. Introduce a settable `PlatformDirectories.dataDirHook` (mirroring how
  `MainThread` installs a per-backend dispatch hook) that the Android backend
  populates from the Activity at startup; desktop backends leave it nil and fall back
  to the Foundation resolution above. `AppPlugin` reads through that hook.
- The directory is created (`createDirectory(withIntermediateDirectories:)`) on first
  call so callers can immediately write into it.

### Why this is safe and small

No new trust surface (it's the app's own sandbox), one new command, one new hook.
Lands independently of #1/#2.

---

## Request 1 — `fs.extractZip` (ZIPFoundation)

### API

```
fs.extractZip({
  from: string,                  // path to the .zip
  to: string,                    // destination dir (created if absent)
  maxUncompressedBytes?: number, // zip-bomb guard; abort if exceeded
  maxEntries?: number,           // zip-bomb guard
  maxCompressionRatio?: number   // zip-bomb guard (uncompressed/compressed)
}) -> { entries: number, uncompressedBytes: number }

fs.listZip({ from: string })
  -> { entries: [{ name: string, isDir: bool, uncompressedSize: number, compressedSize: number }] }
```

Plus an **optional streaming variant** for GB extracts (follows the `updater.run`
subscription pattern):

```
subscribe('fs.extractZipProgress', { from, to, …guards }, (e) => {
  // e.type: 'progress' { entriesDone, bytesDone, totalEntries } | 'done' { entries, uncompressedBytes } | 'error' { code, message }
})
```

`fs.listZip` lets the app validate the manifest entry (read just `pack.json` from the
central directory) before committing to a multi-GB extract — the "peek" the feedback
asked for.

### Implementation

- Add **ZIPFoundation** to `Package.swift` `dependencies`. Bytes are read from the zip
  and written to disk entry-by-entry by the library — they never cross the bridge.
- New `Fs` protocol methods + `SystemFs` implementation (the single portable impl);
  `FsPlugin` registers the three commands next to `fs.copy`/`fs.rename`.
- **Linkage decision (call out for review):** `SystemFs` lives in `SwiftPWACore`, so a
  naive add makes ZIPFoundation a **runtime dependency of every app** — the first such
  third-party runtime dep. Two options:
  1. Add it to Core directly (simplest; ~small binary cost; ZIPFoundation is lean).
  2. Isolate it: a separate `SwiftPWAArchive` product/target that provides an
     `ArchiveExtractor`, injected like `ctx.use(FsPlugin(SystemFs(extractor: ZipExtractor())))`,
     so apps that don't import packs don't link it. More plumbing; keeps Core dep-free.
  **Recommendation: option 2** — it preserves the "Core has no third-party runtime
  deps" property and matches the existing opt-in-plugin ethos, at the cost of one
  extra injection point. Confirm before building.
- **ZIPFoundation platform reach:** Apple + Linux + Windows are supported. **Android
  (Swift) is the open risk** — verify it builds against the Swift Android SDK (zlib is
  in the NDK) early; if it doesn't, `fs.extractZip` ships everywhere except Android in
  v0.7.0 with a documented gap, and Android follows.

### Security guards (central, so adopters don't re-roll them)

All enforced in `SystemFs.extractZip` before/while writing each entry:

- **Path traversal** — for each entry, compute the destination by joining `to`, then
  `standardizedFileURL`; reject unless it still has `to`'s standardized path as a
  prefix (same guard `AssetProvider.resolve` uses today). Rejects `../`, absolute
  paths, and `..`-laden names. Abort the whole extract on the first offending entry.
- **Symlinks** — ZIPFoundation surfaces symlink entries; **reject** them (a symlink can
  point outside `to`, defeating the traversal check). Configurable later if a real use
  case appears; default deny.
- **Zip bombs** — track a running uncompressed-byte total and entry count; if
  `maxUncompressedBytes` / `maxEntries` is exceeded, or any entry's
  uncompressed/compressed ratio exceeds `maxCompressionRatio`, **abort and delete the
  partial output**. Defaults: generous but finite (e.g. 8 GB / 50k entries / ratio 200)
  — tunable per call, never unbounded silently.
- **Cleanup on failure** — extract into a temp sibling of `to` and `rename` into place
  on success, or delete partial output on any thrown error, so a failed/aborted extract
  never leaves a half-populated dir that the app might serve.

---

## Request 2 — serve a writable directory with range requests (the linchpin)

### API

A **configure-time Swift API** (page JS does not get to mount arbitrary directories —
that stays the app author's decision):

```swift
@MainActor func configure(_ ctx: any AppContext) throws {
    let packs = try ctx.dataDirectory().appendingPathComponent("packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    ctx.serveDirectory(packs, at: "/packs")          // served same-origin at /packs/...
    // … createWindow as usual
}
```

- The app mounts a **container** directory once. Packs extracted into it at runtime
  (`…/packs/<id>/…`) are served immediately — **no per-pack JS→Swift call needed**,
  which is what makes the runtime-import flow work without exposing a "serve any path"
  capability to page JS.
- `serveDirectory(_:at:)` and a matching `unserveDirectory(at:)` mutate a shared mount
  registry; they may be called before or after `createWindow` (handlers read the
  registry live, so runtime additions take effect for the next request).
- Served roots are **read-through** (GET only); writes still go through `fs.*`.
- The **prefix is fully app-chosen** (`/packs`, `/library`, anything not colliding with
  a bundle path); the router enforces only non-collision. There's no reserved name.

**Android needs the mounts at build time** (the `WebViewAssetLoader` is constructed in
Kotlin at Activity-init, before any Swift `configure()` runs). So mounts are *also*
declarable in `pwa.json`, which the Android bundler wires into the template and which
desktop backends read at `configure()` as a convenience:

```json
"build": {
  "serve": [ { "mount": "/packs", "from": "data/packs" } ]   // from: relative to dataDir (or "cache/…")
}
```

`ctx.serveDirectory(_:at:)` remains the imperative escape hatch (desktop, or mounting a
path outside the data/cache roots). On Android only the `pwa.json`-declared mounts are
guaranteed at startup; a later `serveDirectory` call for an undeclared prefix is a
desktop-only capability (documented as such).

### Core refactor: `AssetProvider` value → shared multi-mount class

> **As implemented (Phase A2):** rather than introduce a separately-named `AssetRouter`,
> the existing public `AssetProvider` was evolved from a struct into the `final class`
> below — same name, so none of the six backend call sites (`AssetProvider(root:)` +
> `.resolve(_:)`) needed editing, and the change is a pure, behavior-preserving refactor
> with the bundle as the `/` mount. It gains `mount(_:at:)` / `unmount(at:)` and a
> `fileSize` on `Resolved` (for range). The description below uses "AssetRouter" for the
> concept.

Replace the per-window `AssetProvider` value with a shared, thread-safe class
(NSLock, `@unchecked Sendable` — same concurrency idiom as `CommandRegistry`):

```
final class AssetRouter {                      // held by AppContext; shared into each handler
    private var mounts: [(prefix: String, root: URL, writable: Bool)]   // "/" = bundle, read-only
    func mount(_ root: URL, at prefix: String, writable: Bool)
    func unmount(at prefix: String)
    func resolve(_ url: URL) -> Resolved?       // longest-prefix match, per-root traversal guard
}
```

- The bundle is just the `/` mount, installed from `WindowContent.bundled`. `serveDirectory`
  adds more mounts. Longest-prefix wins, so `/packs/...` resolves to the packs root and
  everything else falls through to the bundle.
- Per-mount traversal guard (unchanged logic, applied against each mount's root).
- `Resolved` gains the file size so handlers can answer range requests without a second
  `stat`.

### Range-request support per backend

Range (`Range: bytes=…` → `206 Partial Content` + `Content-Range` + `Accept-Ranges:
bytes`) is what makes large `.webm` seek instead of fully buffer. It also improves
*bundle* streaming as a side benefit.

| Backend | Today | Plan |
|---------|-------|------|
| **Apple** | 200, full read | Parse `Range` from `urlSchemeTask.request`; open with `FileHandle`, seek, emit `206` + `Content-Range`, stream in chunks via repeated `didReceive(_:)`. Honors `stop` for cancellation. **Feasible.** |
| **GTK3/GTK4** | 200, memory stream | Hand WebKit a **seekable `GFileInputStream`** (`g_file_read`) instead of a memory stream, and emit a 206 response with `Content-Range` when a range is requested. **Risk:** range behavior over `webkit_uri_scheme_request_finish` is WebKitGTK-version-sensitive — **prototype large-video seek on GTK3 (4.1) and GTK4 (6.0) early**; this is the single most uncertain piece of the whole feature. |
| **Windows** | native range, single host→folder | `SetVirtualHostNameToFolderMapping` maps a whole host, not a subpath, so a same-origin `/packs` can't be a second mapping. Use the existing **`WebResourceRequested` interception** for `https://swift-pwa.local/packs/*`, served from the router with range implemented in the C++ shim respond path (`swiftpwa_w2_resource_respond`). Bundle keeps its native host mapping. **Medium Windows work.** |
| **Android** | native range | `InternalStoragePathHandler` rooted at `filesDir`, registered via `addPathHandler(<prefix>, …)` in the generated Kotlin — gives range for free. The asset loader is built at Activity-init, so the **app-chosen prefix(es) are declared in `pwa.json`** (`build.serve` — see below) and the bundler wires them into the template. (Desktop reads the same `serve` config at `configure()` time, or the app calls `ctx.serveDirectory` directly.) **Template change.** |

### Why not a `WindowContent` option instead

A `WindowContent` "extra roots" field would fix the mounts at window creation —
but packs are imported *after* the window exists, so we need a mutable, context-level
registry. `serveDirectory` on `AppContext` is the right level; `WindowContent` stays
unchanged.

---

## Rollout plan

Phased, on a feature branch → PR (this is large; pre-1.0 with few users, so the 0.6.x
line is fine — no need to hold for a 0.7.0). **De-risk spikes run first:**

- **Phase 0 — de-risk (do before the dependent phases).**
  1. **ZIPFoundation on Android** — add the dep + the isolated `SwiftPWAArchive` target,
     and push so CI's Android cross-compile job confirms it *links* against the Swift
     Android SDK (resolves open question #3). Builds locally on macOS as the first
     signal.
  2. **GTK range** — prototype a seekable `GFileInputStream` 206 response in the GTK3
     (WebKitGTK 4.1) and GTK4 (6.0) scheme handlers; confirm it compiles in CI and seek
     a large `.webm` under `SWIFT_PWA_LINUX_GUI=1` on a real display. If range genuinely
     can't be made to work on a WebKitGTK version, *then* fall back to documenting Linux
     video as a limitation — but we attempt it now.
- **Phase A — `app.dataDir()` / `app.cacheDir()` + `AssetRouter` refactor.** Add the dir command/hook;
  refactor `AssetProvider` (value) into the shared `AssetRouter` with the bundle as the
  `/` mount — **no behavior change yet**, pure structural prep. Land range support on
  Apple + GTK here too (improves bundle streaming, de-risks the GTK unknown before it's
  load-bearing).
- **Phase B — `serveDirectory` + multi-mount wiring.** `AppContext.serveDirectory`,
  Windows `WebResourceRequested` path, Android `addPathHandler` template, end-to-end
  served-media test.
- **Phase C — `fs.extractZip` + `fs.listZip` + progress.** ZIPFoundation (per the
  linkage decision), the security guards, the streaming variant.

Each phase is independently testable; the feature is usable only after C, but A and B
carry their own value (dir API, faster bundle streaming).

## Test plan

- **Unit (`SwiftPWACoreTests`/`SwiftPWACLITests`):** traversal rejection (`../`,
  absolute, symlink entries), each zip-bomb guard trips + cleans up, `listZip` against a
  fixture zip, extract correctness (small fixture), `AssetRouter` longest-prefix routing
  + per-mount traversal guard, `app.dataDir` returns a creatable path, Range-header
  parsing → correct `206`/`Content-Range`/byte slice.
- **Integration (macOS, WKWebView):** load a served `.webm`, assert a ranged request
  yields `206` and seeks; verify a pack extracted at runtime under a mounted container
  is fetchable.
- **GTK prototype (gated):** the early range spike becomes a kept test under
  `SWIFT_PWA_LINUX_GUI=1`.

## Decisions (round-3 review)

1. **ZIPFoundation linkage → isolated.** A separate `SwiftPWAArchive` target owns the
   dependency. `fs.extractZip`/`fs.listZip` stay `fs.*` commands on the existing
   (opt-in) `FsPlugin`; Core defines an `ArchiveExtractor` protocol and stays
   dependency-free. The command is registered only when an extractor is injected
   (`FsPlugin(SystemFs(extractor: ZIPExtractor()))` or a `.withZip()` convenience), so
   apps that don't import packs link neither ZIPFoundation nor the command. **Not a new
   plugin.** *(Implemented in Phase 0a.)*

   **Windows finding + decision (from the Phase 0a CI de-risk):** ZIPFoundation does
   **not** build on Windows — its `CZLib` shim uses `#import <zlib.h>`, which clang-cl
   rejects (the MSVC `#import`-typelib feature), and Windows ships no system zlib. So
   ZIPFoundation is gated off Windows (the `ZIPExtractor` is a throwing
   `unsupportedPlatform` stub there today). **Decision: keep full parity** — Phase C
   ships a `WindowsZIPExtractor` that shells to bundled `bsdtar` (`tar.exe`, present on
   Windows 10 1803+). The same `ArchiveExtractor` contract applies; the traversal /
   symlink / zip-bomb guards are enforced by a pre-extract listing pass (`tar -tvf`)
   since `tar` won't enforce our limits. macOS / iOS / Linux / Android keep
   ZIPFoundation. (Android confirmed indirectly: Linux — same clang + sysroot-zlib
   shape — builds it; a direct check lands with the Phase C HelloPWA wiring.)
2. **Mount prefix → fully app-chosen.** No reserved name; the router enforces only
   non-collision with bundle paths. Android's build-time constraint is handled by the
   `pwa.json` `build.serve` declaration (above), not by reserving a fixed prefix.
3. **Android extraction → verify early.** Phase 0 confirms ZIPFoundation links against
   the Swift Android SDK in CI before anything depends on it; if it can't, #1 ships on
   the other four backends first.
4. **GTK range → attempt now.** Prototyped in Phase 0; only fall back to a documented
   Linux-video limitation if a WebKitGTK version makes range genuinely unworkable.
5. **`app.dataDir` + `app.cacheDir` → both, from the start.**
6. **Release line → 0.6.x.** Pre-1.0, rapidly developing, few adopters; no need to hold
   these new APIs for a 0.7.0.

## Resume notes (implementation status + how to work)

All work is on branch **`feat/content-packs`** (PR #3), committed + pushed.

**Status:**
- ✅ **Phase 0a** — `SwiftPWAArchive`/`ZIPExtractor` (Windows = throwing stub). CI green.
- ✅ **Phase A1** — `app.dataDir`/`app.cacheDir` + `PlatformDirectories` (+ `ctx.dataDirectory()`/`cacheDirectory()`). Android `filesDir`/`cacheDir` use a fallback derived from the temp dir; a real `PlatformDirectories.Hook` should be installed by the Android backend (still TODO).
- ✅ **Phase A2** — `AssetProvider` is now a multi-mount class (`mount`/`unmount`, `fileSize` on `Resolved`).
- ✅ **Phase A3** — range/206 done on Apple (`WKSchemeHandler`, synchronous chunked, `@unchecked Sendable` — *not* `@MainActor`; CI Xcode SDK marks `WKURLSchemeHandler` `@MainActor` so off-main delivery is illegal) and GTK (both shims' `swiftpwa_uri_request_*` helpers + `SchemeBox`). **GTK verified headless on real WebKitGTK 6.0.** Shared `ByteRange` parser in Core.
- ✅ **Phase B** — `ctx.serveDirectory(_:at:)`/`unserveDirectory(at:)` on the `AppContext` protocol (default extension forwarding to the shared router). The per-window `AssetProvider` is **hoisted to context level** (`AppContext.assetProvider`, a bundle-less `AssetProvider()`; the first `.bundled` window installs the `/` mount via `setBundleRoot`), so a runtime mount is visible to every window's handler. Apple + GTK work through the existing `resolve()` + range path (A3) — **GTK4 re-verified building on the box** after the adapter init-signature change. Windows: `WebResourceRequested` interception filtered on the bundle origin; bundle paths fall through to the native virtual-host mapping (`swiftpwa_w2_resource_passthrough`), served mounts answered range-aware off disk (`swiftpwa_w2_resource_respond_file` via `SHCreateStreamOnFileEx`; to-EOF ranges stream lazily, bounded ranges read a capped buffer — same hybrid as GTK) — **compile-only here, CI-verified**. Android: `pwa.json` `build.serve` (`PWAManifest.ServeMount`) → bundler emits `addPathHandler(<prefix>/, InternalStoragePathHandler(filesDir|cacheDir/<sub>))` in the generated Kotlin — **compile-only / generated-source-tested**. New Core helper `AssetProvider.isServedPrefix` (Windows triage) + unit tests; `ServeDirectoryTests` cover the AppContext extension.
  - **Deferred to Phase C:** the Android `PlatformDirectories.Hook` (real `filesDir`/`cacheDir` via a new JNI accessor) so `app.dataDir()` returns the exact path the Kotlin serves from. The current fallback (`NSTemporaryDirectory()`'s sibling `files`) resolves to `/data/data/<pkg>/files` for the standard single-process layout, so the extract-then-serve flow already lines up; the proper hook lands with the HelloPWA wiring where a real device/emulator can verify it.
- ✅ **Phase C** — `fs.extractZip`/`fs.listZip` + streaming `fs.extractZipProgress` wired through `Fs`/`SystemFs`/`FsPlugin` (registered only when an extractor is injected). `ArchiveExtractor` is **async** (one impl is inherently async — see Android). Per-platform extractor:
  - **macOS / iOS / Linux** — `ZIPExtractor` (ZIPFoundation), all guards, staging-then-commit. Unit + registry tests on macOS.
  - **Windows** — `ZIPExtractor` shells to `tar.exe` (bsdtar); guards enforced via a `tar -tvf` listing pre-pass (`BSDTarListParser`, tested against real `tar`). Compile-only here, CI-verified.
  - **Android** — ZIPFoundation **does not build against Bionic libc** (confirmed on the real toolchain: pervasive `lstat`/`errno`/`S_IF*`/`mode_t` breakage — the Phase 0 risk #3, never actually exercised before because nothing cross-compiled `SwiftPWAArchive` for Android). So ZIPFoundation is gated off Android and `AndroidArchiveExtractor` (SwiftPWAAndroid) routes to Kotlin `java.util.zip` over the existing RPC bridge; guards (canonical-path traversal + zip-bomb) enforced Kotlin-side.
  - **HelloPWA** exhibits the flow (extract embedded sample zip → serve via `/packs`); `pwa.json` `build.serve` declares the Android mount.
  - **Verified end-to-end on a real Android device** (tablet over adb): app launches (runtime `.so` loads), `fs.extractZip` via java.util.zip returns `{entries:2}`, `fetch('/packs/sample/hello.png')` → `200 image/png`.

**Phase C device findings (fixed):**
- The Android bundler resolved the Swift runtime-`.so` bundle at the **macOS** swift-sdks path on a Linux host → skipped runtime bundling → APK crashed at `System.loadLibrary` on-device (CI's assemble-only check never caught it; every Linux-host APK incl. CI release artifacts was affected). Fixed by probing the real candidate roots (`~/.swiftpm/swift-sdks`, XDG, macOS `~/Library`).
- `WebViewAssetLoader` matches path handlers in registration order; the catch-all `addPathHandler("/")` was registered before `/packs/`, shadowing served mounts (broken image). Fixed by registering `build.serve` mounts first.

**Still open / follow-ups:**
- Android `PlatformDirectories.Hook` (real `filesDir`/`cacheDir` via JNI) — turned out **not needed** for the demo: the temp-dir fallback resolved to `/data/.../files`, so `app.dataDir()` aligned with the Kotlin-served `filesDir/packs`. A proper hook is still nice-to-have for robustness.
- Android `fs.extractZipProgress` emits a single terminal tick (unary RPC has no per-entry channel) — a streaming JNI channel could give true per-entry progress.
- **Recurring CI flake (not content-packs):** `swift-test` intermittently hangs ~12 min *after all tests pass* on one of the two Linux GTK jobs (gtk3/gtk4 alternately) — a known Linux swift-testing teardown issue, likely the DevServer inotify watcher not torn down. Passes on retry. Worth a separate hardening pass.

## Round 4 — `fs.createZip` (symmetric counterpart to `fs.extractZip`)

**Status:** implemented (branch `feat/fs-create-zip`). A small, non-blocking follow-on from adopter feedback round 4 — in-app pack **authoring / re-export**.

The everyday authoring case (a small pack) is built **in the browser** as an in-memory `Blob` download — no platform support, runs in a plain tab. `fs.createZip` is the giant-file escape hatch: a multi-GB folder of video that can't become an in-memory blob, and re-exporting an *already-installed* pack (its source is a `<dataDir>` folder the browser can't re-`fetch()`). Same constraint as extract, mirrored: bytes stay off the bridge (path-to-path).

- **API:** `fs.createZip({ from, to, compression? }) → { entries, uncompressedBytes }` + streaming `fs.createZipProgress` mirroring `fs.extractZipProgress`. `compression`: `"stored"` (default) | `"deflate"` — pack media is already compressed, so stored is faster for the same size.
- **Reuses the opt-in archiver.** `create` is a new method on the existing `ArchiveExtractor` protocol (default impl throws, so non-archive `Fs` conformers still compile), wired through `Fs`/`SystemFs`/`FsPlugin` and gated on the same injected extractor — no new dependency, nothing extra linked for apps that don't import packs.
- **Per-platform** (same backends as extract): ZIPFoundation `Archive(accessMode: .create)` + `addEntry` (streams disk→archive) on macOS/iOS/Linux; `tar --format zip --options zip:compression=store|deflate` on Windows; Kotlin `ZipOutputStream` over JNI on Android (where `"stored"` → deflate-level-0 single pass, since `java.util.zip`'s true STORED needs a CRC pre-pass — a second read of every file).
- **Guards:** symlinks in the source are skipped (not followed, not stored); staging-then-move so a failed create leaves no partial `.zip`. No zip-bomb/traversal guards needed — we're reading the app's own files, not untrusted input.
- **Tests:** create→extract round-trip (both compression modes), progress monotonicity, symlink skip, no-partial-on-failure, and the FsPlugin command path incl. a full create→extract bridge round-trip. Verified on macOS + the Linux GTK4 box; Windows is compile-only (CI builds but can't run tests there).

**Key gotchas learned this session:**
- `WKURLSchemeHandler` is `@MainActor` in CI's Xcode SDK (not in my local SDK) → keep handler work on the main actor; deliver synchronously in chunks (reads only the requested bytes, so no full-file buffering).
- WebKitGTK reads the response stream to **EOF** (`stream_length` is only a hint) → `finish_file` hybrid: ranges-to-EOF use the lazy seekable `GFileInputStream` (GB-safe, cancellable); **bounded** sub-ranges must read exactly their bytes (capped memory buffer) or the 206 body won't match `Content-Range`.
- glib `gint64` imports as Swift `Int` on Linux x86_64 → wrap call args in `gint64(...)`.

**Linux GTK build/verify box** (see also the saved project memory): a headless SSH host (passwordless ssh; no sudo; no appindicator → **build the GTK4 backend**). Repo clone at `~/swift-pwa`.
```bash
# Local → box sync (no git noise):
rsync -az --exclude=.build --exclude=.git ~/Code/swift-pwa/ linux-gtk-box:~/swift-pwa/
# On box (GTK4 path; appindicator absent):
export PATH="$HOME/.local/share/swiftly/bin:$PATH"; export SWIFT_PWA_GTK4=1
cd ~/swift-pwa && swift build
# A C-shim (systemLibrary) header change is NOT picked up incrementally → rm -rf .build.
# Headless WebView run:
export WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
timeout 40 xvfb-run -a .build/x86_64-unknown-linux-gnu/debug/<exe> ./web
```
Local `swift build`/`swift package` needs the git safe-directory workaround for dep resolution:
`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build`.
