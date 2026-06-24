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

### Core refactor: `AssetProvider` value → shared `AssetRouter`

Replace the per-window `AssetProvider` value with a shared, thread-safe **`AssetRouter`**
class (NSLock, `@unchecked Sendable` — same concurrency idiom as `CommandRegistry`):

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
```
