# Changelog

All notable changes to swift-pwa will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **`drive scroll` could return success and deliver nothing on macOS** (#264).
  `NSEvent(cgEvent:)` takes a scroll event's window from the window server —
  what is on top at that screen point — rather than from the window it is sent
  to. When that isn't ours the event comes out with no window and a screen
  position where its window position should be, and is hit-tested into
  nothing. It was always the case for a `--background` run's off-screen window,
  and instrumenting it showed the same on a foreground run on a working desktop.
  The adapter now builds the event the way AppKit addresses its own mouse
  events, for this window and point; measured delivering to a foreground window
  and to one whose app had been deactivated. The documented "window under
  pointer" CGEvent fields turn out to have no effect; AppKit reads an
  undocumented one, which a retyped mouse event carries.

  **A backgrounded macOS run still can't take a wheel, and now says so.** WebKit
  drops a wheel event for a window parked off every display even when it is
  handed straight to the webview — while the same event lands in an inactive
  window on screen. So `drive info` reports `input.wheel: false` there and the
  verb fails naming `--background`, rather than letting a scroll test pass
  having scrolled nothing. GTK3 and Windows deliver the wheel backgrounded
  (measured). `Scripts/verify-driven-input.sh` and its `.ps1` gain a wheel check
  and a `--background` / `-Background` mode; the `.ps1` also gets the WebView2 /
  WIL flags Swift 6.4 needs and follows a checkout not named `swift-pwa`, and
  the `.sh` asks SwiftPM for the binary's path instead of searching a layout
  6.4 moved.

- **`image.transcode` on Windows swapped red and blue — in PNG as well as
  JPEG** (#266). `IWICBitmapFrameEncode::SetPixelFormat` is in/out: asked for
  `24bppRGB`, WIC's PNG and JPEG encoders both write back `24bppBGR` and return
  `S_OK`, and the shim wrote its RGB buffer into the frame regardless. The
  encode now converts to whatever format the encoder negotiated. It went
  unnoticed because every WIC check measured size, byte count or that a decode
  succeeded — never a colour — and the swift-testing round trip that would
  have caught it can't run on Windows. `SwiftPWAWindowsTestRunner` now encodes a
  known colour through both formats and reads it back, after first checking the
  decode of a hand-built PNG, so a matching swap on the way in can't hide one on
  the way out. Measured failing (`(220, 60, 30)` came back `[30, 60, 220]`)
  and then passing on x64; passing on arm64, where the report measured the
  same swap byte for byte.

- **Comments that said Windows decodes images with stb_image** (#265). It has
  used WIC since `image.*` shipped; the `PlatformImageTranscoder` doc comment
  told a reader deciding whether to rely on HEIC that they couldn't, which the
  code and `docs/javascript-api.md` both contradict.

- **A bundled Windows or Linux app named its Documents folder after its
  executable, not `pwa.json`'s `name`** (#263). Neither platform gives a
  shipped binary an `Info.plist`, so `app.name` fell back to the process name —
  the SwiftPM target, which can't hold a space — and an app called "Example
  Reader" put its user's library in `Documents\ExampleReader` on Windows and
  Linux, and in `Documents/Example Reader` on macOS. #254 fixed the same split
  for `dev` and `drive`; this is the shipped half. The bundler now writes the
  name where each platform keeps one, and the runtime reads it back:

  - **Windows**: a `VS_VERSIONINFO` resource in the `.exe` — `ProductName` and
    `FileDescription` from `name`, the version from `version`. A resource rather
    than the `pwa.json` staged beside the exe, because a single-file build has
    no `pwa.json` beside it. It is also what Explorer's Details tab and Task
    Manager show, which until now was nothing.
  - **Linux**: `Name=` from the `.desktop` entry at
    `<prefix>/share/applications/<exe>.desktop` beside `<prefix>/bin/<exe>`.
    The AppImage bundler already wrote it there, and a distro package would.

  **The data directory and the webview's storage deliberately do not move.**
  Both were scoped by executable name on these platforms in every earlier
  release, and following the new name would strand each existing user's
  `localStorage` and IndexedDB to rename a folder they never see. So the
  embedded name feeds `app.name` and `app.documentsDir` only — which is why it
  isn't `AppPlugin.setDisplayName`, the seam Android uses, since that one feeds
  `appID()` too. An app that already shipped 0.11.2 on Windows or Linux created
  `Documents\<Target>`; it will now use `Documents\<Name>`, and any files
  there need moving by the app.

  Verified against a fresh scaffold whose target is `SwiftPWAIdentityProbe` and
  whose `pwa.json` says "SwiftPWA Identity Probe". On Windows x64 and arm64,
  `Scripts/verify-app-identity.ps1` (new) checks the bare binary, the folder
  bundle and the single-file build, reading `ProductName` back through
  PowerShell's own `VersionInfo` as well as the runtime (the arm64 box's
  Documents is redirected into OneDrive, which `documentsDir` follows). On Linux
  GTK3 and GTK4, `Scripts/verify-app-identity.sh` gains an AppImage leg. Run
  against unmodified `main`, both harnesses fail exactly the bundled legs
  (Windows x64, Linux GTK3), so they measure the fix rather than pass
  regardless.

- **`ai.local_onnx_runtime` couldn't link on an arm64 Windows host** (#262). The
  resolver pinned one pair of files, Microsoft's x64 build, and an arm64 host
  downloaded them into the same cache and failed at the linker with `machine
  type x64 conflicts with arm64` — an error that names no fix. It now picks the
  pair for the host's architecture: x64 keeps its existing assets, and the
  win-arm64 build of the same 1.29.0 release is re-hosted beside them as
  `onnxruntime-1.29.0-arm64.{lib,dll}`, so older tags' checksum pins are
  untouched. The headers are byte-identical between the two, so the committed
  set doesn't change. `ai.onnx_gpu` (DirectML) has no arm64 pair pinned, so an
  arm64 host now fails that build up front with a message naming the override,
  instead of at the link. New `Scripts/verify-windows-onnxruntime.ps1` scaffolds
  an app that links `SwiftPWAONNX`, bundles it and checks the staged DLL's
  machine type (dumpbin's reading) and that `OrtRuntime.shared` loads: arm64
  passes both through the download and through the local-vendor path, and x64
  is unchanged.

### Added

- **`Scripts/remote-windows.sh`** — the Windows twin of `remote-linux.sh`:
  copies the tree to a box over SSH, loads the MSVC environment and builds or
  runs the Windows test runner with the NuGet headers passed as flags. Every
  step of that had been rediscovered by hand, trap by trap, on each Windows
  change. See `docs/windows-setup.md`.

## [0.11.2] - 2026-09-21

### Added

- **`window.snapshot` — a page can ask for a picture of itself** (#255). Every
  backend could already render its webview's pixels; it had exactly one caller,
  the app driver's `screenshot` verb, and the page couldn't reach it. An app
  animating its own content — a page curl in a reader, a shared-element
  transition — needs a picture of what it is showing, and the web has no API
  that rasterises a DOM subtree. The libraries that fill that gap re-implement
  the renderer in JavaScript: slow, and blind to shadow-root CSS and
  `@font-face`.

  ```js
  const { value: can } = await __SWIFT_PWA__.invoke('window.canSnapshot');
  const { pngBase64, width, height } = await __SWIFT_PWA__.invoke('window.snapshot');
  ```

  `width` / `height` are **device** pixels, so a page can size a canvas without
  guessing at `devicePixelRatio`. `window.canSnapshot` answers without
  rendering anything, so an app decides once at startup rather than catching
  `E_UNIMPLEMENTED` per call. It is the webview's pixels rather than the
  screen's, so it works while the window is occluded or in the background and
  needs no screen-recording permission on any platform.

  **Android had no snapshot at all** and now does, through `PixelCopy` against
  the window's composited surface — implemented in the Kotlin bridge, which is
  what owns the `WebView`. `View.draw` into a software `Canvas` was the obvious
  spelling and it **silently misses every GPU layer**: on a Fold7 a full-screen
  `<canvas>` of random noise came back as one flat colour while the DOM around
  it was captured perfectly, which looks exactly like a working snapshot of a
  blank page. `View.draw` is kept only as the fallback for a window that isn't
  on screen, so a page using `<canvas>`, WebGL or video gets its real pixels.

  No `rect` or JPEG option yet, and the measurement says where they will first
  be needed. A full-window PNG of a page of **body text is ~60 ms and a few
  hundred KiB** on macOS, iOS and both Linux backends — usable for a transition
  as it stands. **Windows (239 ms) and Android (406 ms) are four to seven times
  slower**, nine tenths of it inside the call: a three-to-four-megapixel
  surface, PNG-encoded and — on Android — base64'd across the JNI boundary. A
  page curl can't start under the finger on those two, so `rect` / JPEG have a
  measured case there and none yet on Apple or Linux. The per-platform table is
  in the README's footnote 35.

  **Windows returns colour-managed pixels.** `CapturePreview` hands back the
  display's colour space with that display's ICC profile embedded, so on a
  wide-gamut monitor a page's `#0000ff` reads back as `#2200ff` — the same
  colour, different numbers. It renders correctly; a page that samples the
  bytes expecting its own sRGB values back will not get them. Found because the
  verification script originally asserted exact colours, which was the script
  being wrong rather than the backend.

  `Scripts/verify-window-snapshot.sh` (desktop, with a `.ps1` sibling for
  Windows) and `Scripts/verify-android-window-snapshot.sh` produce it, and
  check correctness by reading pixels back out of the returned image — a blank
  capture decodes, measures and reports a plausible size exactly like a real
  one.

  Two instrument faults found on the way, both of which had made the probe lie
  rather than the product: a hand-rolled LCG's low bits are periodic, so the
  "noise" page compressed thirtyfold better on one engine and read as a backend
  difference that wasn't there; and on iOS a page without `viewport-fit=cover`
  has a layout viewport inset by the status bar and home indicator while the
  webview covers the whole screen — so the snapshot is legitimately taller than
  `innerHeight * devicePixelRatio`, which any app placing one needs to know.
  Both are documented where an adopter will meet them.

- **`ctx.permissions` can ask, not just declare — and All-files access is a
  permission it knows by name** (#243). `android.permissions` (0.11.0, #214) got
  `MANAGE_EXTERNAL_STORAGE` into the manifest; declaring it grants nothing, and
  an app had no way to perform the `ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`
  hand-off that does. `AndroidURLOpener` is `ACTION_VIEW` on a URL — the wrong
  action, and it won't take an `intent://` either — and `AndroidAppContext`
  exposes no `JNIEnv`, correctly. So the only route was an app-side JNI shim
  beside the generated Kotlin, which `swift-pwa build` regenerates around.

  ```swift
  ctx.permissions.declare(.allFiles)
  if await ctx.permissions.status(.allFiles) == .denied {
      _ = await ctx.permissions.request(.allFiles)   // resolves when the user is done
  }
  ```
  ```json
  "permissions": { "device": ["allFiles"] }
  ```

  Declaring the name emits the platform entries — `MANAGE_EXTERNAL_STORAGE`, plus
  the legacy storage pair capped at API 29 for an app that still supports below
  30 — so the request and the manifest can't drift apart. `permissions.status` /
  `permissions.request` are the JS spellings.

  **Three states, because "no" splits in two.** `granted` is usable now;
  `denied` is worth a button, because asking is possible; `unavailable` never
  becomes granted on this build, so the app needs a different design rather than
  a button. `unavailable` is what an undeclared or vetoed permission reports,
  what iOS reports for `allFiles` (a document picker or a scoped bookmark is the
  design there, and no prompt will ever change that) — and what an app reports
  when a store refused the declaration. Play restricts All-files access to apps
  whose core function needs it, so that is a case to design the fallback around
  rather than an error path; [docs/android-setup.md](docs/android-setup.md#all-files-access)
  names it.

  Linux, Windows and macOS answer `granted`: nothing stands between the app and
  a path it can already open, and macOS raises its own prompt on the first read
  of a protected folder. The seam is `DevicePermissionAuthority`, installed by a
  backend's `AppContext`; a backend with nothing to ask abstains and the policy's
  own two ceilings answer. This is deliberately *not* how the web APIs get their
  consent — `getUserMedia` and friends still reach the platform's own prompt
  through their own seam.

- **`__platform.info` reports a `deviceName`** (#243). `ProcessInfo.hostName` is
  `localhost` on every Android device, and that string is what an app writes
  into a "which device is this" field — where it surfaces on another device as
  "continue reading from localhost". `deviceName` is the model on Android (read
  from Bionic's property store rather than a JNI hop to `Build.MODEL`), the
  device's own name on iOS, and the hostname (minus a `.local` suffix) on the
  three desktops. Never empty.

- **`serveDirectory` takes a SAF tree, so a picked folder can be streamed from**
  (#249). #246 made a tree listable; this makes it *servable*, which is the
  half a reader needs. A library folder is served, not read into memory —
  `/library/<rel_path>` is what pdf.js and epub.js stream from, and a 400 MB
  PDF is not a `readBinary`. Until now `AssetProvider.mount` took a filesystem
  URL and a tree could only be enumerated, so an app could find every document
  in a picked folder and had nowhere to point.

  ```swift
  ctx.serveDirectory(pickedTreeURL, at: "/library")   // the same call a path takes
  ```

  One API, not two: a path on desktop, a tree where that is what the user
  picked. A `content://` URI names nothing on the other four platforms, so the
  resolution is Android's — `AssetProvider` reports the mount as a tree plus
  the path within it and the generated Kotlin does the `DocumentsContract`
  walk, one segment at a time, because a provider's document ids are its own
  business rather than something to concatenate. **Every intermediate
  directory is cached**: a reader asks for neighbours in one folder over and
  over, and on a network-backed provider each uncached level is a round trip.

  No `Content-Length` of our own, matching the other mounts: Chromium bounds a
  range with `available()` rather than that header, so setting one would only
  risk contradicting the length it computes — and a network-backed provider
  often has no size to give (#248). Ranges work through the same cap the #244
  fix put in.

- **`fs.readDir` walks a SAF tree on Android, so a folder the user picked can
  back a library** (#246). Everything around it already worked —
  `dialog.openDirectory` opens `ACTION_OPEN_DOCUMENT_TREE`, the runtime takes a
  **persistable** grant so the folder survives a relaunch, and
  `fs.readBinary` / `writeBinary` / `metadata` have read a single document by
  URI since 0.5. What nothing did was enumerate the tree, so an app held a
  durable grant to a folder and could never learn the URIs of anything inside
  it — the read path that worked was unreachable. A picker that returns
  something you can't walk returns nothing.

  ```js
  const { path: tree } = await __SWIFT_PWA__.invoke('dialog.openDirectory', {});
  const entries = await __SWIFT_PWA__.invoke('fs.readDir', { path: tree });
  const book = await __SWIFT_PWA__.invoke('fs.readBinary', { path: entries[0].path });
  ```

  Same `FsEntry` shape a filesystem path returns, each entry's `path` being its
  own document URI, and recursion is the caller's business exactly as it is for
  a path. The two things `DocumentsContract` insists on are both in the
  implementation: children come from the *tree* document id for a freshly
  picked tree and the *document* id once descending, and each row's
  `COLUMN_DOCUMENT_ID` goes back through `buildDocumentUriUsingTree` before it
  can be opened or descended into — the raw id is not a URI, and a child's URI
  without the tree carries no grant.

  **It is the route when All-files access isn't available**, which is three
  cases at once: an app the Play Store won't grant `MANAGE_EXTERNAL_STORAGE`,
  an SD card or USB-OTG volume, and — the one worth knowing — **Drive, OneDrive
  and Dropbox, which are `DocumentsProvider`s on Android rather than synced
  folders**. A cloud folder picked through SAF is the same code path as an SD
  card picked through SAF, so tree listing is also the cheapest possible
  cloud-storage story: no OAuth, no API client, no per-provider adapter.

  `fs.metadata` on a content URI now reports `isDir` from the document's MIME
  type. It claimed every content URI was a file, which was only ever harmless
  because nothing could produce a directory one.

- **`app.documentsDir` — the folder an app owns that the *user* can see**
  (#250). `dataDir` and `cacheDir` are the app's private containers and go when
  the app does; there was no name for the third location every app actually
  needs, so every app hardcoded one per platform.

  ```js
  const { path, survivesUninstall } = await __SWIFT_PWA__.invoke('app.documentsDir');
  ```

  `~/Documents/<App>` on macOS, `$XDG_DOCUMENTS_DIR/<App>` on Linux (read from
  `user-dirs.dirs`, which is where the value actually lives), `Documents\<App>`
  on Windows via the known folder rather than `%USERPROFILE%` (which OneDrive
  redirects), `/sdcard/Documents/<App>` on Android, and the app's own
  `Documents` container on iOS. Created on first call. `ctx.documentsDirectory()`
  in Swift.

  It carries `survivesUninstall` because that is the one fact an app has to
  branch on, and it is **false on iOS** — the visible Documents folder is inside
  the app container. An app that knows can offer an export rather than imply a
  permanence the platform won't provide. iCloud is the iOS answer and needs an
  entitlement a free team can't have, so it is
  [documented](docs/ios-setup.md#icloud-is-the-upgrade-and-it-needs-a-paid-team)
  rather than implemented.

  **On Android this needs no permission**, which reframes what a default
  install can do: since Android 11 an app may create, list and read its *own*
  files in shared storage by path. All-files access is only what lets it see
  what everything else put there — an upgrade, not the price of entry. Measured
  on a Fold7 with the permission denied: the app wrote into
  `/sdcard/Documents/<App>` and listed it back, the file survived
  `adb uninstall` while `Android/data/<id>/files` did not, and the folder
  served a `Range` request because it is an ordinary path.
  `docs/android-setup.md` led with All-files access before this and sent an
  implementer to the wrong design.

### Changed

- **`fs.metadata`'s `size` is optional, and absent means "unknown"** (#246).
  It reported `0` for a file whose size the source didn't know, which is not
  the same statement: "0 bytes" is a claim a caller acts on — it skips the
  read, renders an empty row, or refuses to copy. The case is real rather than
  theoretical, and arrived with SAF tree listing: an Android
  `DocumentsProvider` backed by a network (Drive, OneDrive, Dropbox) is
  entitled to omit `COLUMN_SIZE`, and does.

  ```js
  const m = await __SWIFT_PWA__.invoke('fs.metadata', { path });
  if (m.size == null) { /* unknown — not empty */ }
  ```

  **A breaking change to a shipped shape**, deliberately: `size` is now absent
  from the JSON rather than `0`, and `FsMetadata.size` is `Int64?` in Swift.
  Page code that reads `m.size` for a filesystem path is unaffected — a `stat`
  always knows, so nil never appears there — but code that branches on
  `!m.size` should become `m.size == null`, which is what already had to be
  written for `modified`. Zero remains expressible and now means an empty
  file.

### Fixed

- **A development run and the shipped app agree on the app's name, and so on
  the user's folder** (#254). `app.name` falls back to the executable when
  there's no bundle to read, and the executable is the SwiftPM *target* name —
  which can't contain a space. So an app whose `pwa.json` said `"Aether Reader"`
  answered `AetherReader` from `swift-pwa drive` and `Aether Reader` from the
  built `.app`. That was liveable while only `dataDir` and `cacheDir` hung off
  it — a driven run keeping its own private state is closer to a feature — but
  `app.documentsDir` (#250) is the *user's* folder, and an adopter using it as
  their library root got an empty `~/Documents/AetherReader` created beside the
  real `~/Documents/Aether Reader`, adopted, and shown as an empty library. A
  silent failure that looks like data loss.

  `swift-pwa dev`, `drive` and the headless catalog dump now pass the manifest's
  name to the binary they launch (`SWIFT_PWA_APP_NAME`, read in debug builds
  only for the same reason `SWIFT_PWA_WEB_ROOT` is: a shipped app that took its
  identity from its environment would let whoever launched it choose which
  folder under Documents it adopts). The private containers deliberately do not
  move with it — a shipped app scopes them by bundle id, so renaming the
  unbundled leaf would strand development state without making the two agree.

  Two things found while fixing it. The display name reaches the filesystem, so
  it is now reduced to exactly one path component — `/`, `\` and the
  Windows-reserved set become `-` on *every* platform, so `Reader: Pro` owns one
  folder everywhere rather than working on macOS and silently failing to create
  its directory on Windows. And **the same gap is permanent on Linux and
  Windows**: `Bundle.main.infoDictionary` is empty on swift-corelibs-foundation
  (measured), so a *shipped* binary there answers its executable name too. Until
  a bundler carries the name itself, an app whose display name differs from its
  target name should call `AppPlugin.setDisplayName(_:)` in `configure` — the
  seam Android's backend already uses. Both platforms' "Known limitations" say
  so. `Scripts/verify-app-identity.sh` measures all four cases (driven, bare,
  bundled, declared) against a freshly scaffolded app.

- **The origin root (`/`) serves the app's entry, on Android too** (#242).
  #212 put the Android bundle at the origin root so every root-absolute asset
  resolved; what didn't come with it was the directory index. `web.entry` was
  served at `/index.html` and at no other name, so the one navigation an app
  writes as "go back to the top" —

  ```js
  window.location.replace(`${location.origin}/`);
  ```

  — landed on Chrome's `net::ERR_INVALID_RESPONSE` with no back stack to
  recover with, on Android alone. Measured on a Galaxy Z Fold7 (Android 16),
  0.11.1. The bundle handler now resolves a directory path to its index: the
  mount's own root serves the entry, a deeper directory (`/docs/`) serves its
  `index.html`, and a path with no trailing slash still 404s, because serving
  `/docs/index.html` for `/docs` would resolve that document's relative URLs
  one directory too high.

  The same resolution moved into Core's `AssetProvider`, which Apple, both GTK
  backends, Windows' interception path and Android's runtime
  (`ctx.serveDirectory`) mounts all share — so it now honours `web.entry`
  rather than a hardcoded `index.html`. An app whose entry is `app.html` had no
  working origin root anywhere.

- **A ranged response's `Content-Length` and its body agree** (#244). Chromium
  applies the `Range` to whatever stream `shouldInterceptRequest` returns: it
  bounds the range with `available()`, `skip()`s to the start offset, reports
  `Content-Length` as the length that was *asked for* — and then reads the
  stream to EOF. Measured over a 12,270-byte file on a Fold7: `bytes=100-199`
  announced 100 bytes and delivered 12,170. Chromium tolerates its own
  mismatch, and no `Accept-Ranges: bytes` is advertised so nothing on Android
  ranges by choice, but a consumer that trusted the header would truncate
  silently — and every range of a large file was reading the whole tail for
  nothing.

  The runtime now caps the stream at the end of the range. It deliberately does
  *not* skip to the start offset: Chromium already does, and doing it twice
  would deliver the wrong bytes. `available()` still reports the full remaining
  length, because that is what Chromium's bounds check runs against before it
  skips. Applies to the bundle, `build.serve` mounts and runtime
  `ctx.serveDirectory` mounts alike. A range with no explicit end (`bytes=500-`,
  `bytes=-50`) already agreed with itself and passes through untouched.

- **A missing file on Android says so** (#242). A not-found out of
  `shouldInterceptRequest` was a response with a null stream, which the WebView
  renders as `ERR_INVALID_RESPONSE` — a protocol failure, not a missing file,
  which sends you looking for a corrupt mount rather than for the path you
  never staged. It cost the reporter an hour. Both the bundle and a runtime
  mount now answer a real `404` carrying a body that names the path. Only for
  the app's own origin: a null response for any other host means "not mine",
  and inventing a 404 there would break every outbound request the page makes.

## [0.11.1] - 2026-09-18

### Added

- **`native_include_dirs` — a vendored library's headers reach the compile, not
  just its binaries the link** (#238). `native_library_dirs` (0.10.8, #220) put
  the `.so`/`.a` on the linker's search path and staged it into the artifact.
  The compile happens first, and nothing put the matching header anywhere, so an
  app vendoring anything with an API — the reported case is SQLite, because GRDB
  needs one and the NDK ships none — died at the first Swift module importing
  the C shim:

  ```
  GRDBSQLite/shim.h:1:10: error: 'sqlite3.h' file not found
  ```

  ```json
  "android": {
    "native_include_dirs": ["Vendor/sqlite/include"],
    "native_library_dirs": ["Vendor/sqlite/<abi>"]
  }
  ```

  Emitted as `-Xcc -I<dir>` on `android`, `linux` and `windows`, at every place
  #220's own closing measurement found the library half was needed: the three
  bundlers *and* the CLI's host runs (`dev`, `drive`, and the headless catalog
  dump `build` uses to check `permissions` / `agent.expose`), which compile the
  same sources.

  A separate key rather than something `native_library_dirs` implies, because
  the two are genuinely different directories: the library is per-ABI and the
  header, being architecture-independent, is not. `<abi>` is substituted in
  both, so neither key surprises someone who learned the other.

  This is the second half of the regression #219 documents. `CPATH` was the
  recipe an adopter used through 0.10.x, and Swift 6.4's `swiftbuild` engine
  drops it for the same reason it drops `LIBRARY_PATH` — #219 moved the library
  half to a flag, and the header half had no flag to move to. With neither
  reaching the build, there was no supported way to build such an app for
  Android from a clean checkout at all: a bare `swift build --swift-sdk` takes
  `-Xcc` but stages nothing and assembles no APK, and the CLI, which does, took
  no passthrough.

  Verified on real hardware on all three, with a control:
  `Scripts/verify-vendored-native-deps.sh` (Android cross-compile, Linux) and
  `Scripts/verify-vendored-native-deps.ps1` (Windows) scaffold an app that
  vendors a library, build it with a genuinely cold clang module cache, and
  check the symbol landed in the built binary. The control is not optional
  here — clang's module cache holds the built shim module *across a change of
  include flags*, so a machine that once compiled with `-Xcc -I` goes on
  succeeding indefinitely. Deleting `.build/out/Products` is not enough and
  neither are the intermediates; the scripts wipe `.build` wholesale for each
  run. The probe library is built under a name nothing else provides, because
  most Linux boxes ship a system `sqlite3.h` that would satisfy the control and
  make the run report a pass it hadn't earned.

### Fixed

- **Windows: `swift-pwa build --target windows` could not complete on Swift
  6.4** — two faults found by running the check above on a real box, both
  older than #238 and neither reachable from CI, which compiles the Windows
  backend but never runs the CLI against an app.

  The headless catalog dump (and `dev`, and `drive`) compiles `CWebView2Shim`
  like any other build, but the WebView2 / WIL include and lib directories
  were resolved inside `WindowsBundler` and reached only the bundler's own
  `swift build`. They rode on `INCLUDE` / `LIB` for everything else until 6.4
  stopped forwarding those (#219), so every build died in the permissions
  check with `'wil/com.h' file not found` — before the bundler ran at all.
  `NativeLibrarySearch` now passes them to the host runs too.

  And an app declaring `windows.native_library_dirs` crashed SwiftPM outright:
  the runtime-environment override was keyed `PATH` while Windows' own
  environment spells it `Path`, and a child handed both traps with
  `Duplicate values for key: ProcessEnvironmentKey(value: "PATH")` — naming
  neither swift-pwa nor the manifest entry behind it. The override now uses
  whichever spelling the environment already has.

## [0.11.0] - 2026-09-18

### Added

- **`auth.*` — open a provider's consent page and catch the OAuth redirect, on
  all five platforms, with PKCE** (#221). The one step of an OAuth 2.0
  authorization-code flow an app in a swift-pwa shell could not do for itself.

  ```js
  const { code, codeVerifier, redirectUri } =
    await __SWIFT_PWA__.invoke('auth.authorize', {
      authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
      clientId: '…', scopes: ['…/auth/drive.readonly'], redirect: 'auto',
    });
  const tokens = await __SWIFT_PWA__.invoke('auth.exchange', {
    tokenEndpoint: 'https://oauth2.googleapis.com/token',
    clientId: '…', code, codeVerifier, redirectUri,
  });
  ```

  Everything either side of this already existed — `net.*` does the token
  exchange and every call after it, `secrets.*` holds the refresh token — but
  the middle is per-platform in a way an app shouldn't own, and it is the *same*
  middle for Drive, Dropbox, OneDrive, GitHub and Graph alike. The reporting
  adopter was designing Google Drive support and found the framework had
  everything but this.

  **It can't be done in the page.** Google, GitHub and Microsoft all refuse to
  render consent inside an embedded webview (`disallowed_useragent`), which is
  RFC 8252 §8.12 working as intended: an app that hosts the consent page can
  read the password out of it. So the page is the system browser, and the
  redirect has to cross a process boundary — two mechanisms, picked per
  platform. Desktop binds a **loopback HTTP listener** on an OS-assigned
  `127.0.0.1` port (new, beside `LoopbackServer`, reusing `LoopbackSocket`);
  mobile catches a **custom scheme**, on iOS through `ASWebAuthenticationSession`
  and on Android through `ACTION_VIEW` onto the existing `app.openURL` channel.

  Loopback is what `redirect: 'auto'` picks on desktop because it registers
  nothing — which matters most on a portable Windows `.exe`, where a custom
  scheme costs the user a `register-url-schemes.cmd` run *before* they can ever
  finish signing in, at a moment the app has no way to tell them about.

  **`auto` refuses rather than guesses on iOS and Android.** The issue proposed
  reading the scheme from `pwa.json`'s `url_schemes`; that can't work.
  `url_schemes` is build-time only — it generates `CFBundleURLTypes`, an
  `<intent-filter>`, a `.desktop` handler and Windows registry scripts, and
  nothing carries it into the process — and even with the list in hand the right
  entry is provider-specific (Google's is the reversed client ID, derived from a
  value only the caller knows). A wrong guess wouldn't fail at the call; it would
  fail minutes later at the provider's redirect, in a browser, with the app
  showing nothing. So mobile takes `redirect: { scheme: … }` and names both fixes
  in `E_AUTH_REDIRECT` when it is missing.

  **PKCE (`S256`) and `state` are always on, with no way to weaken either.**
  RFC 7636 is mandatory for native clients for exactly this runtime's reason: on
  every platform where the redirect returns over a custom scheme, another locally
  installed app can register the same scheme and receive the code. A callback
  whose `state` doesn't match is dropped and the wait continues — a mismatch is
  an attack or an unrelated local request, and neither should end a flow the user
  is still in — except under Apple's one-shot session, where there is nothing
  left to wait on and it throws `E_AUTH_STATE`.

  The issue also reported that PKCE was impossible on Windows and Android for
  want of a SHA-256. That turned out to be wrong about the framework (`Crypto` is
  declared on `SwiftPWACore` for `.linux`/`.windows`/`.android` since #229, and
  CryptoKit covers Apple) and right about apps, which have no hash of their own —
  which is why the primitive owns the verifier and challenge rather than taking
  them.

  Registration is **one line that compiles on all five**:
  `ctx.use(AuthPlugin(networkClient: URLSessionNetworkClient()))`. `AppContext`
  gains `urlOpener` and `authorizationSession` so the backend hands in the
  browser and (on Apple) the OS session, instead of every adopter writing an
  `#if os(…)` ladder naming `AppleURLOpener` / `GTKURLOpener` /
  `WindowsURLOpener` / `AndroidURLOpener` — a branch in a shared `main.swift` is
  a branch that breaks on the platform its author can't test. `OAuthAuthorizer`
  is the same object underneath, so a flow can run entirely in Swift and no token
  need ever be visible to the page.

  **`agent.expose` refuses the whole `auth.` namespace** at build time, alongside
  `secrets.` and `agent.`. It is the same hole as `secrets.*` one step earlier:
  that one hands an agent a key the app already had, this one *mints* a new one —
  and since both commands take the provider's endpoints as arguments, an agent
  holding them chooses whose credential to get, while the consent sheet built
  from the developer's own description would honestly read "Sign in".

  Nothing is stored: no token cache, no refresh scheduling, no keychain writes.
  See [docs/auth.md](docs/auth.md) and the tutorial
  [Signing in with a cloud provider](docs/tutorials/signing-in-with-a-cloud-provider.md).

  Verified by `Scripts/verify-oauth.sh` (and `verify-oauth.ps1`, since Windows
  has no bash), which drives a real app — scaffolded by a fresh `swift-pwa
  init`, not an Example — against a stand-in authorization server running as its
  **own process**, so the PKCE challenge is checked by the far side of the
  protocol rather than by a test double: a challenge can be well-formed and
  wrong. It carries the two controls this repo has learned to demand: a leading
  `system.openURL` check, so a box with no browser SKIPs instead of reporting a
  broken feature, and a final flow that nothing redirects to which *must* time
  out, without which every check above it is equally consistent with a receiver
  that resolves whatever it is handed.

  Both controls earned their keep immediately. The browser wait was 10 seconds,
  which is plenty for a Mac with a browser already running and far too short for
  a cold Chrome under Xvfb — so the first Linux run reported "no browser on this
  box" on a box with two installed, the control failing at its one job. And the
  Windows script needs somebody **logged on at the console**: `schtasks /it` runs
  the app as the interactive user, and a server sitting at the login screen has a
  connected console session with no one on it. It detects that and SKIPs rather
  than reporting an app that never started.

  Where it stands per platform: **all five** run the whole flow green against a
  real system browser — macOS, both Linux backends (GTK4 and GTK3, on their own
  boxes) and Windows x64 through `verify-oauth.sh` / `.ps1`, **Android** on a
  cabled Galaxy Z Fold7 through `verify-oauth-android.sh`, and **iOS** on a
  cabled iPad mini through `verify-oauth-ios.sh`. All four desktop platforms also
  pass the full Core suite, so the loopback receiver's real-socket tests have run
  on BSD sockets and on Winsock.

  The desktop run is wired into CI as a weekly `oauth` job, off the PR gate,
  which **files its own tracking issue** on failure the way the next-toolchain
  canaries do. It passes `--require-browser`, a new flag that turns "no browser
  on this box" from a SKIP into a failure — skipping is right for a developer on
  a headless machine and worthless in CI, where a job that skips everything
  reports green having tested nothing. The handler CI registers is a **fetcher,
  not a browser**, and the job says so: a hosted runner ships Chrome but
  registers no default handler, and Ubuntu 24.04's AppArmor restriction on
  unprivileged user namespaces breaks its sandbox so that GIO reports a
  successful spawn and the browser then dies. Everything that can regress in our
  own code is still covered end to end; rendering a consent page is what the
  desktop and device runs are for.

  The two mobile scripts exist because the redirect arrives differently there and
  a desktop check can't reach it. Android's fires the real
  `ACTION_VIEW` Intent the OS routes from a provider's 302, exercising
  `SchemeRedirectReceiver` and the `app.openURL` chain — the half no desktop
  check touches. iOS can't do that at all: the callback must travel through
  `ASWebAuthenticationSession`'s *own* navigation, so the stand-in provider
  gained an opt-in 302 and the probe registers the session as `ephemeral`, which
  is what skips the cookie-sharing prompt nothing can tap. That run also asserts
  the property the session is chosen for — **the callback never reaches the
  `app.openURL` channel**, so nothing else listening there can see an
  authorization code.

  The cookie-sharing prompt itself and cancel-by-dismissal stay as two cases in
  [docs/manual-test-cases.md](docs/manual-test-cases.md): no API observes a
  system sheet, and `drive shot` captures the webview's renderer, not the
  screen.

  The loopback receiver's tests open **real sockets** rather than mocking
  `LoopbackSocket`, since working across five platforms' socket APIs is the only
  interesting thing about it. That is also what caught the bug this feature is
  most likely to have shipped with: reading only the HTTP request line left the
  browser's headers unread, and closing a socket with unread input sends an RST
  that **discards the response already written** — so the user would have seen a
  connection-reset page after a sign-in that actually succeeded.

  **Four bugs the device runs found that nothing else could**, all on the Apple
  path, none reachable from a unit test:

  - `present` resumed its continuation **twice** — `start()` returning false and
    the session's completion handler are not exclusive — which doesn't throw, it
    traps: `SWIFT TASK CONTINUATION MISUSE`, signal 5, app gone.
  - The presentation **anchor** took any window from any scene.
    `ASWebAuthenticationSession` rejects one whose scene isn't
    `.foregroundActive`, reporting only "The operation couldn't be completed.
    (…error 3.)" — naming neither the window nor the reason. It now prefers
    active scenes *and* says what it chose, because that message alone is
    undiagnosable from a device.
  - A freshly launched app is `.foregroundInactive` for a moment, so an
    `auth.authorize` fired from a startup path or straight off a deep link hit
    exactly that error. Measured: the call that failed at launch succeeded six
    seconds later. `present` now waits briefly for a presentable scene.
  - `timeoutMs` **hung the caller** on this path. A task group doesn't return
    until every child finishes, and the presenter's continuation simply leaked
    when cancelled — so a 6-second timeout produced a 180-second hang. The
    continuation is now resumed by whichever of completion, refusal, or
    cancellation arrives first.

  That last one was a hole in a fix made the same day: `timeoutMs` was documented
  for every platform and applied on three, because a presented session has no
  deadline of its own — `ASWebAuthenticationSession` waits for the user forever.

  Two Swift toolchains on Linux disagreed with the first version of the
  custom-scheme receiver, which stashed a `CheckedContinuation` in a
  lock-guarded property: 6.3.1 crashed *compiling* it (`swift-frontend` signal
  11 in the `ClosureLifetimeFixup` SIL pass, no diagnostic), and where it did
  compile the suite segfaulted inside `CheckedContinuation.resume(returning:)`
  on the event bus's emit thread. It is an `AsyncStream` now — which is the type
  built for "yield from any thread, possibly before anyone is awaiting", has no
  continuation bookkeeping to get wrong, and is shorter. Neither failure
  reproduced on macOS or Windows, which is the argument for running the suite on
  a real box of each platform rather than generalising from one.

- **An app can declare the directories its own vendored native libraries live
  in, per ABI** — `native_library_dirs` in `pwa.json`'s `android`, `linux` and
  `windows` sections (#220).

  ```json
  "android": { "native_library_dirs": ["Vendor/sqlite/<abi>"] }
  ```

  An app that links a native library the platform doesn't ship had no way to
  say where it is. The reporting adopter vendors SQLite for GRDB and hit
  exactly that. swift-pwa already had the mechanism — the ONNX Runtime tier
  resolves `libonnxruntime.so` per ABI inside the cross-compile loop and hands
  the directory to *that ABI's* link step — but it was hard-wired to that one
  tier. The generic workaround left to an app was a global search path, and the
  bundler links every ABI in one process, so a single global value can only
  ever carry one ABI's copy: **a multi-ABI build with a vendored library was
  not expressible at all.** `<abi>` is substituted per ABI, which is what makes
  it expressible.

  Each resolved directory goes on that build's link search path, and the shared
  libraries in it are staged into the artifact: `jniLibs/<abi>/` on Android,
  `linuxdeploy --library` into the AppImage, next to the `.exe` on Windows.
  Staging is the half an app can't do by hand either — the Gradle scaffold is
  regenerated on every build, so a `.so` copied in manually is gone next time
  and the APK dies at launch with `UnsatisfiedLinkError`. Everything in the
  directory is staged, not the subset the built binary's `DT_NEEDED` list names
  — a library the app `dlopen`s by name is in neither list, and its absence
  only shows up on a device. A declared directory that isn't there fails the
  build naming the entry, rather than reaching the linker as `unable to find
  library -lsqlite3`, which names neither.

  Two more places needed it, both found by building a real app against a real
  vendored `.so` rather than by reasoning about it, and each only visible once
  the one before it worked. The CLI's own host runs — `dev`, `drive`, and the
  headless catalog dump `build` uses to check `permissions` / `agent.expose` —
  run the binary straight out of `.build`, where nothing has been staged, so
  they need the directory on the loader's path as well as the linker's; the
  link succeeded and the dump then died at load. And `linuxdeploy` walks the
  binary's `DT_NEEDED` list against the *system* search path **before** it
  looks at the `--library` files it is about to deploy, so it refused the
  AppImage naming the very library it had been handed.

  Verified end to end, both halves with a control that had to fail. On Linux,
  an AppImage whose binary loads the bundled copy with the vendored directory
  deleted. On Android, `arm64-v8a` and `x86_64` each linked against their own
  `<abi>` directory, the right-architecture `.so` in each `jniLibs/<abi>/` and
  in the assembled APK, and the app running on a Galaxy Z Fold7 — against the
  same APK rebuilt with only the staged library removed, which dies at launch
  with exactly the error this prevents:
  `UnsatisfiedLinkError: dlopen failed: library "libmylib.so" not found: needed
  by …/libProbeApp.so`.

  The device run also turned up a trap worth documenting: Android 15+ wants
  every `.so` **16 KB page-aligned**, and a hand-built vendored library usually
  isn't, because a bare `clang -shared` still defaults to 4 KB. Everything
  swift-pwa stages is already aligned — the Swift Android SDK's runtime,
  `libc++_shared.so`, and the app's own `.so` all measure `0x4000` — so this is
  the adopter's build to fix (`-Wl,-z,max-page-size=16384`), and
  docs/android-setup.md now says so.

  Not on Apple: SwiftPM's `.binaryTarget` xcframework is the first-class
  mechanism there, and it carries the code-signing and rpath handling a
  directory of loose dylibs does not. The asymmetry is upstream's, not ours —
  it is also why the off-Apple mechanism below exists at all.

- **`swift-pwa doctor --target android` now checks the host against the
  installed Swift Android SDK**, and the docs stop naming a Swift version
  (#218).

  The Swift Android SDK's prebuilt `.swiftmodule`s load only in their own
  release, so a cross-compile on a host without that release fails with
  `module compiled with Swift X cannot be imported by the Swift Y compiler` —
  at the end of a multi-minute build, naming the compiler rather than the fix.
  `doctor` now reports the pairing up front: which release the installed SDK
  bundle needs, and whether this machine can serve it (a matching
  `.xctoolchain` on macOS, the ambient `swift` or a swiftly-installed release
  elsewhere). Advisory, not required, because a plain `build --target android`
  emits the Gradle scaffold and needs no cross-compile at all.

  **The policy it encodes: there is no project-wide Android Swift version, per
  host or otherwise.** The alternative — one release across every machine — was
  considered and rejected. From Xcode 27 a Mac cannot choose (the macOS SDK
  passes `-target-arch-variant`, which earlier compilers reject), CI cannot
  enforce a choice either way (the `android` job is scaffold-only on purpose,
  since a hosted runner can't cross-compile this reliably), and after #217 the
  matching is automatic anyway. So the installed SDK names the release and the
  CLI finds a toolchain for it. `docs/android-setup.md` said `swiftly install
  6.2.0` and read as though 6.2 were *the* supported version; its examples are
  now labelled as shape, not as a supported set.

  Checking this surfaced one stale claim: the **API 28 floor is swift-pwa's
  own**, not the SDK's. It was the SDK's under 6.2, whose `swift-sdk.json`
  declared triples for API 28–36; the 6.4 bundle declares 23–36 again
  (measured). The bundler still clamps to 28 and the docs now say why that is
  ours to lift, with a build and an on-device run at the lower API, rather than
  something the toolchain imposes.

- **`ctx.serveDirectory(_:at:)` works on Android** — a directory the app mounts
  at *runtime*, from any root it can read, served on the bundle origin (#213).

  It was documented as a desktop capability and was a silent no-op there. The
  `WebViewAssetLoader` is built in `Activity.onCreate`, before any Swift runs,
  so the only mounts that could exist were `pwa.json`'s build-time
  `build.serve` entries, rooted inside app storage. That covers a content pack
  the app downloads into its own directory and nothing else: an app whose roots
  are folders the *user* points it at — a reader's library, wherever the books
  already live — could not serve one file to its own page. Copying them into
  app storage is a different product, and `fs.readBinary` is a base64 copy of
  every file (a 300 MB PDF becomes a 400 MB string) that defeats range-based
  loading anyway.

  **Kotlin deliberately keeps no mount table.** The obvious design — Swift
  pushes each mount over the RPC, Kotlin holds a prefix→root map — needs a sync
  protocol and can go stale between a `serveDirectory` call and the request that
  follows it. Instead `shouldInterceptRequest` asks Swift synchronously, the way
  `shouldOverrideUrlLoading` already did, so **Core's `AssetProvider` is the one
  mount table for all five backends**: same longest-prefix match, same per-mount
  traversal guard, same MIME table, and `unserveDirectory` takes effect on the
  next request with nothing to keep in sync. It costs a JNI upcall into a
  lock-guarded path lookup, on a WebView worker thread rather than the UI
  thread, and answers nil for everything outside a mount — which on Android is
  the entire app bundle, since that provider is never given a `/` root.

  **One platform limit, measured rather than assumed: a `Range` request is
  answered `200`, not `206`.** A `206` returned from `shouldInterceptRequest` is
  rejected by the WebView *before the page sees it* — `TypeError: Failed to
  fetch`, with nothing logged by us or by Chromium, against a correct 206
  carrying the right `Content-Range` and a bounded stream. What Chromium does
  instead is range the stream itself: given a `200` it seeks to the requested
  start offset and serves to the end of the file. So a `<video>` scrub and a
  range-fetching reader both work; the end of the range is ignored. No
  `Accept-Ranges: bytes` is advertised, deliberately — promising a 206 that
  never arrives would send a client that checks (pdf.js does) down the range
  path to be wrong about what it got. `build.serve` mounts have always behaved
  this way; runtime mounts now match them. Device-verified on a Fold7 via
  `Scripts/verify-android-served-mounts.sh`.

- **`android.permissions` in `pwa.json`** — Android permission names emitted
  verbatim as `<uses-permission>` entries (#214).

  `permissions.web` declares capabilities the *web platform* has a name for and
  maps each onto whatever Android calls it, so a permission with no web
  counterpart had no door at all. All-files access is the case that prompted it:
  an app reading folders the user points it at, by path, needs
  `MANAGE_EXTERNAL_STORAGE`, and the only way to get it was editing the
  generated `AndroidManifest.xml` — which the next build overwrites.

  ```json
  "android": { "permissions": ["android.permission.MANAGE_EXTERNAL_STORAGE"] }
  ```

  Emitted after the built-in and web-derived entries, duplicates dropped.
  Validated for *shape* at build time (a bare `MANAGE_EXTERNAL_STORAGE` is
  refused, naming the fully-qualified form) but deliberately **not** against an
  allowlist of known permissions: OEMs define their own and new platform
  releases add more, so a list would go stale and start refusing valid
  declarations. Declaring still grants nothing — a dangerous or special
  permission needs its runtime request, which is what the declaration makes
  possible. Some carry store-policy consequences; that is the app's call, not a
  reason the manifest can't express them.

- **`WindowEvent.didFocus` / `.didBlur` now mean the same thing on all five
  backends** — this window became, or stopped being, the one the user is
  working in (#214).

  Only macOS reported both from a real OS signal. Windows emitted `didFocus`
  from `WM_SETFOCUS` and had no `WM_KILLFOCUS` counterpart, so an app could
  learn it had become active and never that it had stopped. Both GTK backends
  emitted either one *only* from an explicit `focus()` call, which is the app
  talking to itself. iOS did the same. Android surfaced nothing at all.

  Now: `notify::is-active` on GTK3 and GTK4, `WM_KILLFOCUS` on Windows,
  `Activity.onResume` / `onPause` on Android, and scene did-become-active /
  will-resign-active on iOS. The two mobile backends matter most here — an app
  that was backgrounded there was *suspended*, so anything it was watching
  stopped being watched — and they are why an app re-reading state on becoming
  active, or re-engaging a lock on leaving, can now be written once in Swift and
  be right everywhere. `.didBlur` is pushed before `super.onPause()` so the
  handler is queued while the process is still scheduled. An explicit `focus()`
  is de-duplicated against the signal that follows it, so presenting a window
  doesn't report focus twice.

  Verified on real hardware on **all five**, one script per platform family: a
  Fold7 for Android, an iPad for iOS, and a logged-in desktop session on the
  GTK3, GTK4 and Windows boxes. Each asserts on a transition **nothing in the
  app asked for** — a backend that merely echoed its own `focus()` call would
  pass otherwise — and each carries a control that must succeed, because the
  failure mode here is an event that is simply absent.

  Three traps, each of which gave a confident wrong answer first. A desktop
  session has to be **unlocked**, and so does a device: under Xvfb a scaffolded
  GTK app maps no window at all, and nothing unmapped can ever become active, so
  the run passes vacuously; on iOS a locked device refuses to launch the app
  while installing it happily. On **Windows** a new window takes focus
  *synchronously inside* `createWindow`, so its first `WM_SETFOCUS` is delivered
  before `eventStream()` can be attached to the returned window — `AsyncStream`
  doesn't replay, so that first event is unobservable to any caller, and
  checking for it failed against correct behaviour. GTK doesn't race this; it
  maps once the main loop runs. And on **iOS** the app is *suspended* while
  backgrounded, which is the very window being measured, so it records to a file
  in its own container that `devicectl` lifts afterwards rather than answering a
  bridge command — and the build has to be `debug`, or the driver socket the
  first attempt relied on isn't compiled in at all.

- **`navigator.audioSession` works on Android** — the W3C Audio Session API,
  filled natively where the engine doesn't ship it, rather than exposed as a
  swift-pwa-shaped API beside it.

  *Why this and not an `audio.*` plugin.* All five engines were measured
  ([`docs/proposals/audio-plugin.md`](docs/proposals/audio-plugin.md)) and the
  roadmap's premise — that native capture/playback would be lower-latency and
  more capable than the webview's — does not hold: every engine already gives
  raw 128-frame PCM into an `AudioWorklet` at 2.7–10 ms base latency with
  gapless scheduling. What's genuinely missing is *policy*, and Apple's WebKit
  already has the standard API for it. A parallel API would make every app
  carry a branch, and the branch only breaks on the platform its author can't
  test.

  So an adopter's whole requirement is the line the web platform already
  defines, with no manifest key, no Swift call and no plugin to install:

  ```js
  navigator.audioSession.type = 'playback';   // or 'ambient' for a game
  ```

  **The type decides real behaviour, not a label.** On Android it maps to audio
  focus — `playback` / `play-and-record` take `AUDIOFOCUS_GAIN` (other audio
  stops), `transient` ducks, `transient-solo` pauses others, and `ambient` /
  `auto` deliberately request *no* focus, which is what leaves the user's own
  music playing. Device-verified on a Fold7 down to the focus stack:
  `requestAudioFocus() … AA=USAGE_MEDIA/CONTENT_TYPE_MUSIC req=1` on
  `playback`, `abandonAudioFocus()` with no re-request on `ambient`.

  **The polyfill matches WebKit's behaviour because it was measured against
  it**, not read off the spec: an unrecognised value — a bad string, a number,
  `null` — is *ignored* rather than throwing, leaving `type` on its previous
  value, and `audioSession` is defined on `Navigator.prototype` where the real
  one lives. The same expression run against macOS WebKit and the Android
  polyfill now returns byte-identical results. It installs only where the API
  is absent and never wraps a real implementation.

  Reading `type` back reports what the *platform* did rather than what the page
  asked for, so an OS that coerces or refuses a type can't leave a page
  believing it has background audio it doesn't have.

  **On Linux and Windows the fill records the type and drives nothing**, and
  that is a platform limit rather than an omission: the playing stream belongs
  to the *webview's own process* (`WebKitWebProcess`, `msedgewebview2.exe`) and
  both platforms set audio policy per-stream, by the stream's creator — so the
  shell has nothing to set. Android is the exception that makes a real fill
  possible there, because its focus is per-app. Measured rather than assumed,
  including that a stock GNOME/PipeWire session loads no role-ducking module at
  all, so the one knob that *is* settable is inert anyway. It costs little:
  desktop audio was measured to keep playing when the window is minimized, so
  the behaviour the type buys on a phone is already true there.

  The page-visible API is identical on all five, verified on each: present on
  `Navigator.prototype`, invalid values ignored, `type` and `state` reading back
  the same way.

- **`navigator.mediaSession` works on Android** — the W3C Media Session API,
  filled over a platform `MediaSession` plus a transport notification. Android
  is the only one of the five engines whose WebView doesn't expose it at all,
  so without this an Android app playing audio is invisible to the system: no
  lock-screen controls, no notification, and nothing for a headset button to
  talk to. The other four already route the web API to the OS (verified by
  driving the real control: a media key on macOS and Windows, the lock screen on
  iOS, MPRIS over D-Bus on both GTK backends), so the fill installs on Android
  alone.

  A page writes the standard API — `metadata`, `playbackState`,
  `setActionHandler`, `setPositionState` — and `MediaMetadata` is defined too,
  since it's missing wherever `mediaSession` is. Only the actions a page
  registers a handler for are published to the OS, because a transport button
  that does nothing is worse than one that isn't there.

  Device-verified on a Fold7: `dumpsys media_session` shows the app as the
  system's media button session (`active=true`, `state=PLAYING`, `actions=311`,
  metadata published), a real `KEYCODE_MEDIA_PAUSE` and `KEYCODE_MEDIA_NEXT`
  each reach the page's handler, and the lock-screen controls appear and work.

  **Two bugs this found, both of which failed silently** and neither of which a
  unit test would have caught. The action pump was started with a plain `Task`
  inside a `@MainActor` function, so it inherited that isolation — and Android's
  main thread runs a Java looper that never drains libdispatch's main queue, so
  the task was created and never scheduled: the OS delivered the action, Kotlin
  forwarded it, Swift yielded it, and nothing was at the other end (the same
  hazard that keeps `BridgeRuntime` off the MainActor). And the notification was
  refused with `IllegalArgumentException: Invalid notification (no valid small
  icon)` for an app that sets no icon — which `notify()` *logs* rather than
  throws, so it looked like it had worked.

  Not yet: artwork (`MediaMetadata.artwork` round-trips in JS but isn't shown by
  the OS), and the notification needs `POST_NOTIFICATIONS` granted — media keys
  work without it.

- **`setSinkId` is deliberately not filled**, which completes the audio work by
  deciding against it rather than building it. It's absent from WebKitGTK and
  Android's WebView, and an earlier draft treated that as our gap to close.

  It isn't, and the reason is the API's shape: `setSinkId` is a method on an
  `HTMLMediaElement`, so a page may route one element to the speakers and
  another to a headset. Everything a shell can reach is per-*process* — on Linux
  PipeWire can move a stream between sinks, but the node is the whole
  `WebKitWebProcess`; on Android there is no route-another-process's-media API
  at all. Two elements with different sinks can't both be honoured, and the
  failure would be silent.

  Unlike `audioSession`, an inert fill would be actively harmful here. A
  recorded-but-inert session type costs nothing, because what it buys on a phone
  is already true on desktop; a recorded-but-inert `setSinkId` would tell a page
  its audio had been routed when it hadn't — and `'setSinkId' in element` is
  exactly how a page decides whether to show a device picker. Absent, an app
  hides a picker it can't honour; filled, it shows one that lies.

  The line between the two cases: **fill a web API when a no-op is harmless and
  the outcome is already true; leave it absent when a no-op would make the page
  believe something false.**

- **The tutorials and samples now declare an audio policy**, so the first thing
  an adopter copies is the version that works on a phone.

  `Examples/CritterFacts`' speak-the-fact card and its dedicated `speak.html`
  both generate and play speech, and both would have stopped backgrounded on
  iOS as written — the sample was demonstrating the bug. The deck takes the one
  line; `speak.html` takes the whole story, since it is what someone building a
  read-aloud app will read: `audioSession.type`, lock-screen metadata with
  artwork, play/pause handlers, and `playbackState` driven from the element's
  own events so the transport row can't disagree with what is actually
  playing. The on-device AI tutorial gains a "speaking it" step next to its
  image one, and [`docs/ai-plugin.md`](docs/ai-plugin.md) tells a backend
  author the same thing where they'll be reading.

  Two measured anti-patterns are called out in both places, because both look
  reasonable and neither works: don't stream synthesis into a player as it
  arrives (on-device TTS runs ~2.5x *slower* than real time, so the buffer
  underruns), and don't schedule audio from a timer (throttled to ~1 Hz in the
  background — use the audio clock).

  The README roadmap's **"Platform audio (capture / playback)"** item is
  removed rather than marked done: measurement retired its premise. Every
  engine already delivers raw 128-frame PCM into an `AudioWorklet` at 2.7–10 ms,
  so there was no native plugin worth building — what was missing was policy,
  and that shipped as three decisions about standard web APIs. The feature
  matrix gains rows for `navigator.audioSession` and `navigator.mediaSession`
  with a footnote covering all three, `setSinkId` included.

- **An app that plays audio without declaring a policy is now told so**, at
  runtime and by `swift-pwa doctor`.

  This closes the gap the audio measurements opened rather than fixed. Setting
  `navigator.audioSession.type` is one line, but *forgetting* it is invisible
  on the machine the app is written on — the audio plays perfectly — and shows
  up only when an iPhone user leaves the app and the sound stops. An adopter
  who doesn't own an iPhone can't discover that, let alone report it, which is
  exactly the shape of gap the project's stance exists to close.

  Both checks fire on a *pairing* — audio actually sounding, policy absent —
  because either half alone is noise. At runtime, the first media element that
  plays or `AudioContext` that reaches `running` while the type is still `auto`
  produces one `console.warn` naming the consequence and the remedy; an
  `<audio>` element that never plays, an `OfflineAudioContext` rendering to a
  buffer, and a type set in the same handler that starts the sound all stay
  silent. `doctor` applies the same pairing to the project's `web/` sources and
  reports it as advisory — never a build failure — naming the file it matched,
  so the one unavoidable false positive (a bundled framework that merely
  mentions `AudioContext`) is dismissed at a glance.

  The Web Audio half observes by subclassing the `AudioContext` global, since
  nothing fires when a context starts. Verified transparent on device and on
  macOS: `AudioContext.name`, `instanceof`, the prototype chain and a page's
  own `extends AudioContext` all behave unchanged. Verified on both engines
  that it fires for Web Audio and for media elements, and stays silent once a
  type is declared — on macOS reading back WebKit's **own** `audioSession`, not
  the fill.

- **`MediaMetadata.artwork` reaches the lock screen and the notification** on
  Android, which completes the `navigator.mediaSession` fill.

  The design decision worth recording is that **the page fetches its own
  artwork and the bytes cross the bridge**, rather than the URL crossing and
  the platform fetching. Handing Android a `src` would fail on the most common
  case by far — cover art in the app's own bundle, which lives on a virtual
  origin no other process on the device can resolve — and fail silently, since
  a decode that finds nothing looks the same as a track with no art. Fetching
  in the document also makes `blob:` and `data:` artwork work for free.

  Two behaviours follow from that choice and are documented rather than
  implied: the fill picks the artwork entry closest to **512 px** instead of
  the first or the largest, so a page offering several `sizes` gets a sharp
  cover without pushing a print-resolution master through the bridge; and art
  over **4 MB** is skipped with a `console.warn` rather than resized, because
  re-encoding a page's own image is a surprise. Metadata text publishes
  immediately and the image follows, so downloading a cover never delays the
  controls.

  Device-verified on a Fold7 against the real controls: a page offering a 96 px
  and a 512 px cover gets the 512 px one drawn in the media notification;
  switching to a track with no artwork clears it rather than leaving the
  previous cover under the new title; an artwork URL that 404s leaves the track
  showing with a warning; and the notification's own pause button still reaches
  the page's handler.

### Changed

- **Vendored native libraries reach the link step as a flag, not an
  environment variable** — Linux and Windows, closing the desktop half of the
  Android fix that shipped last release (#219).

  Off Apple, swift-pwa hands a vendored library to the linker without writing a
  `-L` into a package manifest's `unsafeFlags`, which would poison dependency
  resolution for everyone depending on the package. That used to be
  `LIBRARY_PATH` (Linux) / `LIB` (Windows). **Swift 6.4 makes `swiftbuild` the
  default build engine, and it does not pass those to the link task.** Measured
  on a real Linux box at 6.4.0, with 6.2.0 and 6.3.1 as the control: the same
  build that links cleanly with `-Xlinker -L<dir>` fails with the environment
  variable set, as `cannot find -lonnxruntime` — an error that reads like a
  missing dependency rather than a missing search path, and names no fix. Under
  the classic build system both mechanisms work, which is why nothing was
  failing yet: CI pins Linux at 6.2 and Windows at 6.3.1.

  All three tiers move: ONNX Runtime on Linux and Windows, llama.cpp on both,
  and — found while doing it, and not in the issue — the **WebView2 loader's
  import library and the WebView2 / WIL headers**, which `WindowsBundler` had
  been putting on `LIB` and `INCLUDE` for every Windows build, AI tiers or not.
  The Vulkan SDK's `Lib` moves with them. The Windows spelling is
  `-Xlinker /LIBPATH:<dir>` and `-Xcc -I<dir>`: `link.exe` does not understand
  `-L` at all and reads one as an input filename, so a wrong spelling fails on
  *that* instead.

  **`INCLUDE` is dropped too, not just `LIB`** — measured on the Windows box
  under 6.4.0, each with a control that had to fail: a header reachable only
  through `INCLUDE` is `'elsewhere.h' file not found` and the same header
  behind `-Xcc -I` compiles; a library reachable only through `LIB` is a link
  error and the same library behind `/LIBPATH:` links; and with neither, both
  fail. Under 6.3.1 every one of those passes, which is what makes it a 6.4
  regression rather than a broken box.

  **The environment variables are gone rather than kept as a second
  mechanism.** Two mechanisms is how this went unnoticed for a release: the
  redundant one covers for the broken one until it doesn't, and then the
  failure is silent again. The repo's own CI, `Scripts/remote-linux.sh`, the
  Windows setup doc's manual recipe, and the workflow `swift-pwa init` emits
  all move with the product, so none of them can drift back. (The generated
  workflow simply stops setting them: `swift-pwa build --target windows` finds
  `packages/` itself and passes the paths as flags.)

  Verified on both hosts, in both directions, with 6.2.0 / 6.3.1 as the
  control: a real app whose vendored `.so` the build could not find with the
  environment variable set and linked cleanly with the flag; and the whole
  swift-pwa package — `CWebView2Shim` included — building on Windows under
  6.4.0 with **no** `INCLUDE` or `LIB` additions at all.

### Fixed

- **Swift 6.4 can link a Linux or Windows app again** (#229). Under 6.4 —
  where `swiftbuild` became the default build engine — *every* app linking the
  GTK backend failed at the product link with `undefined reference to symbol
  'ZSTD_isError'` and `libzstd.so.1: DSO missing from command line`. The
  vendored zstd decoder compiled fine and its object sat in the products
  directory; it just never reached the link. Windows was broken the same way
  and worse, with `Crypto` missing too: `lld-link: error: undefined symbol:
  $s6Crypto6SHA256VACycfC` … `ZSTD_isError` — the updater's whole verification
  path.

  The cause is neither zstd nor Linux. **swiftbuild resolves a target's
  platform filter once, from whichever dependency edge it reaches first**, and
  a filter that doesn't match the platform being built drops that target's
  object from the product link. `CZstd` is reached from three backends —
  `.when(.macOS)` from the Apple one, `.when(.linux)` from GTK,
  `.when(.windows)` from Windows — and the Apple edge is declared first, so
  Linux and Windows builds both took the Apple filter and dropped it. Two
  minimal packages measured what does and doesn't rescue it: a second edge that
  *does* match the platform does not, and neither does an unconditional edge
  from a third consumer. The only thing standing between a working build and a
  broken one was the order the edges happen to be declared in.

  So every edge onto a shared target now spells the same condition, hoisted
  into a named `let` where it needs one: `zstdPlatforms`, `cryptoPlatforms`,
  `zipPlatforms`, `onnxDesktopPlatforms` (which the GPU tier's Windows swap
  would otherwise split). A target's platform condition is a property of the
  target, not of each edge. Two divergences that had nothing to do with this
  bug turned up while unifying them: the `SwiftPWAArchiveTests` edge onto
  ZIPFoundation claimed `.android`, which the library cannot build for at all,
  and `CStbImage` was gated three different ways. `Crypto` is the one edge set
  that *can't* agree — the runtime must not pull swift-crypto onto Apple, where
  its consumers use CryptoKit, while the CLI imports it outright on every host
  it runs on — so that exception is named, explained and allowed in the test
  rather than left to be rediscovered.

  `ManifestDependencyDriftTests` fails if any other two edges disagree, reading
  edges wrapped over several lines as well as single-line ones — the wrapped
  ones are where both surprises were hiding, since a condition is what pushes a
  line past the column limit. That guard is the durable part: the manifest read
  perfectly reasonably, and the failure it caused was three hops away in
  another platform's link.

  Measured before and after on all three desktop platforms under 6.4: both
  Linux boxes (GTK3 and GTK4, different distros) build the package clean, link
  `Examples/HelloPWA` with `CZstd`'s object in the link list, and start the
  binary under Xvfb; the Windows box goes from the undefined-symbol wall above
  to a linked 30 MB `.exe`; macOS builds and the suite passes. 6.2.0 and 6.3.1
  build the same tree unchanged. docs/linux-setup.md drops the "stay on
  6.2 / 6.3.x" limitation this shipped with, and the four
  `Scripts/verify-windows-*.ps1` probes now pass `-Xcc -I` / `-Xlinker
  /LIBPATH:` instead of setting `$env:INCLUDE` / `$env:LIB`, which 6.4 ignores
  (#219) — they would have failed on any box that moved to it.

- **`deploy --target ios` says why a launch was refused, instead of blaming
  trust every time** (#224). The launch was wrapped in a blanket `catch` that
  attributed *every* failure to an untrusted developer profile, so the message
  sent you to Settings → VPN & Device Management to re-trust a profile that was
  already trusted — while the real cause, a locked screen, was in `devicectl`'s
  own output two lines above. The reporting adopter met it on two devices in a
  row, both of which had launched that same app from that same profile fifteen
  minutes earlier.

  It couldn't do better, because the reason never reached it: `Shell.run`
  inherits stderr and throws an exit status with no payload, so the text was a
  guess and it was the same guess every time. The launch now also writes
  `devicectl --json-output` to a temp file and reports the **leaf** of the
  `NSUnderlyingError` chain, where the specific reason lives — the outermost
  link says "The application failed to launch.", which is the one thing the
  caller already knew. stderr still passes through, so `devicectl`'s own
  rendering stays on screen and a run that dies before writing the document
  loses nothing.

  **No table of error codes, and not simply "print the leaf"** — both were
  ruled out by measuring four real documents off a device rather than reading
  one. A device that hasn't been unlocked since boot fails two links deep in
  `RemotePairingError` carrying only `NSLocalizedDescription`; a locked *screen*
  on a live tunnel fails three deep in `FBSOpenApplicationErrorDomain`, with the
  middle link describing the same thing in service-delegate jargon; and a bundle
  id that isn't installed puts the useful sentence on the **outermost** link
  under a leaf of LaunchServices bookkeeping that carries no message at all — so
  a reader that printed the leaf would have printed nothing at all for that one.
  The rule is the deepest link that actually carries a sentence, which is right
  for all four and for the causes nobody has hit yet.
  The Settings → Trust paragraph is kept, but only when `devicectl`'s own
  wording says the profile isn't trusted — matched on wording rather than a code
  because that case is *unmeasured* here (reproducing it means un-trusting a
  team on a device, which takes out every other development build on it), so it
  only ever adds a paragraph and never replaces the real reason.

  A refused launch still doesn't fail the deploy — the app is installed, and
  every cause is fixed on the device and retried with `--no-build` — but the
  final line no longer reads the same as a successful one: `Installed on
  <device>; the app is not running.` rather than `Deployed to <device>.`

- **An app that depends on an ONNX-tier product builds without also setting
  `ai.local_onnx_runtime`** (#215). The two used to be independent: the package
  graph decided whether the runtime was *linked*, and `pwa.json` decided whether
  the library was *staged* — so an app whose `Package.swift` named
  `SwiftPWAQwenTTS` and whose manifest had no `ai` section failed at the link
  step with an error that names no fix:

  ```
  ld.lld: error: unable to find library -lonnxruntime          # Android
  lld-link: error: could not open 'onnxruntime.lib': ...       # Windows
  ```

  Both measured on real hardware. The package graph is the authority now:
  depending on `SwiftPWAONNX`, `SwiftPWASegmentation`, `SwiftPWAImageEdit`,
  `SwiftPWAStableDiffusion` or `SwiftPWAQwenTTS` brings the tier, and
  `swift-pwa build` says so in one line. `ai.local_onnx_runtime` stays as the
  explicit opt-in for an app that reaches the runtime some other way; it is no
  longer something an adopter can forget.

- **The Android ONNX Runtime links again under Swift 6.4.** Found while fixing
  the above, and independent of it: the vendored `libonnxruntime.so` was handed
  to the cross-compile on `LIBRARY_PATH`, and **Swift 6.4's `swiftbuild` engine
  does not pass that variable through to the link task**. The same build that
  fails `unable to find library -lonnxruntime` with the variable set succeeds
  with `-Xlinker -L<dir>`, which is what the bundler passes now — still a build
  flag rather than `unsafeFlags` in a manifest, which is what the env var was
  avoiding. The desktop tiers (Linux `LIBRARY_PATH`, Windows `LIB`) use the same
  mechanism and will need the same fix when those hosts move to 6.4; CI pins 6.2
  and 6.3.1 there today.

- **An app's own `@MainActor` code runs on Windows, Linux and Android.** It
  never had, on any of the three, and the failure was silent: no error, no
  timeout, nothing on stderr — the `await` simply never returned (#216).

  Off Apple, `MainActor` is backed by libdispatch's main queue, and that queue
  is drained by exactly one thing: `dispatch_main()`. `gtk_main()`,
  `GetMessageW` and Android's `Looper` each own the main thread instead and
  drain nothing. swift-pwa's own code routes around this with `MainThread.run`
  and always has — the comment explaining why sits at the top of
  `WindowsAppRuntime.swift` — but an **app's** code has no such routing, and
  nothing at runtime said so. The reporting adopter had one `@MainActor` class
  reached by three bridge commands; on Windows all three hung forever while
  every nonisolated command on the same registry answered in milliseconds. The
  app's gallery sat at "0 items" with no console error.

  This is the shape an app written on macOS first will *have*: main-actor
  isolation is what Swift's concurrency model steers you toward for state that
  outlives a page navigation. So the fix is to make it work, not to document a
  rule.

  Each backend now waits on libdispatch's main-queue handle alongside its own
  events and drains it when it signals — GTK3/GTK4 via `g_unix_fd_add` on the
  default `GMainContext`, Windows by replacing `GetMessageW` with
  `MsgWaitForMultipleObjectsEx` over the handle plus `QS_ALLINPUT`, Android by
  adding the eventfd to the UI thread's native `ALooper`, which `Looper.loop()`
  already polls. It is the same integration CoreFoundation performs on Linux
  and Windows, and it fixes `DispatchQueue.main.async` for the same single
  reason.

  **The mechanism the issue proposed does not work, and that was measured
  rather than assumed.** `swift_task_enqueueMainExecutor_hook` is exported by
  every Linux toolchain this project supports (6.0.3, 6.2.0, 6.3.1) and a C
  shim writes it successfully — the global reads back non-null — and it is
  **never called**, on any of the three. A main-executor hook also could not
  have fixed `DispatchQueue.main.async`, which an app is just as likely to use.

  **The trap, for anyone touching this again:** on Linux and Android the handle
  is a *level-triggered* eventfd, so a watch that only drains the queue spins —
  2,900,705 loop iterations and 100% CPU in 2 s, measured. It has to be `read`
  first, *before* draining, so work enqueued mid-drain re-signals instead of
  being lost. Windows' handle is an auto-reset event and has no such failure
  mode.

  Verified by driving a scaffolded app — not an Example, which carries
  fallbacks the scaffold never emits — through four commands: a `@MainActor`
  class method, `MainActor.run`, `DispatchQueue.main.async`, and a nonisolated
  control that must answer either way. Run in **both** directions on GTK3,
  GTK4 and Windows: with the fix disabled the control answers in 2–3 ms and
  the other three never reply at all; with it in place all four answer in
  0–1 ms. `Scripts/verify-main-actor.sh` and
  `Scripts/verify-windows-main-actor.ps1` are the repeatable form.

  **Android is verified too**, on a Fold7 via
  `Scripts/verify-android-main-actor.sh`: all four probes answer in 1–3 ms,
  where before the fix the app's own main-actor code never returned. Getting a
  device run at all first needed the three Android build fixes below.

- **`SwiftPWACore` declares the `Crypto` dependency it has always used**, which
  is what made `build --target android` ship an APK that crashed at launch on
  Swift 6.4 (#217).

  `URLSessionNetworkClient` hashes a download with SHA-256 — CryptoKit on
  Apple, swift-crypto's `Crypto` everywhere else — and reached it through
  `canImport(Crypto)`. That succeeds whenever *any* target in the build graph
  has pulled the module in, so with a backend target declaring the edge the
  code compiled, and the classic SwiftPM build system linked the whole package
  as one so it ran too. The edge was simply missing from `Package.swift` for
  years, invisibly.

  Swift 6.4 makes `swiftbuild` the default engine, and it builds each product's
  link list from the **declared** edges. The app's `LinkFileList` came out with
  six objects and no `Crypto.o`. On Android that is silent twice over: the
  product is linked `-shared`, where undefined symbols are legal, so the build
  is green and the failure is `UnsatisfiedLinkError: cannot locate symbol
  "$s6Crypto0A8KitErrorON"` on the device.

  **Linux and Windows had the same defect** and had simply not reached 6.4 yet;
  so had CI, which pins 6.2 / 6.3.1 and takes whatever Xcode the macOS runner
  image ships.

  Two guards, because one bug that stays quiet for years deserves better than a
  fix. The Android build now links with **`-Xlinker --no-undefined`**, so a
  missing edge fails the build instead of the app — verified by removing the
  edge again and watching `ld.lld: error: undefined symbol` name the exact
  symbol. And `ManifestDependencyDriftTests` compares every target's imports
  against its declared dependencies straight from the manifest, which is the
  half that runs in CI, where there is no Android SDK and no device.

- **`build --target android` stages `libc++_shared.so` from the installed NDK**,
  and refuses to build an APK without it.

  Swift Android SDKs through 6.2 vendored an `ndk-sysroot/` inside the artifact
  bundle, and that is where the bundler took it from. The 6.4 bundle doesn't
  ship one — so the copy was silently skipped, the APK built and installed
  perfectly, and the app died at `System.loadLibrary` with `UnsatisfiedLinkError:
  dlopen failed: library "libc++_shared.so" not found`. Every Swift runtime `.so`
  needs it, so there is no app for which skipping it is right; it now falls back
  to the NDK the cross-compile is already using, and a miss is a hard error
  naming every path it looked in.

- **`build --target android` finds the matching toolchain again after the SDK
  bundle was renamed.** It keyed off `swift-<v>-RELEASE-android-…`; from 6.4 the
  bundle is `swift-6.4.0-RELEASE_android` — an underscore, no trailing revision,
  and a patch component in the version. The auto-select matched nothing,
  silently, so the cross-build ran under whatever `swift` was ambient (Xcode's,
  which is a *different build* from the swift.org release of the same number and
  cannot load the SDK's prebuilt modules) and failed with "module compiled with
  Swift X cannot be imported". Both spellings are matched now, a `major.minor`
  SDK also matches a `major.minor.patch` toolchain directory, and an Android
  bundle whose name can't be parsed says so instead of saying nothing.

- **`build --target android` uses the ambient toolchain when it already matches
  the Swift Android SDK**, instead of insisting on swiftly.

  The cross-compile has to run under the SDK's exact Swift release, and a repo
  `.swift-version` can pin a different one, so it wrapped the inner build in
  `swiftly run +<major.minor>`. That assumed swiftly could serve any release
  the SDK named. It can't: when the matching toolchain is one swiftly doesn't
  manage, `swiftly run` refuses outright — "the selected toolchain didn't match
  any of the installed toolchains" — rather than falling back, and the build
  fails with "could not produce a native library for the requested ABI". This
  is the ordinary case right after an Xcode release, when Xcode's Swift is
  ahead of everything swiftly has.

  `swift --version` already reflects any `.swift-version` pinning, since that
  is what swiftly's shim acts on — so reading it says which toolchain the build
  would really use, and when that already matches the SDK there is nothing to
  override.

- **Android serves the web bundle at the origin root**, so a page's
  root-absolute URLs resolve there the way they already did on the other four
  backends (#212).

  Android navigated to `https://swift-pwa.local/web/<entry>` and mapped
  `/<path>` onto `assets/<path>`, which put the bundle one directory below the
  origin. Every root-absolute URL a page contains therefore missed on Android
  and nowhere else: `/styles/tokens.css`, `/js/app.js`, `import('/vendor/…')`,
  `location.replace('/reader.html?id=…')`. The reporting adopter's app lost
  eight resources on load and rendered as an unstyled shell, with
  `Error opening asset path:` in logcat as the only clue.

  The root cause is small and worth recording, because it looks like a
  deliberate choice and wasn't: `AssetsPathHandler`'s public constructor takes
  only a `Context` — there is no base-path argument — so the `web/` prefix had
  to go somewhere, and it went into the URL. It belongs in a handler instead. A
  `WebBundlePathHandler` now prefixes `web/` and delegates to the stock handler,
  keeping its MIME guessing, its containment check and its not-found shape.

  This is a **parity fix, not a new capability**: `docs/swift-api.md` and the
  content-packs design doc already told adopters that an origin-relative URL
  works unchanged on every backend, and `build.serve` mounts already did. The
  bundle itself was the one thing that broke the rule, and relative URLs were a
  workaround nothing else in swift-pwa asks for — with no spelling at all for a
  `location.replace('/reader.html')` called from a nested route.

  Device-verified on a Fold7: a root-absolute stylesheet, script, `fetch`,
  dynamic `import` and `location.replace` all resolve; a missing asset still
  404s honestly; a `build.serve` mount still serves ahead of the bundle; and
  SPA history routing still loads the entry for `/library/shelf/42` — with that
  entry's own root-absolute script resolving from the nested route, which is the
  case relative URLs cannot express.

[Unreleased]: https://github.com/tophatch/swift-pwa/compare/v0.10.7...HEAD

## [0.10.7] - 2026-09-14

### Added

- **`swift-pwa drive --background`: a driven run that stays off the screen**
  ([#208]). A suite launches one app per test file — the reporting adopter's is
  37 of them — and every launch came to the front and took focus, so a full run
  was minutes during which the machine couldn't be used for anything else. The
  driver's whole premise is that a run needn't own the machine (input goes into
  the app's own event queue, screenshots come from the engine's own
  compositor); the window coming forward was the last thing contradicting it.

  **Hiding the window is the obvious fix and it doesn't work**, which is why
  this needed more than a flag: an engine stops servicing
  `requestAnimationFrame` for a window that isn't on screen, so a page that
  draws in a rAF callback silently does nothing and neither it nor the driver
  fails — it reads as the feature being broken. So the mode *parks a real
  window* rather than hiding one, on each of the three backends that can:

  - **macOS**: `.accessory` policy, no `NSApp.activate`, the window ordered in
    and parked far off screen — which needs `constrainFrameRect(_:to:)`
    overridden, because AppKit otherwise drags a titled window back to the
    screen edge at order-front (measured: the parked frame reads back correctly
    right up until the window is shown) — and
    `-[WKWebView _setWindowOcclusionDetectionEnabled:]` off.
  - **Linux GTK3**: `focus-on-map` off, moved off screen *again after mapping*
    (a window manager places a window as it sees fit when it maps, and xfwm4
    put a backgrounded one back at (0, 0)), kept below, out of the taskbar and
    pager.
  - **Windows**: created off screen with `WS_EX_TOOLWINDOW`, shown with
    `SW_SHOWNOACTIVATE`.

  **Only macOS needed private API**, which the measurements are what
  established: WebKitGTK doesn't throttle an off-screen window at all — 83 fps
  parked at (-32000, -32000) under a real window manager, against **0 fps and
  `document.visibilityState === "hidden"`** once *iconified* — and neither does
  WebView2. On macOS 26.6.2 a window parked off screen serves **0** rAF
  callbacks per second, **0–17** covered, and **63** with occlusion detection
  off in any of those positions. Two further macOS results shaped the design:
  **key and active are irrelevant** (a window that never becomes key, in an app
  that never activates, runs at full rate — so the focus theft and the frame
  throttling read as one problem and are two), and **`orderOut` is not
  occlusion** (0 fps even with detection off, and no SPI covers it).

  Verified per backend by driving a real app: macOS 60 fps with the frontmost
  application unchanged and the window at (-32000, -32000), `drive click` and
  `drive type` still landing, and a screenshot of *live* content; GTK3 122 fps
  with the active window unchanged, under a real window manager, with a
  normally-launched app as the control; Windows 128 fps with the foreground
  window unchanged. `window.focus` stops raising the app on all three, because
  a page that polls it until `!document.hidden` wants rendering, not the user's
  screen.

  **GTK4 refuses rather than pretending.** It dropped window positioning
  outright, so there is nowhere off screen to put the window; it says so on
  stderr and points at a nested display, which is invisible *and* unthrottled
  (measured: 84 fps under `xvfb-run`). More generally the app reports what it
  actually did — `capabilities.background`, visible in `drive info` — and the
  CLI repeats it on stderr, so a backend that ignores the request can't look
  like a broken flag. iOS is refused outright: a backgrounded app there is a
  *suspended* app, and a verb sent to one doesn't fail, it queues and answers
  when the app comes forward.

  **A backgrounded run no longer writes the app's remembered window geometry.**
  A suite that resizes the window for a responsive check would otherwise
  persist that size into `window-state.json` — measured, the user's app then
  opens at 500×368 because of a test they'd long since forgotten. Deliberately
  not every driven run: a driven window that's on screen is still a real window
  at a plausible size, and a suite may legitimately be testing `rememberState`
  itself.

  Off by default and driver-only — `DriverBackground.isRequested` answers
  `false` unless the driver is compiled in at all, so the environment variable
  can't reshape a shipped app's windows. The macOS mechanism rests on private
  API, so a missing selector degrades to a **visible** run plus a line on
  stderr rather than an invisible one whose page never paints, and a unit test
  pins the selector so we hear about it before an adopter does.

- **Windows reports the calling frame, and stops embedded content reaching the
  app's commands at all** ([#204]). `CommandContext.frame` is `.main` on
  Windows now rather than `.unknown`, so the `external_urls.allow_any_scheme`
  opt-out covers the app's own page there as it does on Apple.

  **The measurement inverted the issue's assumption.** #204 expected the answer
  to come from `ICoreWebView2WebMessageReceivedEventArgs::get_Source` and
  expected it to be imprecise, since a same-origin iframe reports a URI
  indistinguishable from its parent's. Measured on a real box, WebView2 doesn't
  route embedded frames through that event *at all*: their `postMessage` is
  raised on the frame's own `ICoreWebView2Frame2::WebMessageReceived`, which
  nothing was subscribed to — so on Windows an embedded frame had never been
  able to reach the bridge, and the top-level event only ever fires for the
  window's own document. Which event fired is therefore the whole answer, and a
  structural one: verified against an iframe loaded from *its parent's own
  URL*, the case no comparison of URIs can decide.

  **That silence is what changed.** WebView2 drops a message from a frame
  nobody subscribed to without a word anywhere, so an app whose own iframe
  called `invoke` saw it work on the other four backends and do nothing here,
  with no way to find out why. The frames are subscribed now purely so the
  refusal can be *explained*: one diagnostic naming the frame's document, the
  command it tried, and the way round it (have the top-level document call on
  the frame's behalf). Embedded content still reaches nothing — this is the
  safest of the five backends and stays that way — but it now says so.
  `FrameCreated` on the webview reports only first-level frames (measured: a
  grandchild whose document had loaded and run was never announced), so each
  frame's own `ICoreWebView2Frame7::FrameCreated` is subscribed too and the
  refusal reaches every nesting depth.

  New `Scripts/verify-windows-frame-identity.ps1` drives all of it on a real
  box, checking the app's *diagnostics* as well as its commands — a refusal
  nobody is told about is the failure this guards, and absence alone can't tell
  it from a frame that never loaded.

- **Android reports the calling frame too, and a cross-origin frame no longer
  reaches the bridge behind `bridge.js`'s back** ([#204]). The inbound channel
  moves from `addJavascriptInterface`, which reports nothing about the caller,
  to `WebViewCompat.addWebMessageListener`, which carries `isMainFrame` and the
  sending document's origin. `bridge.js` needed no change: the object that API
  injects has the same `postMessage(String)` shape it already calls.

  The channel also takes **origin rules**, where `addJavascriptInterface`
  injects into every frame regardless of origin. `bridge.js` was already scoped
  to the app's origin by `addDocumentStartJavaScript`, but `__SwiftPWA__post`
  was not — so a cross-origin iframe could reach it directly and post a raw
  envelope without `bridge.js` ever running in that frame. Both are scoped to
  the same origin now.

  Unlike Windows, embedded frames still *reach* the bridge on Android and are
  reported rather than refused: they always could, and narrowing that is the
  app's call through `ctx.frame` (or a decision to make across all five at
  once, which this isn't). The `addJavascriptInterface` path stays as a
  fallback for a System WebView with no `WEB_MESSAGE_LISTENER` — reporting
  `.unknown`, which the JNI ABI carries as a genuine third state rather than
  defaulting to "main", since an app narrowing a permission must not read "I
  can't tell" as "the app's own page". New
  `Scripts/verify-android-frame-identity.sh` drives it on a real device.

- **Embedded content can no longer reach the app's commands: `bridge.js` is
  injected into the top frame only** ([#204]). It went into *every* frame on
  Apple (`forMainFrameOnly: false`) and Linux
  (`WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES`), so a cross-origin `<iframe>` — an
  ad, a map, a third-party widget — could invoke every command the app
  registered, with the same arguments the app's own code would use. With no
  opt-in plugin installed that already reaches `window.close`, `app.quit` and
  **`events.emit`**, which forges the app's own internal bus in a way a
  subscriber cannot distinguish from a real emit; with `FsPlugin`,
  `ProcessPlugin` or `SecretsPlugin` installed it reaches file writes, process
  spawning and secret storage. Replies never reach the frame, so this was
  side effects rather than exfiltration — which is not much comfort when the
  side effect is `fs.delete`.

  **Scoping the injection rather than checking the caller, because only the
  former works everywhere.** Both GTK backends genuinely cannot report which
  frame sent a script message, so a check above the adapter could never have
  stood in the way there; injection scope is enforced by the webview itself.
  Nothing legitimate is lost: a *same-origin* frame is the same trust domain and
  still reaches the bridge through `window.parent.__SWIFT_PWA__` — already the
  documented pattern, already where the reply was delivered, and correctly
  attributed to the parent — while a cross-origin frame cannot touch the
  parent's object at all. **Migration:** an app whose own same-origin iframe
  calls `__SWIFT_PWA__` directly changes that one reference to
  `window.parent.__SWIFT_PWA__`.

  `CommandContext.frame` is now the *report* rather than the barrier: it still
  distinguishes a same-origin frame on Android, whose channel is scoped by
  origin instead of by frame, and it is what `allow_any_scheme` narrows itself
  with.

### Fixed

- **Windows: a window moved to a negative coordinate killed the app** ([#208]).
  `WM_MOVE` packs its coordinates as *signed* 16-bit words; the handler read
  them unsigned, out of an `Int32(lParam)` conversion that **trapped** for any
  packed value with the high bit set. A window moved to (-32000, -32000) packs
  to 0x8300_8300 — past `Int32.max` as the `LPARAM` really is — and the app
  died in `Integers.swift: Not enough bits to represent the passed value`
  inside its own window procedure, with no line of swift-pwa's own code in the
  trace.

  Found by parking a window off screen for a backgrounded driven run, but the
  case that meets it in ordinary use is **a second monitor placed left of or
  above the primary one**, where window coordinates are negative: before the
  fix a window there reported the wrong position (-100 read back as 65436) and
  crashed outright once the packed value went negative. Verified on a real box:
  a move to (-1200, -900) now leaves the app alive and reads back as
  (-1200, -900).

- **Documented the limit of what `CommandContext.frame` can defend** ([#204]).
  A **same-origin** frame can call the parent's bridge object
  (`window.parent.__SWIFT_PWA__.invoke(...)`), which posts from the parent's
  frame — so the runtime sees `.main`, correctly, and the scoping is bypassed in
  one line. Measured against a real `WKWebView`, not reasoned about. It is
  inherent to the same-origin policy rather than a hole (such a frame can
  already drive the parent's DOM), but it decides what the feature is *for*:
  `ctx.frame` separates the app's page from **cross-origin** embedded content,
  and must not be used to sandbox same-origin content the app doesn't trust —
  give that its own origin first. Now stated in `docs/swift-api.md` and pinned
  by a test, because the wrong reading of this is the one that would ship a
  vulnerability while looking careful.

- **`allowAnyScheme`'s own documentation still described the world before frame
  identity existed** ([#204], reported by the adopter from [#203]). The property
  said the runtime "cannot currently tell a subframe's invoke from the main
  frame's, on any backend", twenty lines above the code that refuses
  `.subframe` — and it reversed the real advice on the platforms where the
  scoping already worked. It was wrong the moment #206 landed, and this release
  would have made it wrong twice over.

  Fixed as suggested: the per-backend picture lives in **one** table (in
  `docs/javascript-api.md`) and the property points at it instead of restating
  it, so wiring the next backend can't silently invalidate a second copy. The
  half that doesn't change with the backend — that the flag is for apps which
  don't host other people's content, and that it softens nothing else — stays
  inline where it is read. The same duplicate-restatement was removed from
  `docs/linux-setup.md`, which named Apple as the only backend that could report
  a frame.

- **An embedded frame could cancel the app's in-flight work** ([#204]). `hello`
  is the frame that hands a window to a new document, and taking it tears down
  everything the previous one subscribed. `bridge.js` sends it only from the
  top frame — but that test is `window.top === window`, evaluated *inside* the
  frame making the claim, so an embedded frame posting a forged envelope could
  cancel every open subscription in the window. `BridgeRuntime` now refuses a
  `hello` from a known subframe, which is the first thing `CommandContext.frame`
  is used for beyond a policy input. Backends that can't report the frame are
  unaffected: `.unknown` still adopts, or they would never adopt a document at
  all.

## [0.10.6] - 2026-09-13

### Added

- **`CommandContext.frame` — a handler can tell the app's own page from an
  `<iframe>` it embedded** ([#204]). `bridge.js` is injected into every frame,
  so embedded content reaches the same commands as the app's own code; until
  now nothing above a webview adapter could see the difference. Apple reports
  it from `WKScriptMessage.frameInfo` (`.main` / `.subframe(origin:)`), and the
  first consumer is `external_urls.allow_any_scheme`, which now covers the
  app's own page while an embedded frame keeps the declared allowlist.

  **Not self-reported, deliberately.** `bridge.js` could send
  `window.top === window` in the envelope — one line, looks like the same
  answer — but the frame this identifies is content we don't trust, and it
  would simply lie. Only the backend, which sits outside the web content, can
  answer it.

  **`.unknown` is a real answer**, not a stub: measured on both boxes, the GTK
  UI process genuinely isn't told. WebKitGTK's `script-message-received`
  carries only the message value, and `WebKitFrame` is guarded to the
  web-process extension API in both 4.1 and 6.0, so reaching it means shipping
  a second `.so` into WebKit's web process. Where the frame is unknown,
  `allow_any_scheme` keeps its broader meaning rather than silently doing
  nothing — an app would otherwise find its links working on some platforms and
  refused on others with no diagnostic explaining why. Documented in
  [`docs/linux-setup.md`](docs/linux-setup.md)'s Known limitations; Windows and
  Android can report it and aren't wired yet ([#204] stays open for both).

  Worth restating, because it decides what the scoping is *for*: an embedded
  frame's reply never reaches it. `deliver` evaluates into the main frame, so
  its correlation id belongs to a bridge instance that never sees the answer —
  already documented in [`docs/javascript-api.md`](docs/javascript-api.md) as
  "don't drive the bridge from an iframe", but stated there as advice to the app
  author. Read as a security property it means an embedded frame can *cause* any
  registered command to run while reading nothing back, so side effects — not
  data — are the reach worth narrowing.

  The seam is `PWAWebView.inboundFrames()` → **`inboundMessages()`**, carrying
  an `InboundMessage` (frame + caller frame). A **source break for an
  out-of-tree backend**; all five in-tree adapters and the test mock are
  updated, and `MockWebView.send` defaults to `.main` so a test that means "an
  embedded frame said this" has to say so.

- **`external_urls.allow_any_scheme` — accept the OS's routing instead of an
  allowlist** ([#203]). `external_urls.schemes` is an exact set-membership test,
  which assumes the app can enumerate its schemes at build time. An app that
  renders links from *user-authored* text can't: the list is "whatever that
  person has installed", so the declaration is a guess, and the eleventh app
  they own is refused with `E_URL_SCHEME` — indistinguishable, from where they
  sit, from the app not being installed, and fixable only by a rebuild. The
  reporting adopter had shipped ten schemes and was still guessing.

  The flag is opt-in and off by default, because the allowlist's reasoning still
  holds for the apps it was written for: `bridge.js` is injected into subframes,
  so a third-party `<iframe>` can invoke commands. It moves exactly one step of
  `ExternalURLPolicy.decide` and leaves the refusals either side of it — `pwa:`,
  `file:`, `about:`, `javascript:`, `data:`, `blob:`, and the app's own
  registered origin, which is what catches `https://swift-pwa.local` on Windows
  and Android. Those are what the tests pin, rather than the happy path.

  **It means any scheme from any frame, and the docs say so**, because the
  runtime cannot currently tell a subframe's `invoke` from the main frame's on
  any backend — `WKWebViewAdapter` drops `message.frameInfo`, and the other four
  never carried it. The sharp version of this feature (allowlist for third-party
  frames, OS routing for the app's own) needs frame identity plumbed into
  `CommandContext` the way `caller` was in #170; filed separately rather than
  smuggled in here.

  Spelled as its own key rather than `"*"` in the schemes list: every other
  `pwa.json` key maps 1:1 onto a Swift property (`ctx.externalURLs.allowAnyScheme`),
  the scheme validator keeps its single invariant instead of special-casing a
  value that inverts the list's meaning, and a named switch is visible when
  someone reviews a manifest where one entry among ten isn't.

[#203]: https://github.com/tophatch/swift-pwa/issues/203
[#204]: https://github.com/tophatch/swift-pwa/issues/204
[#208]: https://github.com/tophatch/swift-pwa/issues/208

## [0.10.5] - 2026-09-12

### Fixed

- **The prebuilt Linux CLI runs on a machine that has nothing installed**
  ([#199]). The first command a new user ran died in the dynamic loader —
  `libswiftCore.so: cannot open shared object file` — before `main`, so
  `swift-pwa doctor`, the tool whose whole job is explaining a missing
  prerequisite, could never execute to say so. Having Swift installed didn't
  help: a swiftly-managed toolchain keeps its runtime inside the toolchain
  directory, off the loader's path. Found by running the published v0.10.4
  binaries; v0.10.3 and every earlier Linux asset fail identically.

  Two changes, because the first one alone left the same failure one library
  later. The release binary is now built `--static-swift-stdlib` and stripped
  (~66 MB, against 32 MB dynamic — a Swift crash backtrace loses its symbol
  names, which is the right trade for a build tool). And **`CSecretShim`
  `dlopen`s libsecret instead of linking it**, which is what removes
  `libsecret-1.so.0` and the glib trio from the binary's `DT_NEEDED` list:
  measured with libsecret masked out, the statically-linked build still
  refused to start. The `swift-pwa` CLI never touches a keyring, and neither
  does an app that doesn't register `SecretsPlugin`, but both used to require
  the library to be installed merely to *start*.

  Same move as `CHeifShim`, with the same knock-on: **`libsecret-1-dev` is no
  longer a Linux build prerequisite** — dropped from five CI apt lists and the
  setup docs. The hand-transcribed ABI is pinned by
  `Scripts/verify-libsecret-abi.sh`, which `static_assert`s every struct size,
  field offset and enum value against libsecret's real headers, because getting
  it wrong would surface as a lookup that quietly finds nothing rather than as
  a compile error.

  `LinuxSecretStore` now also distinguishes **"libsecret isn't installed"** from
  **"no Secret Service is running"** in the thrown message. They have different
  fixes, and `dlopen` makes the first one a state an app can actually be in.

  Verified on a real box: the stripped static binary runs under `env -i` and
  with libsecret and glib masked out; `doctor` executes and correctly reports
  the missing Swift toolchain; and the live `set → get → overwrite → delete`
  round-trip passes against a real GNOME Keyring through the dlopen path. A new
  release-workflow step runs the built Linux binary under `env -i` and fails the
  job if it can't, since nothing else here would notice.

[#199]: https://github.com/tophatch/swift-pwa/issues/199

## [0.10.4] - 2026-09-12

### Added

- **A physical iOS device can be driven (`swift-pwa drive --target ios`).**
  Until now a real iPhone or iPad was the one platform in the matrix where a
  behavioural claim couldn't be checked without a person holding the device —
  every `eval`, screenshot and layout check on iPadOS was done by hand, by two
  adopters and by us, while the simulator had the full loop. That's the wrong
  way round: a device is where the interesting failures are, and this project's
  own history is mostly bugs that only appeared on hardware ([#176]).

  It needed nothing from the driver. The app half has been in place since the
  driver shipped — `IOSSceneDelegate` starts the control socket like every
  other backend — so this is host-side plumbing only: `devicectl … launch -e`
  sets `SWIFT_PWA_DRIVE`, `--console` relays the app's stdout so the port and
  per-launch token can be read, and the socket is reached through **usbmuxd**.
  `drive` takes the same signing options as `build` and `deploy`, and
  `--attach` was already able to talk to whatever it was pointed at.

  The obvious route doesn't exist: `devicectl` has **no port-forwarding verb**,
  and no networking verb at all. usbmuxd is the mechanism — the host asks it to
  connect, and its counterpart inside the device dials `127.0.0.1:<port>`
  locally, which is the only way to reach a loopback listener from outside.
  Speaking its property-list protocol directly costs about a hundred lines and
  keeps this dependency-free; the alternative was vendoring libimobiledevice
  for one message type.

  Two limits, both measured rather than assumed, and both documented because
  neither announces itself. **A cable is required**: only usbmuxd's USB
  transport dials the device's loopback, so a Wi-Fi-paired device installs and
  launches perfectly well and then can't be driven (and a charge-only USB-C
  cable presents exactly like no cable). **The app must stay frontmost**: iOS
  suspends a backgrounded app, and a verb sent to a suspended one *doesn't
  fail* — the TCP connection still completes from the kernel's listen backlog,
  the request queues, and it answers when the app comes forward. Measured at
  60+ seconds of apparent hang that resolved the instant the app was
  foregrounded. That inverts the desktop behaviour, where driving an occluded
  window is the whole point. Synthetic input stays refused on iOS, exactly as
  on the simulator — there is no public event-synthesis API.

  Verified end to end on a physical iPad: `info`, `eval` and `shot` (a 2816×1940
  capture off the device's own renderer) through the full build → install →
  launch → forward → drive → teardown loop.

- **A command handler can tell a page from an agent (`CommandContext.caller`).**
  It previously could not: the only difference visible to a handler was that an
  agent call passed `originWindow: nil`, which is a consequence of the agent
  path having no window rather than a contract — and it fails in the dangerous
  direction. Give agent calls a window id one day and every guard built on that
  check silently stops filtering, with no error and no warning: a tool that was
  scoped is now unscoped. `caller` is `.page(WindowID)` or `.agent`, switched on
  exhaustively, so a new caller kind is a compile error in the app rather than a
  filter that quietly stopped working ([#170]).

  It matters because the `agent.expose` allowlist is per *command* while the
  interesting cases are per *call*: the reporting adopter wanted content the
  user had locked kept out of the six read-only tools their app exposes — the
  same `stories.list` an agent may call, answering with less. Without a
  dependable signal they left the tools alone and wrote the gap down instead.
  The alternative shape, a parallel set of `*.forAgent` commands, is worse in
  every way.

  `originWindow` stays as a computed property over `caller`, so window-targeting
  commands are unchanged and can't drift from it. There is deliberately **no
  `.driver` case**, despite the issue proposing one: `swift-pwa drive eval` runs
  its JavaScript inside the page and arrives through the page's own message
  handler with the page's window id, so a driven call is not distinguishable
  here — a case that can never be constructed would read like a filter that
  works. The old `init(invocation:originWindow:appContext:)` is kept and
  deprecated for source compatibility.

- **`swift-pwa drive drag` — press, move along a path, release.** `drive` could
  click, type and scroll but had no press-move-release verb, so anything driven
  by a drag was unreachable; the reporting adopter was exercising a sheet
  gesture with synthesized `PointerEvent`s through `drive eval` instead, which
  tests the page's handlers and not the path the OS actually delivers. That is
  the same distinction that hid the `key: "Dead"` bug for two releases —
  `eval`-dispatched events looked identical while real ones were wrong ([#175]).

  **The moves in between are the feature.** A press and a release at two points
  drives no momentum, inertia or rubber-banding — most of what a drag gesture is
  for — so the verb interpolates a path and paces it over `--duration` in real
  elapsed time. `--to` repeats, so a multi-segment gesture is one command
  (`--from 20,20 --to 200,20 --to 200,200`), and steps are spread by *distance*
  rather than one share per segment, so an L-shaped drag doesn't crawl along its
  short leg and jump along its long one. Endpoints can be `--from-selector` /
  `--to-selector`, which survive a layout change. Also served to agents as the
  `app_drag` MCP tool.

  Pacing is to a deadline rather than a sleep between sends: every move is a
  synchronous round trip to the app, so adding a fixed sleep to each one
  overshoots — measured at roughly 2x on a local macOS app, which a page
  computing velocity reads as a slower gesture than the one requested. Where the
  round trips genuinely can't keep up, the verb says so instead of reporting the
  duration it was asked for.

- **Synthetic input on Windows, over the DevTools protocol.** WebView2's own
  `SendPointerInput` lives on `ICoreWebView2CompositionController` and swift-pwa
  creates a *windowed* controller, so this backend reported no input at all and
  every keyboard, pointer and wheel verb was refused on it. The obvious fix —
  `SendInput` / `keybd_event` — would have cost the property the whole driver is
  built on, since OS-level injection moves the real cursor, needs the window
  foreground, and makes the machine unusable while a run is in progress.

  `CallDevToolsProtocolMethod` is on the base `ICoreWebView2`, well below the
  SDK version this project already requires, and CDP's `Input.dispatchKeyEvent`
  / `Input.dispatchMouseEvent` inject at the *browser* level: trusted events,
  hit testing, focus, default actions, nothing near the OS input queue, and a
  backgrounded window drives correctly. The same mechanism Puppeteer and
  Playwright drive Chromium with. Windows therefore keeps the same
  "needn't be frontmost" guarantee as macOS and GTK3 ([#164]).

- **Synthetic input on GTK4, over XTEST — and a capability field that says how
  it differs.** GTK4 removed event synthesis outright: `GdkEvent` is opaque with
  no public constructors and `gtk_main_do_event` is gone, so
  `gdk_display_put_event` survives with nothing to hand it, and WebKitGTK
  exposes no injection API of its own. The X server's test extension is what is
  left, and it is a genuinely weaker guarantee — events enter at the *server*,
  so the window must hold input focus, the real pointer moves, and it reaches
  X11 and XWayland clients only. Under Xvfb, where CI runs and nothing competes
  for focus, none of that costs anything, and it is the only way the GTK4
  backend's keyboard behaviour can be checked by anything but a person.

  Rather than report that as a plain `true`, `InputCapabilities` gains
  **`delivery`** (`appQueue` / `displayServer`), surfaced by `drive info`, so a
  harness can branch on it instead of writing a test that works on one machine
  and fails on another for reasons nothing reports. libXtst is `dlopen`ed rather
  than linked — it is not a GTK dependency, and a box without it reports no
  input support instead of failing to link the whole Linux backend.

- **`Scripts/verify-driven-input.sh` (and a `.ps1` sibling for Windows, which
  has no bash) — the editing and drag checks, as a script rather than a
  paragraph in a PR.** Every keyboard fix in [#163] was verified by
  hand on real hardware while CI only compiled the backends, so all of them could
  regress silently. This drives a real app through select-all / cut / type /
  paste, type → undo → redo, a page that claims the undo key with
  `preventDefault` keeping it, typing into a freshly focused field, and a
  multi-segment drag ([#164]).

  It is written around the two traps that make such a run green while proving
  nothing. The obvious editing sequence **round-trips to its own starting
  state**, which is equally consistent with everything working and with only
  select-all working — so every step here leaves a *distinct* value. And a quiet
  environment is not a passing test: a locked macOS screen has no key window and
  an SSH shell has no interactive desktop, in which every shortcut fails exactly
  as a broken fix would. So the script leads with a control keystroke that must
  land, adds a second control on macOS for whether the app can become active at
  all (menu key equivalents need a key window, and plain typing doesn't — so the
  first control can't tell the two apart), and **skips** rather than passes the
  checks a backend or session genuinely can't run.

  The Windows script also handles the session-0 problem on its own: an SSH shell
  there has no interactive desktop, WebView2 refuses to create a controller, and
  every page-dependent verb times out behind `0x80070578`. It launches the app
  into the active console session with a scheduled task and attaches over
  loopback, which crosses the session boundary fine.

  Run on demand or weekly by a new opt-in `driven-input` CI job (Linux, under
  Xvfb — the one hosted environment that can do this; a macOS runner has no
  logged-in desktop, so it would correctly skip every menu shortcut).

  **Found while writing it: the clipboard is the one thing the driver can't
  reach on Windows.** A driven `Ctrl+X` runs the edit — the field empties — but
  nothing lands on the system clipboard, so the following `Ctrl+V` restores
  nothing. Chromium runs clipboard commands in the browser process off a native
  key event while the DevTools protocol dispatches into the renderer. A real
  user's `Ctrl+C` works; only driving it doesn't, so the check is reported as a
  skip with that reason rather than folded into the editing assertion, where one
  platform's driver limitation would have looked like an editing regression on
  all of them.

[#176]: https://github.com/tophatch/swift-pwa/issues/176
[#193]: https://github.com/tophatch/swift-pwa/issues/193
[#170]: https://github.com/tophatch/swift-pwa/issues/170
[#175]: https://github.com/tophatch/swift-pwa/issues/175
[#164]: https://github.com/tophatch/swift-pwa/issues/164
[#163]: https://github.com/tophatch/swift-pwa/issues/163

- **`app.openURL` — a deep link the OS routes to the app reaches the page.**
  The outbound half shipped first, which left the capability half-built: an app
  could *send* a `myapp://…` link but had nowhere to *receive* one. A URL the OS
  delivered reached `NSApplicationDelegate.application(_:open:)` and was then
  dropped by `urls.filter(\.isFileURL)` — right for `app.openFile`, which is
  about documents, but a custom-scheme URL has no path to put on that channel
  and had no channel of its own. Measured before the fix: `system.openURL` on a
  registered scheme reported `{ opened: true }` (the OS accepted and routed it)
  while the page's `app.openFile` handler never fired. Never worked, not a
  regression ([#177]).

  An arriving URL is now emitted on its own `app.openURL` event channel,
  **retained** the way `app.openFile` is — a link far more often *launches* the
  app than reaches a running one, so the event fires before any listener exists
  and has to replay on subscribe. The payload is `{ url, urls }`: one OS event
  can carry several links, and retention keeps only a channel's latest value, so
  emitting them one apiece would have shown a late subscriber only the last.
  `url` is the first, which is the case a router actually has.

  A separate channel from `app.openFile` on purpose — a path to read and a URL
  to route are different payloads, and an app that handles documents shouldn't
  start receiving deep links it never declared. A `file:` URL counts as a
  document and keeps going to `app.openFile`, including its macOS
  security-scoped grant.

- **`url_schemes` — one declaration, five platform artifacts.** The receiving
  end needs the OS to know the app handles the scheme, and that registration
  lives in a different file on every platform. Unlike `document_types` there is
  one top-level list, because a URL scheme is the same string everywhere where a
  file type is a MIME type on Linux/Android and an extension on Windows.
  `swift-pwa build` generates Apple `CFBundleURLTypes`, an Android
  `ACTION_VIEW` intent-filter with `DEFAULT` + **`BROWSABLE`** (without which a
  link tapped in a browser or mail client silently doesn't match — the only
  place deep links come from), a `.desktop` `x-scheme-handler/…` MIME entry with
  the `%U` field code, and an MSIX `windows.protocol` extension — or, for the
  portable Windows exe, a `register-url-schemes.cmd` the user runs once, next to
  the existing file-type pair rather than folded into it.

  **Deliberately a separate list from `external_urls.schemes`**: that one is
  what the app may *open*. Handling a scheme and being allowed to launch one are
  different permissions and most apps want only one of them, so neither implies
  the other. A system-owned scheme (`https`, `mailto`, `file`, `pwa`, …) is
  refused at build time with the reason — claiming `https` would put the app in
  the browser chooser, and making `https://` links open an app is universal-link
  / App-Link verification, which needs a signed file served from the domain and
  isn't something a build tool can generate.

  One knock-on worth knowing on Linux: `%U` supersedes `%F` when an app declares
  both a scheme and document types, because a field code is singular and `%U` is
  the general one. The desktop then hands *local files* over as `file:///…`
  URIs, so the launch-argument scan accepts a `file:` URL as a path.

- **`system.openURL` — a page can open a URL outside the app.** There was no
  way to do it at all, and all three of the routes a web developer reaches for
  failed differently: an `<a href="https://…">` **loaded in place and stranded
  the app** (measured — the window has no address bar and no back button, and
  `drive eval` then reports `E_EVAL_LOST: the page navigated`), `window.open`
  returned `null`, and a scheme WebKit can't load was handed to the system on
  **iOS only**, doing nothing at all on macOS. So deep links worked on a phone
  by accident of what WebKit refuses, and web links worked nowhere. Reported by
  an adopter whose workaround was to render links with no `href` and **copy an
  `http` URL to the clipboard**, because opening it would have destroyed the
  app.

  The command returns `{ opened }` rather than throwing when nothing handles
  the URL — a deep link into an app the user may not have installed is a
  question the page can act on, not a failure — and refuses with `E_URL` for a
  URL the system can't be asked to open (`pwa:`, `file:`, `javascript:`,
  unparseable). `NSWorkspace` on macOS, `UIApplication` on iOS; the other three
  backends register the command and answer `E_UNIMPLEMENTED`, so a page
  feature-detects on the code rather than on the platform ([#167]).

- **Off-origin navigation goes to the system browser instead of stranding the
  app** — the other half of the same problem, and the one an app can't work
  around, because any link in content it didn't write is a trapdoor. A
  main-frame navigation that leaves the window's own origin is cancelled and
  handed to the OS. Subframes, same-origin navigation (including a router
  doing a real page load) and `about:` / `blob:` / `data:` URLs are untouched,
  and a window created on `WindowContent.remote` counts **its own site** as the
  app, so a wrapper around a web app still navigates that site freely. Opt out
  with `"external_urls": { "off_origin_navigation": "in-app" }` ([#166]).

- **`alert()`, `confirm()` and `prompt()` work on macOS and iOS.** No backend
  set a `uiDelegate`, and `WKWebView` serves a JavaScript panel *only* through
  `WKUIDelegate` — so all three were dropped: measured at **0 ms** with nothing
  on screen. The absence wasn't the problem, the silence was: nothing threw,
  nothing warned, and a page can't feature-detect it (`typeof alert` is
  `"function"` and the call returns normally). The adopter who reported it had
  sixteen error paths reported that way and could read none of them; the one
  that cost real time was a failed biometric unlock on an iPad, which looked
  exactly like a tap that had missed. Now an `NSAlert` sheet / `UIAlertController`
  attached to the window that raised it — not app-modal, so one window's
  `confirm()` doesn't block another's — with the button and the entered text
  returned properly. A dialog raised by a **cross-origin subframe** names the
  origin that raised it, because `bridge.js` and the page's scripts run in
  subframes too and an iframe's `confirm()` otherwise reads as the app's own.
  Still unimplemented on Linux, Windows and Android, documented in each
  platform's "Known limitations" ([#165]).

  Getting this wrong is invisible, which is worth recording: `WKUIDelegate` and
  `WKNavigationDelegate` are almost entirely **optional Objective-C methods
  matched by selector**, and WebKit's headers mark these `WK_SWIFT_UI_ACTOR` /
  `WK_SWIFT_ASYNC`. A completion-handler signature whose closure isn't typed
  `@MainActor` compiles, conforms, and is **never called** — indistinguishable
  from having no delegate at all. The first draft here had exactly that, in four
  of five methods, and it was a `responds(to:)` test that caught it rather than
  the compiler; the shipped code uses the async spellings and that test pins
  every selector.

- **The same policy on Linux and Windows** — GTK3, GTK4 and WebView2 now hand
  an off-origin main-frame navigation to the desktop instead of loading it in
  place, and `system.openURL` works there (`g_app_info_launch_default_for_uri`,
  `ShellExecuteW`). The rule itself is unchanged: each backend translates
  `ExternalURLPolicy.navigationDisposition` into its own callback. Android is
  the remaining gap ([#166], [#167]).

  **The dialogs needed no work on either**, which is the opposite of what this
  was scoped as. The claim that all four non-Apple backends were inert came
  from grepping for handlers we don't install; measured, `alert()` **blocks the
  page** on WebKitGTK 4.1, WebKitGTK 6.0 and WebView2, because all three ship
  their own script dialogs when the embedder installs none. `WKWebView` is the
  outlier with no built-in panel at all — which is why the Apple gap existed
  and why nobody noticed it elsewhere. Android is still unmeasured ([#165]).

  **Linux needs two mechanisms where Windows needs one**, and the reason is
  worth recording: WebKitGTK's `decide-policy` carries **no frame
  information** — measured, a cross-origin `<iframe>`'s own load is
  indistinguishable from the main frame navigating away, with
  `webkit_navigation_action_get_frame_name()` NULL for both. Acting on every
  navigation decision would hand every embedded map or video to the browser,
  which is worse than the bug being fixed. So the GTK backend acts on
  *user-initiated* navigation decisions (link click, form submit, plus
  `window.open`) and catches the rest — a programmatic `location.href = …` —
  at the **response** decision, which does carry
  `is_main_frame_main_resource`. The cost is one request made before the
  cancel; the alternative is not catching it. WebView2 needs none of this:
  `NavigationStarting` is top-level by contract, with subframes on a separate
  event.

  Verified on real boxes rather than in CI, which builds these backends but
  never runs them: on both GTK boxes a new `SWIFT_PWA_LINUX_GUI`-gated test
  asserts that two cross-origin iframes still load, a link click and a JS
  redirect both leave the page where it was with the URL handed to the opener,
  and same-origin navigation still works. On an x64 Windows box the same
  behaviours were driven by hand, with Edge confirmed launching in the
  interactive session at each handoff.

[#166]: https://github.com/tophatch/swift-pwa/issues/166
[#167]: https://github.com/tophatch/swift-pwa/issues/167
[#177]: https://github.com/tophatch/swift-pwa/issues/177
[#173]: https://github.com/tophatch/swift-pwa/issues/173
[#174]: https://github.com/tophatch/swift-pwa/issues/174
[#187]: https://github.com/tophatch/swift-pwa/issues/187

- **`external_urls` in `pwa.json`, and `ctx.externalURLs` at runtime.** Opening
  a URL launches whatever app is registered for its scheme, and the page asking
  isn't always the app's own code — `bridge.js` is injected into subframes, so
  a third-party `<iframe>` can invoke commands, and a link in user-authored
  content is written by the user. So the gate has the shape `permissions` has:
  `http`, `https`, `mailto` and `tel` need no declaration (a link in a page
  means a document or a contact), and everything else — `things:`,
  `obsidian:`, a conferencing handler — is declared, with a refusal that logs a
  diagnostic naming the exact fix. `swift-pwa build` rejects a scheme that
  can't be one (`"https://example.com"` in the list declares nothing useful)
  and an unspelled `off_origin_navigation`, before anything is built.

  The rule itself lives in Core — `ExternalURLPolicy.navigationDisposition(for:appOrigin:isMainFrame:)`
  answers `allowInApp` / `openExternally` / `block` — so the four remaining
  backends need the translation into their own callback and not the reasoning,
  and it is unit-tested without a webview.

- **`allowDeviceCredential` on both `biometric.*` commands.** A biometric lock
  the app puts on the user's own content could become **un-openable**:
  `SystemBiometricAuth` evaluated `.deviceOwnerAuthenticationWithBiometrics`,
  which is biometrics or nothing, so a Mac that had Touch ID when the lock was
  set and has since had the enrolment removed has no way back in.
  `canAuthenticate` reported the situation honestly, which let an app refuse to
  *offer* a lock but not open one already there. The flag widens the policy to
  the account password / device passcode / PIN / pattern — what Notes, Files
  and Photos all use for exactly this — and defaults to `false`, so nothing
  changes for existing callers.

  It is on `canAuthenticate` **as well**, because the advisory answer has to be
  policy-specific: asking the biometrics-only question and then running the
  wider one is how an app ends up hiding a feature that would have worked. Per
  backend: Apple swaps `LAPolicy`; Android requests
  `BIOMETRIC_WEAK | DEVICE_CREDENTIAL` (the one combination androidx supports
  at every API level this targets — `BIOMETRIC_STRONG | DEVICE_CREDENTIAL`
  throws at `PromptInfo.build()` on API 28–29, and `BIOMETRIC_STRONG` is a
  subset of `BIOMETRIC_WEAK` so nothing is lost) and drops the negative button,
  which the system replaces with "Use PIN"; Windows' `UserConsentVerifier`
  already offers the PIN either way, so the flag is accepted and ignored there;
  Linux stays unavailable. Reported by an adopter shipping a lock on user
  content ([#168]).

[#168]: https://github.com/tophatch/swift-pwa/issues/168

- **`Scripts/android-cdp-eval.py`** — on-device verification in one command
  instead of four copy-pasted ones. `swift-pwa drive` can't reach an Android
  app (the driver socket is on the device's loopback), so verification goes
  through the WebView's own CDP endpoint, and
  [docs/android-on-device-testing.md](docs/android-on-device-testing.md) had
  been telling people to save a helper into `/tmp` and `pip install
  websockets` — a documented manual procedure, which is the smell that
  something should be a script. This one finds the process, forwards its
  abstract socket (bound to the PID, so it is re-established every run),
  discovers the page target and evaluates, several expressions in order
  against one connection. Stdlib only, WebSocket framing included: a test
  tool shouldn't add a `pip` dependency to the machine running it.

  Two traps it now documents, both of which produced confidently wrong
  readings while verifying the change above: **each `swift-pwa drive eval`
  launches a fresh app instance** and tears it down, so a "still pending"
  promise read by a *second* call is a new process rather than an unfinished
  await; and **a native prompt is never screenshottable** — Android blanks
  `screencap` over `BiometricPrompt` and macOS's `screencapture` misses the
  Touch ID sheet, so a blank frame says nothing about whether the prompt
  appeared. `adb shell uiautomator dump` reads it, which is how the negative
  button was confirmed to say "Use PIN".

### Changed

- **The vendored ONNX Runtime moves 1.27 → 1.29 on Apple, Android, Linux and
  Windows** ([#158]). Nothing was broken at 1.27, which is the point: it
  carried a trap with no symptom until an adopter hit it. ORT 1.27 cannot
  *create a session* for an fp16-converted transformer graph at
  `ORT_ENABLE_ALL` — its own `SimplifiedLayerNormFusion` fails naming an
  `InsertedPrecisionFreeCast_…` node the graph doesn't contain — and v0.10.2
  made `.all` the default everywhere except Android. So converting any model in
  this tier to fp16 produced a refusal pointing at a node that isn't there.
  Reproduced through this repo's own `OrtModelSession` against the vendored
  build (1.27: `basic` loads, `all` refuses; 1.29: both load), not just in
  Python.

  Two things deliberately did **not** move. The Windows **DirectML** build
  stays at 1.24.4 with its own committed `ORT_API_VERSION 24` header set — the
  separation exists precisely so the two runtimes can drift, and collapsing it
  would mean a null `GetApi()` and a crash. And 1.29.**1** / 1.30 were ruled
  out by checking the artifacts rather than the release notes: neither ships
  the Android AAR, and 1.29.1 has no Apple pod either.

  **Linux CUDA now needs CUDA 12.8, where 12.4 was enough.** ORT 1.29's CUDA 12
  build is compiled against 12.8 and its provider library imports
  `cudaLibraryGetKernel`, a symbol CUDA 12.4 doesn't export. Measured on one
  machine with only `LD_LIBRARY_PATH` differing: against the system CUDA 12.4
  the EP refuses to load and `ai.vision.info` reports `"cpu"`; against a 12.8
  runtime it reports `"cuda"`. The transparent CPU fallback means this shows up
  as *slower*, not broken — so it is called out in
  [`docs/linux-setup.md`](docs/linux-setup.md) rather than left to be discovered.
  Nothing else in the tier changed behaviour.

  **Published artifacts now carry the ONNX Runtime version in their filenames.**
  Every artifact was previously published under a plain name on a long-lived
  release tag, and both `Package.swift` and the CLI resolvers pin it *by
  checksum* — so re-publishing a new version over the old bytes would have
  broken `swift build` for v0.10.3 and every earlier tag, with no workaround
  but upgrading. A bump is now additive: the new asset lands beside its
  predecessor and old pins keep resolving. (The DirectML assets keep their
  plain names until that pin first moves; the script says so.) A new
  `OnnxRuntimeArtifactPinTests` holds that invariant, because the way to break
  it is to update a checksum and forget the URL — a failure that shows up
  nowhere near here, in other people's builds of older tags.

- **`AppContext` gains `externalURLs`** (an `ExternalURLPolicy`, the way
  `permissions` is a `PermissionPolicy`). Additive for anyone using the
  built-in backends, but a **source break for an out-of-tree `AppContext`
  conformance** — add `public let externalURLs = ExternalURLPolicy()`. All
  in-tree conformances and the test mock are updated. `SystemPlugin` also takes
  an optional `urlOpener:`, defaulted, so existing `SystemPlugin(…)` calls are
  unchanged.

[#158]: https://github.com/tophatch/swift-pwa/issues/158
[#165]: https://github.com/tophatch/swift-pwa/issues/165
[#166]: https://github.com/tophatch/swift-pwa/issues/166
[#167]: https://github.com/tophatch/swift-pwa/issues/167

- **Android completes the set** — `shouldOverrideUrlLoading` hands an
  off-origin main-frame navigation to `Intent.ACTION_VIEW`, and
  `system.openURL` works there, so all five platforms now behave alike.
  Android is the *least* fiddly of the five: `request.isForMainFrame` tells a
  cross-origin `<iframe>` apart from the app navigating away for free, where
  WebKitGTK needed two mechanisms to approximate it.

  It needs the one **synchronous** seam in that backend — a blocking JNI call
  rather than the async RPC everything else uses — because the WebView wants
  an answer before the load proceeds. That's only safe because the decision is
  a lock-guarded pure function in Core; it is worth keeping it that way.

  **And the dialogs were fine here too**, which completes a clean sweep
  against the original assumption: Android's WebView shows its own
  `alert()` / `confirm()` / `prompt()` when the `WebChromeClient` doesn't
  override them. Measured and screenshotted on a device — the page blocks and
  renders *"The page at … says:"*. So **`WKWebView` was the only engine of the
  five with no built-in JavaScript panel**, and #165 — filed as "all four
  non-Apple backends are inert" — was wrong about every one of them. The
  claim came from grepping for handlers we don't install; what an engine does
  when you *don't* handle something is not something grep can answer.

- **`system.openURL` refuses the app's own origin.** Found on a device: two
  backends serve the bundle over **https** (`https://swift-pwa.local` on
  Windows and Android), so the scheme check that catches `pwa://` on Apple
  couldn't tell app content from the web — and the app cheerfully opened
  Chrome on a page only it can answer. Backends now register their content
  origin with the policy (`registerAppOrigin`, from the one place each already
  computes it as a window loads) and `decide` refuses anything on it. It was
  invisible on Apple because the bundle origin is a scheme the check already
  rejected — and invisible on Windows because the earlier verification
  reached for `pwa://` there, which isn't that backend's origin at all.

### Fixed

- **A disabled tray menu item could still be activated on Linux.** Both
  backends export `enabled: false` correctly, so a panel greys the item out and
  a user can't click it — but a panel isn't the only thing that can send a
  `com.canonical.dbusmenu.Event`, and neither backend checked the flag on the
  way in. Our GTK4 shim tested only `!separator` before firing the callback;
  on GTK3, libayatana routes an Event straight to `gtk_menu_item_activate`,
  which doesn't consult widget sensitivity. Either way an app that disabled an
  item — the usual reason being that the action isn't valid right now — could
  still be told it was clicked, by anything in the user's session. Both shims
  now refuse it. Found by the negative control for the test work above ([#193]).

- **The Linux tray is verified on both backends, and a failing tray test no
  longer costs the rest of the run its result.** `GTKTraySNITests` asserted the
  addresses our *GTK4* shim publishes at — a name it owns, `/StatusNotifierItem`
  and `/MenuBar` — against whichever backend was built. The GTK3 backend
  delegates to `libayatana-appindicator3`, which exports onto the app's own
  connection under `/org/ayatana/NotificationItem/<id>`, so the suite could
  never pass there and the GTK3 tray had no coverage at all. The test now asks
  the tray where it lives ([#193]).

  It also assumed a panel was needed to make any of this appear. Measured, it
  isn't: libayatana exports the item and its dbusmenu as soon as the indicator
  exists, with no `StatusNotifierWatcher` on the bus at all — a watcher is who
  gets *told*, not what makes the objects exist. So the GTK3 tray is drivable
  headlessly, and the coverage is real rather than skipped: menu layout,
  `separator`, and a `com.canonical.dbusmenu.Event` arriving on the app's event
  stream. The icon is asserted per backend, because the backends genuinely
  differ — our GTK4 shim marshals the file into an ARGB `IconPixmap`, while
  libayatana passes the path through as `IconName` for the panel to load.

  The worse half was the failure mode. The test raced the incoming event against
  a timeout in a task group so "a regression fails the test instead of hanging
  it" — but on the timeout branch the group was left awaiting a child still
  iterating the stream, and the test never completed. Every suite in flight
  behind it was stranded: on a GTK3 box the four other GUI suites printed
  `started` and were never heard from again, so one structurally-impossible
  assertion was quietly costing four suites their verification. The wait is now
  bounded polling with no `await` in it, so an event that never arrives fails.

- **`Shell.capture`'s timeout didn't bound a command that spawns subprocesses.**
  The deadline fired and terminated the child, but the call then sat in
  `readDataToEndOfFile` anyway: a pipe reaches EOF when the last *writer* closes
  it, and a child's own children inherit the write end. So terminating the child
  produced no EOF whenever it had spawned anything that outlived it — which is
  most of what this timeout exists to bound, since `linuxdeploy`, `xcodebuild`
  and `simctl` all spawn subprocesses. The code comment asserted the opposite
  ("a child that wedges without closing it is still bounded by the timeout,
  whose `terminate` produces the EOF"), true only for a childless child.

  Measured on Linux: after `terminate()`, `sh -c "echo hello; sleep 60"` leaves
  `sleep` holding the pipe and the read is **still blocked eight seconds
  later**. stdout is now drained on a background thread and the deadline is
  waited on directly, so a wedged child is genuinely bounded; the repo's own
  `aWedgedChildTimesOutWithATimedOutError` went from never completing on Linux
  to passing in 4.0s.

  **It had never passed on Linux, and CI called it green** — the test started,
  never reported, and the quiescence rule below read the silence as the post-run
  park. It surfaced on the first run after that rule was fixed, which is the
  clearest demonstration available of what the old one was hiding.

- **A driven drag delivered no movement at all, on both backends that had
  synthetic input.** `PointerInput` carried the button that *changed* but not
  the buttons *held*, and a move is a hover or a drag depending entirely on the
  latter — which the platforms express with different events, not a flag. AppKit
  wants `mouseDragged` rather than `mouseMoved` (and discards a plain
  `mouseMoved` outright unless the window accepts moved events); GDK wants the
  button mask set in the motion event's state. So every synthesized move was a
  hover, and a drag reached the page as a press and a release with nothing in
  between.

  Latent until now because nothing exercised the `move` phase: `drive click` is
  a press and a release, and the drag verb above is the first caller. Measured
  against a page that records the gesture: **0 of 50 moves reached the page and
  the dragged element never moved**; with the fix, 50 of 50, the path passes
  through its corner, and the page computes a real end-of-gesture velocity.
  Confirmed load-bearing by putting the old behaviour back and watching the
  same page go to zero again.

  `PointerInput` gains `buttons`, modelled on the DOM's `PointerEvent.buttons`
  as the rest of the type already is. Additive and defaulted, so a `down` / `up`
  is unchanged.

- **A Linux GUI test run could report a pass while tests were still running.**
  `Scripts/ci-test-linux.sh` reads its verdict from swift-testing's structured
  event stream because the swift-corelibs exit-hang eats the console summary
  ([#39]), and one of its three pass conditions is *quiescence*: 8 seconds with
  no growth in the event file plus any `testEnded` was read as "parked at the
  post-run exit-hang", whereupon the loop breaks and `kill -9`s the bundle —
  discarding anything that had not yet run or not yet flushed its failure.

  The script documented exactly this as its one caveat, and said the assumption
  held because "the suite has no such test (all are fast and event-dense)". That
  stopped being true when the GUI-gated GTK suites arrived: they pump a
  GMainContext for up to 4 seconds at a stretch emitting nothing, and one test
  takes ~18 seconds on its own, so a gap longer than the threshold is normal for
  them rather than hypothetical. Measured on the GTK3 box against a suite with a
  genuine failure, the old rule reported `no failures` and exited 0 on **1 run
  in 5** — a race rather than a systematic false green, which is worse, because
  the failing run is the one you don't repeat ([#190]).

  The event stream carries `testStarted` / `testEnded` per `testID`, so "a test
  is still in flight" is directly observable rather than inferred from file
  growth. With nothing in flight the short quiet window still passes
  immediately; with something in flight it now waits far longer than any test in
  the suite takes, because a live test reports inside that window and a tail
  lost to block buffering never will. Passing on the long window is still a
  judgement call, and it now says so, naming the tests that never reported.

- **`Scripts/remote-linux.sh test` ran no GTK suites by default.** It passed an
  empty filter straight through to `ci-test-linux.sh`, whose own default is the
  two backend-agnostic CI targets — correct for CI, wrong for a box whose only
  purpose is the GTK backend. The obvious invocation ran 952 Core + CLI tests
  with zero GTK suites among them and printed a green verdict that read as "the
  full suite passed on the box". It now defaults to `SwiftPWAGTKTests`; hosted CI
  already covers the other two ([#190]).

[#39]: https://github.com/tophatch/swift-pwa/issues/39
[#190]: https://github.com/tophatch/swift-pwa/issues/190

- **A GTK window can be closed while the webview still has work queued, without
  taking the process with it.** `WebKitGTKAdapter` defers every WebKit call onto
  the GTK main thread through `MainThread.run`, and the widget pointer travels
  through those closures as a `UInt` — so a pointer to a destroyed view is
  indistinguishable from a live one, and the existing `guard let view = …
  (bitPattern:)` never failed. Closing a window destroyed the `WebKitWebView`
  and freed the heap-boxed `NavigationBox`; a `load` that had not run yet then
  called `webkit_web_view_load_uri` on dead memory and wrote the resolved origin
  into the freed box. The visible form was a `WEBKIT_IS_WEB_VIEW` assertion
  followed by a crash in `swift_release`, which this repo had recorded as
  headless noise ([#187]).

  The adapter now carries a lock-guarded liveness token that every deferred
  closure captures and checks, and the window invalidates it before the destroy
  on both close paths (`close()` and the WM's `delete-event`). Late work is a
  no-op; `evaluateJavaScript` and `captureSnapshot` still answer their callers
  rather than stranding them. This was reported against the test environment,
  where `initGTKForTesting` never enters `gtk_main` so the closures land on a
  libdispatch worker — but the same ordering is reachable in a shipping app
  whose window closes between a `load` being scheduled and the main loop getting
  to it, so the fix is in the backend rather than the harness.

  The harness half is that GUI-gated tests could not exercise teardown at all:
  `GTKFullscreenStateTests` crashed on `main` on both boxes and both backends,
  and `GTKAppearanceBackgroundTests` worked around it by leaking its windows.
  `withGTKMainThreadForTesting` now gives a test production ordering — the
  `g_idle_add` dispatch hook installed for the duration and the default restored
  after, since the hook is process-global and only delivers while something
  pumps the loop, so one left installed hangs every later test that awaits
  `MainThread.run`. `MainThread.resetHook()` is the new API that makes that
  restore possible.

- **`window.background_color` carries a light/dark pair all the way to the
  pixels.** The manifest has decoded a `{ light, dark }` pair since v0.7.8, but
  only Android used both halves; the runtime `WindowConfig` took one `String?`,
  so every other backend resolved a pair to its **dark** value and painted that
  forever. That was a defensible call for a *launch* colour — a dark flash beats
  blinding a dark-mode user — and wrong for what the colour actually is on iOS,
  where it paints the scroll view's rubber-band area and is therefore on screen
  during **every overscroll**: a dark-themed app flashed paper white on each
  bounce, and a light-themed app in light mode got the dark half all day
  ([#174]).

  `WindowConfig.backgroundColor` is now a `WindowBackgroundColor` — `.single`
  or `.dayNight(light:dark:)`, `ExpressibleByStringLiteral` so the existing
  spelling still compiles — and every backend resolves it against the **live**
  system appearance, re-resolving when the user switches theme under a running
  app. Apple hands the pair to the platform (`UIColor(dynamicProvider:)` /
  `NSColor(name:dynamicProvider:)`) rather than tracking it; the one thing AppKit
  can't re-resolve for us is the webview layer's `CGColor`, which carries no
  appearance, so that is repainted from an `effectiveAppearance` observation.
  Linux follows `GtkSettings:gtk-application-prefer-dark-theme` and Windows the
  `AppsUseLightTheme` theme setting, with a `WM_SETTINGCHANGE/ImmersiveColorSet`
  repaint.

  **Why those two signals and not the portal or `GTK_THEME`:** measured, both
  ways. WebKitGTK derives the page's own `prefers-color-scheme` from exactly
  that GTK property — verified on WebKitGTK 4.1 *and* 6.0 — so the native
  surface and the web content can't disagree, which is the entire point of a
  pair. `GTK_THEME=Adwaita:dark`, the obvious thing to reach for, turned out
  **not** to set it (it applies at the style-context level), so it is not a
  usable signal. On Windows, `AppsUseLightTheme` is what Chromium reads, for the
  same coherence reason — `SystemUsesLightTheme`, which the tray already uses
  for its own art, is a separate setting.

  Found while verifying: a closed GTK window kept being repainted, because the
  Swift object can outlive its `WebKitWebView` and a weak reference doesn't say
  so — a GTK `CRITICAL`, not a silent no-op. Observers are dropped in the
  window's one teardown path.

  The **iOS launch screen** follows too, which the previous note had written off
  as impossible ("a launch screen is a single static image"). It isn't: UIKit
  resolves a *named* colour from the compiled asset catalog against the launch
  trait collection, so a pair is emitted as a colour set — into the app icon's
  catalog, because `actool` writes one `Assets.car` per `--compile`.

- **`macos.icon` / `ios.icon` / `linux.icon` / `windows.icon` /
  `android.icon` — one project, per-platform artwork.** `pwa.json` had a single
  `icon` and no override, but the two Apple platforms want **opposite** source
  images: macOS composites nothing (`sips`/`iconutil` take the PNG as-is, so the
  rounded-square mask has to be drawn in, with transparent padding around it)
  while iOS applies its own superellipse to a full-bleed image. Give iOS the
  macOS art and its squircle sits nested inside Apple's with the padding reading
  as a dark border — which an adopter shipped, visibly, to the home screen
  ([#173]).

  Each platform section now takes its own `icon`, falling back to the top-level
  one. The manifest key rather than a `--build --icon` flag because it is
  declarative, lives in the repo, and matches how every other per-platform
  difference is spelled (`macos.info_plist`, `android.document_types`). The
  workaround it replaces is the argument for doing it properly: the reporting
  adopter's install script **rewrote `pwa.json` for the length of the build and
  restored it from a trap on exit**, which also forced the script to avoid
  `exec`. Android takes the key for consistency, but adaptive-icon artwork (a
  separate foreground and background layer) is still not modelled — that is a
  design question, not plumbing.

- **Three `SwiftPWAQwenTTS` adoption papercuts, all documentation.** Reported by
  an adopter wiring up read-aloud, in descending order of what each cost them
  ([#171]).

  **The ONNX tier's env gate is named now.** Its products aren't in the package
  graph unless `SWIFT_PWA_ONNXRUNTIME` is set when SwiftPM resolves, and the
  string didn't appear in [docs/ai-plugin.md](docs/ai-plugin.md) at all — so the
  first thing an adopter met was `product 'SwiftPWAQwenTTS' … not found in
  package 'swift-pwa'`, which reads as a bad checkout or a version mismatch
  rather than a missing flag. `swift-pwa build` sets it from
  `ai.local_onnx_runtime`; every other way of building the package — plain
  `swift build`, `swift test`, Xcode — doesn't, which is exactly when this bites.
  A new *Opting in to the ONNX Runtime tier* section says so for all five
  products, and the tutorial's flag table (which had omitted `SwiftPWAQwenTTS`
  entirely) points at it.

  **The streaming shape is stated as a contract, not a capability.** The docs
  showed `subscribe('ai.generateAudioStream', …)` emitting play-as-it-arrives
  `chunk`s next to the backend that ships, so the example read as if it applied
  to it. It doesn't: `QwenTTSBackend` doesn't override `generateAudioStream`, so
  a subscriber gets the protocol default — one `done` frame with the complete
  WAV, no chunks — and the adopter wrote against the streaming shape first. Said
  plainly in the callout and beside both examples. Genuine incremental synthesis
  remains unbuilt; the bridge primitive it was once blocked on has shipped, and
  the roadmap no longer claims otherwise.

  **Two vendored-artifact comments that read as blockers are deleted.**
  `Package.swift` said no release had published `onnxruntime.xcframework.zip`
  and `QwenTTSModelSource` said the `qwen-tts-vendor` release "must be
  published … before these URLs resolve". Both assets have existed for
  releases (55 MB and ~2.6 GB, verified against the published releases); the
  adopter nearly rejected the approach on those comments before testing them.
  Also refreshed the doc's status block and the audio roadmap, which still
  described on-device TTS as unshipped.

[#171]: https://github.com/tophatch/swift-pwa/issues/171

- **`--team` embedded an installed provisioning profile without checking the
  target device was in it.** `deploy --target ios --device <name> --team <id>`
  found a profile for the app id, reported it as the answer, and the install
  then failed at its very last step with `0xe8008012` / *"This provisioning
  profile cannot be installed on this device"* — which reads as a mis-signed
  app. It isn't: the profile is correct, current and correctly signed, it just
  lists the *other* device. A free personal team mints a profile per device, so
  a second test device hits this the first time it is used ([#172]).

  `IOSSigning.bestProfile` filtered candidates on bundle id, team and expiry and
  never read `ProvisionedDevices`. It does now, when the build knows which
  device it is for — `deploy` always passes the resolved device through, and
  `build` takes `--device` (or resolves one for
  `--allow-provisioning-registration`). A profile that doesn't list it is
  treated exactly like no profile at all, so the existing mint path takes over
  and produces one that covers the device; nothing is lost, because the
  non-matching profile could not have been installed anyway. With no device in
  view a plain `build` filters nothing and behaves as before.

  The skipped profiles are named in the output, since the platform's own error
  has no way to say *which* profile or *which* device it means. Two guards the
  device list needs: a profile that lists **no** devices is a distribution
  profile and isn't device-restricted, so "no list" means *any* device rather
  than none; and `--device` accepts a device *name*, passing an unlisted value
  through verbatim as the udid, so the filter runs only against something
  shaped like a real UDID — comparing a name would have rejected every profile.

[#172]: https://github.com/tophatch/swift-pwa/issues/172

- **On Windows, a `ctx.serveDirectory(_:at:)` mount was unreachable: every
  fetch under it failed at the network layer.** An app that mounted a directory
  at `/packs` and fetched `/packs/photo.png` got a `TypeError` for *every* file
  on Windows while the identical app worked on macOS. A plain PNG failing
  alongside the exotic formats was the tell -- this was never a content-type
  problem, and a `TypeError` rather than a resolved 404 means the request never
  reached a handler at all ([#159]).

  The cause is a WebView2 precedence rule that isn't obvious from either API's
  documentation: **`SetVirtualHostNameToFolderMapping` answers requests to its
  host before `WebResourceRequested` is raised.** The bundle origin had a folder
  mapping, so the interception handler that serves mounts was never called --
  not for a mount, not for anything. Measured directly: with the mapping
  installed, a trace in the handler logged nothing across a full page load;
  with the same binary skipping the mapping, the first request appeared
  immediately. The code comment claiming bundle paths "fall through to the
  native virtual-host mapping" had the precedence exactly backwards, and since
  a mapping covers a whole *host* and cannot be scoped to a subpath, there was
  no arrangement in which both worked.

  So Windows no longer uses the folder mapping. The bundle, served-directory
  mounts and the SPA-history fallback all resolve through the same shared
  `AssetProvider` the other four backends use, range-aware, through the
  interception path that single-file builds have always used. One serving path
  can't be shadowed by the other. Three things improve as a side effect: a
  missing file under a mount is now an honest **404** instead of a network
  error; the **SPA-history fallback works on Windows at all** (it was dead for
  the same reason -- `/settings` now serves the entry document); and a bundled
  file's `Content-Type` comes from our own table rather than Chromium's
  guess, so `.heic` no longer arrives as `application/octet-stream` there.

  A `serveDirectory` mount is checked *before* the in-exe overlay, so a
  single-file app can still mount a content pack it downloaded -- that was the
  one Windows case which already worked, precisely because a single-file build
  installs no mapping.

  Verified on an x64 Windows box across all three build shapes -- `swift build`,
  a portable folder bundle, and `--single-file` -- for the bundle, a mount
  (binary and text), a byte range (`206 bytes 0-15/68`), a missing file, an
  encoded path-traversal attempt, and SPA routes.

  **Why this lasted:** the Windows half of content packs was landed
  "compile-only here, CI-verified". CI builds the Windows target but never
  launches it, so no test has ever fetched a URL on the bundle origin. New
  `Scripts/verify-windows-serving.ps1` does exactly that on a real box, and is
  checked against this bug -- it reports `FAIL` on the pre-fix code.

[#159]: https://github.com/tophatch/swift-pwa/issues/159


- **A CI-only flake: three `ComfyUIWorkflowProviderTests` tests failed together
  on the macOS runner against a 500 ms test-harness deadline.** The suite drives
  a fake ComfyUI in the same process, and the deadline is a test constant no
  assertion depends on — so an unrelated PR went red for a budget that was never
  measuring anything, which trains people to re-run a red job without reading
  it. The three that failed are exactly the three that hold `/history` empty for
  four polls, making them the only ones whose runtime depends on timer
  scheduling at all — 14 ms locally, against 1 ms for the tests that do a single
  round trip. What stretches those four sleeps past 500 ms on a hosted runner
  was not established: it did not reproduce locally with the full suite at load
  average 85 on 10 cores, nor with a single-thread cooperative pool. The shared
  helper now allows 30 s. The one test that asserts *on* timeout behaviour
  keeps its own short budget and now also checks *which* error came back,
  since a fail-fast regression would otherwise still satisfy "it threw" by
  polling to the deadline ([#180]).

[#180]: https://github.com/tophatch/swift-pwa/issues/180

- **A CI-only flake: `DevServerTests` bound a port it had probed as free,
  which anything could take in between.** The test discovered a free port by
  binding `port: 0`, recorded the number the OS handed out, **stopped that
  server**, then bound the same number again to prove a fixed port yields a
  stable origin — a window no test can win, because the port it just released
  goes straight back into the range the kernel hands out to any outbound
  connection, and the rest of the suite runs concurrently. `SO_REUSEADDR`
  doesn't help: another socket genuinely owns the port, it isn't ours in
  `TIME_WAIT`.

  Fixed by removing the window rather than narrowing it — the test now binds a
  port it *chooses*, so the attempt is its own probe and there is nothing to
  re-acquire. The number is drawn from below the ephemeral range, which is
  what makes this airtight rather than merely unlikely: measured on macOS,
  4,000 `bind(0)` calls returned nothing below 49152 (`net.inet.ip.portrange.first`,
  and the flake landed on 49189), so a chosen port in the 20000s cannot be
  handed to a competing connection at all. Only the *choice* retries, bounded,
  and if every attempt is occupied the last error surfaces — a broken bind
  can't be retried into a pass. The assertion also got stronger: the port is
  now the test's own number for `DevServer` to honour, not one the OS had just
  supplied ([#161]).

  The race was real but rare, which matches having been seen once: a released
  port does come back from `bind(0)` — measured, port 51433 reappeared after
  16,356 tries, about the 16,384-port range size — so the odds were roughly
  one in a range-size per competing bind inside a microsecond window.

[#161]: https://github.com/tophatch/swift-pwa/issues/161

- **On Android, an `ACTION_VIEW` intent routed to an app that was already
  running stacked a second `MainActivity` — with a second Swift runtime.** Found
  while verifying the deep-link work, but it applies equally to a warm document
  open, so it predates it. The launcher Activity keeps the default `standard`
  launch mode deliberately: `singleTop` or `singleTask` would redirect
  `spawnWindow`'s secondary Activity into the existing instance and break
  multi-window. The cost is that a warm `VIEW` intent arrives as a brand-new
  Activity instead of `onNewIntent`, and that instance ran the whole primary
  path — spawning another `swiftPwaMain()` thread and taking the single-slot
  bridge ref off the live one.

  It looked fine, which is why it lasted: measured on a Fold7, three warm deep
  links left **three `MainActivity` records in one task** (`sz=3`) each with its
  own runtime, while the page still showed the right URL — because the URL was
  being read off the newest copy of the app. The back button then walked
  backwards through stale ones.

  A redundant primary now hands its intent to the live owner and finishes
  before it builds a WebView or attaches a bridge, keyed on the same
  `swift-pwa.config-json` extra that already distinguishes a secondary window —
  so multi-window is untouched (verified: the secondary still opens, `sz=2`,
  with no extra runtime). After the fix three warm links leave `sz=1` and the
  runtime-thread count a plain launcher start produces.

- **`biometric.canAuthenticate` reported `available: true` on a Face ID device
  with no `NSFaceIDUsageDescription`**, where the `authenticate` that follows
  can never succeed. `authenticate` already preflighted the key and threw a
  clear error rather than letting iOS raise the uncatchable exception that
  terminates the app; `canAuthenticate` didn't, so an app doing the
  **documented** thing — check availability, offer the feature only when
  available — offered a biometric lock on a device where the unlock could
  never work, and the error then arrived when someone was trying to get back
  in. It only reproduces on a real device, which is where the reporting
  adopter found it. Both entry points now run the same check, and it is a
  pure function (`BiometricPolicy.faceIDUsageDescriptionProblem`) so it is
  assertable without a bundle that has or lacks the key ([#169]).

[#169]: https://github.com/tophatch/swift-pwa/issues/169

- **Text fields on macOS can select-all, copy, paste, cut and undo.** Until
  now none of them could, in any swift-pwa app: the keystroke arrived and the
  app beeped. The editing shortcuts on macOS are not a property of a text
  field — they are main-menu *key equivalents*, dispatched down the responder
  chain as `selectAll:` / `copy:` / `paste:` / `cut:` / `undo:`, and an
  equivalent matching no menu item is never dispatched at all. `NSTextView`
  inside `WKWebView` implements every one of those actions and was sitting
  there ready to receive them; nothing ever sent them, because
  `MacAppRuntime.makeMainMenu` built one submenu (About / Hide / Quit) and
  stopped. The fix that made ⌘Q work went one submenu deep and the rest never
  followed. Reported by an adopter, whose page had no `keydown` handler, no
  `preventDefault` and no `user-select` rule anywhere — nothing on the web side
  was involved.

  So the menu bar now carries **Edit** (Undo / Redo / Cut / Copy / Paste /
  Paste and Match Style / Delete / Select All) and **Window** (Minimize / Zoom
  / Close, with `NSApp.windowsMenu` set so AppKit maintains the window list),
  plus a Services menu. Every editing item has a `nil` target, which is what
  sends it down the responder chain and lets WebKit enable and disable it
  against whatever is focused — Paste greys out on a non-editable field with
  swift-pwa knowing nothing about the page.

  Verified by driving a real app: ⌘A selects, ⌘C and ⌘X reach the **system**
  pasteboard (checked with `pbpaste`), ⌘V pastes it back, ⌘Z undoes and ⇧⌘Z
  redoes. A page that handles ⌘A itself still wins — measured against a
  genuine keystroke, its handler runs and `preventDefault` holds — so an app
  that already intercepts these keys is unaffected.

  **iPadOS was measured and needs nothing.** It was the platform most likely
  to share the bug — and doesn't: on an iPad Pro (M5) with a hardware
  keyboard, ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z all work in a `WKWebView` text field with
  no menu at all, because UIKit hands the standard edit actions down the
  responder chain itself. That step is exactly what AppKit lacks, where the
  same actions exist only as main-menu key equivalents.

  **Linux had a smaller gap of the same kind, now fixed too.** On both
  backends Ctrl+A / Ctrl+X / Ctrl+V already worked — WebKit's GTK port binds
  those itself — but **Ctrl+Z / Ctrl+Shift+Z did nothing**, because WebKit
  leaves undo and redo to the embedder and swift-pwa never wired them up.
  Identical on GTK3 + WebKitGTK 4.1 and GTK4 + WebKitGTK 6.0, so it was the
  WebKit port rather than the toolkit. Both now call
  `webkit_web_view_execute_editing_command`.

  **The binding is the interesting half.** The existing Ctrl+Q and Ctrl+Alt+J
  bindings are deliberately dispatched ahead of focus — a GTK3 accel group, a
  global-scope `GtkShortcutController` on GTK4 — so they fire over a focused
  text input. Undo must *not* work that way: it would take Ctrl+Z from a page
  implementing its own, which is a drawing or editing app, the kind most
  likely to want it. So it runs after the page declines instead — a
  `G_CONNECT_AFTER` handler on the window's `key-press-event` on GTK3, a
  bubble-phase `GtkEventControllerKey` on GTK4 — which is what macOS does,
  where the page measurably keeps a ⌘Z it calls `preventDefault` on.

- **Windows: a freshly launched app can be typed into.** The editing
  shortcuts themselves were already fine there — Ctrl+A / Ctrl+X / Ctrl+V /
  Ctrl+Z / Ctrl+Shift+Z all work, WebView2 handles them internally — but the
  window's `WM_SETFOCUS` only emitted `.didFocus` and never called
  `ICoreWebView2Controller::MoveFocus`, so **the web content never got
  keyboard focus from activation**. Measured on a fresh launch: the window is
  foreground, the page's own `element.focus()` has set `activeElement`, and
  `document.hasFocus()` is still `false` — so nothing you type goes anywhere
  until you click inside the window. macOS and both GTK backends focus their
  web view on activation, so Windows was the only platform where "launch the
  app and start typing" did nothing.

- **The app driver could not have caught this, and now can.** `drive type`
  gained **`--modifiers shift,control,alt,command`**, and two things behind it
  had to change before a driven ⌘V meant anything. Synthetic input is
  delivered with `NSWindow.sendEvent`, one level *below* the
  `NSApplication.sendEvent` step that dispatches menu key equivalents, so a
  driven shortcut could only ever do nothing however right the menu was; an
  unhandled injected event is now offered to the main menu at the point it
  falls off the responder chain (`DriverWindow.noResponder`), which is where a
  real keystroke would go and keeps the page's first claim on it. And a
  shift-bearing keystroke carried the *unshifted* character — a real ⇧⌘Z sends
  "Z", not "z", and AppKit matches key equivalents on that string, so ⇧⌘Z
  matched no item and looked exactly like a broken Redo when the menu item was
  correct and the event was wrong.

  Menu shortcuts also need an **active app**: a menu item's action is sent with
  a `nil` target and AppKit routes those through `NSApp.keyWindow`, which an
  inactive app doesn't have. `drive type --activate` brings the app forward for
  the keystroke — opt-in per keystroke, since not needing the screen is the
  point of this driver. Dispatching down the driven window's own chain to avoid
  that was tried and rejected: it gets past the routing but still fails
  WebKit's `validateUserInterfaceItem`, and forcing past *that* would have the
  driver report an editing capability a real user doesn't have.

- **`invoke(cmd)` with no argument now decodes.** `bridge.js` sends
  `payload: null` for an argument-less invoke, and a struct whose fields are
  all optional cannot decode from `null` — the synthesized initializer asks
  for a keyed container and JSON `null` isn't one. So the documented
  `invoke('app.quit')` failed with a decoding error while
  `invoke('app.quit', {})` worked, and the only commands that escaped were
  those taking `EmptyArgs`, which has no properties and so never asks. Every
  test passed `{}`, which is not the shape the page sends. `Invocation.decode`
  now retries as `{}` when the payload is literally `null` — retried rather
  than substituted up front, so it can only rescue a decode that was already
  failing and a handler that wants a `null` payload still gets one.

### Added

- **`macos.last_window_closed` — what happens when the last window closes.**
  ⌘W working makes a state reachable that previously wasn't: macOS is the one
  platform here where an app outlives its windows (Linux and Windows exit), so
  closing the only window used to leave a running app with a menu bar, no
  window, and no way back — a Dock click did nothing, because the runtime
  can't ask an app to build a window again after `configure` has returned.

  The default, `reopen`, is what Finder and Safari do: the app stays running
  and activating it brings the window back, rebuilt from the `WindowConfig` it
  was created with (so a remembered size and position come back with it; page
  state does not — it loads fresh, as a relaunch would). `keep-running` stays
  windowless on purpose, for an app whose real surface is a status item.
  `quit` terminates, like a single-window utility and like the other two
  desktops. Seeds `ctx.lastWindowClosed` in the generated `App.swift` at
  `swift-pwa init` time, the same way the `window` block does; `swift-pwa
  build` rejects an unspelled value rather than ignoring it and leaving the
  setting looking broken.

  **`app.lastWindowClosed`** puts the same choice behind a page's own
  preference checkbox: called with no argument it reads the current policy,
  with `{ value }` it sets one, and either way the reply carries what is now
  in force so a settings UI round-trips in one call. Both sites that consult
  the policy read it when they need it, so a change applies to the very next
  close. Where the choice is *stored* stays the app's business — an app
  already has somewhere it keeps preferences, and a runtime that quietly
  persisted this one would then owe an answer about which wins at launch, its
  own file or `pwa.json`'s default.

## [0.10.3] - 2026-08-30

### Added

- **Linux decodes HEIC and AVIF through libheif — and it cost no new
  dependency after all.** The last platform, and the one the proposal expected
  to be expensive: Linux is the only target with no system image codec (the
  vendored stb build reads PNG and JPEG only), and WebKitGTK links no HEIF or
  AVIF decoder either, so a HEIC was undecodable at *both* layers there.

  The plan was a `libheif-dev` build dependency, AppImage bundling, CI
  provisioning in several places, and an opt-in build flag to keep all that off
  everyone else's build. None of it was necessary: `CHeifShim` loads libheif
  with **`dlopen`**. No `-dev` package, no link-time dependency, no hard
  `libheif.so.1` requirement in an AppImage, and no flag to set — an app gains
  the formats on a machine that has libheif and doesn't on one that doesn't.

  That also makes the capability honest in the same way Windows already is:
  libheif `dlopen`s its *own* codec plugins (libde265 for HEVC/HEIC, aomdec for
  AV1/AVIF), so having libheif installed does not mean a given format decodes.
  `capabilities()` calls `heif_have_decoder_for_format` per family, and
  `image.info` reports exactly that.

  The ABI is bound by hand from libheif 1.21's headers — opaque pointers,
  scalars and one small by-value struct — read from the real headers
  (`apt-get download libheif-dev` + `dpkg-deb -x`, no install needed) rather
  than assumed, because a wrong struct layout here is a crash rather than an
  error. An unresolvable symbol disables the feature instead. stb stays the
  first decoder and libheif is tried only for what stb can't read, so the common
  PNG/JPEG path is untouched.

  **Verified on both Linux boxes** — Ubuntu 26.04 with GTK4/WebKitGTK 6.0 and
  Ubuntu 25.10 with GTK3/WebKitGTK 4.1 — each reporting
  `decode: avif,heic,heif,jpeg,jpg,png` and decoding real fixtures of both
  formats at full size.

  With this, `image.*` covers **all five platforms**, and the tests gained the
  check that matters most for a capability-reporting API: a build that *claims*
  a format in `image.info` must actually decode it, asserted against committed
  1.4 KB HEIC and AVIF fixtures. On a platform that doesn't claim it, the same
  test asserts the refusal is clean rather than a broken image.

- **Windows decodes through WIC, so `image.*` can rescue a HEIC there too.**
  Phase 2 of the transcode proposal. Chromium has no HEIC decoder, so a WebView2
  app cannot display an iPhone photo — but the machine underneath usually can,
  through the Windows Imaging Component. Windows now gets the same
  platform-codec treatment Apple (ImageIO) and Android (`BitmapFactory`) already
  had, via a new `CWicShim`: decode-to-RGB that **scales during decode** (so a
  24-megapixel photo never exists at full size in memory, unlike the
  resample-after-decode path), PNG/JPEG encode, and a decoder enumeration. Plain
  Win32/COM headers from the Windows SDK — unlike `CWebView2Shim` it needs no
  NuGet package, so it builds on any Swift-on-Windows install, and every entry
  point catches its own exceptions because a C++ exception unwinding across a C
  ABI into Swift kills the process with no message.

  **What Windows can read is a property of the machine, not the build**, so
  `capabilities()` enumerates the registered decoders at runtime rather than
  claiming a list: HEIC needs the HEVC codec extension (the paid/OEM-supplied
  one) and AVIF needs the AV1 extension. On a machine without them, `heic`
  simply isn't in `image.info` — which is the honest answer, and why Windows
  must never advertise the format statically.

  `stb_image` stays on Linux, now the only target with no system codec, and
  `ImageCodec+Desktop` is narrowed to `os(Linux)` to match. Windows gains a lot
  more than HEIC from the switch: the test box enumerated **66 decodable
  extensions** — TIFF, JPEG XL, and camera RAW from most manufacturers — where
  stb was compiled for PNG and JPEG only.

  **Verified on a real x64 box**, and the claim lands in one measurement: a HEIC
  reports `naturalWidth: 0` in WebView2, and the 3,444-byte JPEG that
  `image.transcode` returns renders at 240 (the same image as PNG is 35,794
  bytes, which is how we know `format` reaches the encoder). The 5 new codec
  tests live in `SwiftPWAWindowsTestRunner` — swift-testing cannot discover
  tests on Windows, so that is the only place this path runs at all — and all 17
  cases pass there.

- **`image.*` — convert an image the webview can't display.** The webview is
  routinely the least capable image decoder on the device. Measured by driving a
  real app on each of the four engines this project ships on, **HEIC renders in
  exactly one of them** — Apple's; WebKitGTK links no HEIF or AVIF decoder at
  all, and Chromium (WebView2 and Android's `WebView`) has AVIF but not HEIC.
  Since HEIC is what every photo an iPhone writes to iCloud Drive actually is,
  an app that accepts photos from a user's filesystem previously had to ship
  Apple-only or write per-platform native code — the work this framework exists
  to absorb. Reported by an adopter who had left both formats out of their
  importers because of it.

  The decoder was already there. `ImageCodec`'s Apple path is ImageIO, which
  reads HEIC and AVIF today, and its Android path is `BitmapFactory`, which
  decodes both on a modern device — it was `package`-internal, reachable only by
  the on-device AI backends. So this exposes what a build already contains
  rather than adding a codec: opt-in `ImagePlugin(PlatformImageTranscoder())`
  (add the `SwiftPWAImage` product) serving `image.info` and `image.transcode`.

  **`image.info` is load-bearing, not decoration** — what a build can read is
  genuinely not uniform, so it is *derived*, never assumed: Apple enumerates
  ImageIO's real type list (AVIF read arrived in macOS 13 / iOS 16), Android
  asks the device because `minSdk` can be 28 while HEIF needs 28 and AVIF needs
  31, and desktop reports the two formats the vendored stb build is actually
  compiled for (`STBI_ONLY_PNG` + `STBI_ONLY_JPEG` — so Linux and Windows can
  convert and resize but cannot rescue a HEIC, at either layer). A format this
  build can't handle throws `E_IMAGE_UNSUPPORTED`, kept distinct from `E_IMAGE`
  because it is a question `image.info` could have answered first.

  `ImageCodec` gained JPEG output on all three platform codecs to go with it
  (ImageIO, `Bitmap.compress`, and a new `stbi_write_jpg` shim), since PNG is
  the wrong output for a photo. Decodes are bounded at 4096px by default:
  a 24-megapixel photo is ~72 MB of RGB per buffer and on Android that crosses a
  JNI RPC, which is the same wall `LaMaBackend` hit. `SwiftPWAImageIO` moved out
  from behind the ONNX gate it used to sit under — it never had an ONNX
  dependency, and `image.*` must not drag in the AI tier.

  **Verified by driving a scaffolded app on real hardware, not just in tests.**
  On a Galaxy Z Fold7 the end-to-end claim is demonstrated in one measurement:
  the HEIC reports `naturalWidth: 0` in Android's `WebView`, and after
  `image.transcode` the resulting 2,934-byte JPEG renders at 240 — the format
  the engine refuses, converted by the decoder underneath it, displayed. The
  same file to PNG is 42,000 bytes, which is how we know `format` genuinely
  reaches `Bitmap.compress` rather than quietly writing PNG twice. On macOS a
  real HEIC converts to a 240×240 baseline JPEG on disk (confirmed with `file`)
  and renders from the page. On Linux the transcoder's suite runs against the
  real stb build, where the unsupported-source path is meaningful rather than
  skipped.

  Docs: [`docs/javascript-api.md`](docs/javascript-api.md); proposal
  [`docs/proposals/image-transcode.md`](docs/proposals/image-transcode.md).
  Phase 1 of that proposal — Windows via WIC and Linux via libheif/libavif are
  phases 2 and 3, and both are capability-reported rather than assumed.

### Fixed

- **The same record now always crosses the bridge as the same bytes.** Two
  `invoke` calls returning an identical value could serialize its keys in
  different orders, so `JSON.stringify(a) === JSON.stringify(b)` — the obvious
  way for a page to ask "did this change?" — never matched. Reported by an
  adopter whose virtualized gallery reuses a card when its record is unchanged:
  with the comparison always false, **every card on screen was rebuilt on every
  re-list**, and a rebuilt card is a new `<img>` that decodes again. On an iPad,
  re-listing every couple of seconds while covers generated, that read as the
  whole grid flashing about once a second — a visual symptom whose cause was on
  the wire.

  The source is `JSONEncoder`, which does not preserve declaration order for
  synthesized `CodingKeys`: it emits them in hash order, which varies per encode
  *and* per process. Measured here on one struct: **6 distinct key orders across
  200 encodes** with a single reused encoder, and a different order again in
  each of six fresh processes.

  The fix is `.sortedKeys` in `Envelope.encode`, not on the handler's encoder as
  originally suggested — `Envelope.encode` parses each payload back to
  `Any` and re-serializes it, so a sort done upstream was **undone** on the way
  out. Applied at the envelope it is also the one choke point every backend
  delivers through, so it covers unary replies, stream and session chunks, and
  `events.*` pushes on all five platforms, nested objects included, in one line.
  Pre-fix that path emitted **6 distinct frames** for one identical record
  (the envelope's own keys varied too); it now emits one. Key *sets* still
  differ when an optional Swift property is `nil`, since `JSONEncoder` omits it
  rather than sending `null` — that is a real difference, correctly reflected.
  Cost is a sort per object: on a deliberately large 685 KB reply carrying ~6,000
  records, frame serialization goes 6.4 ms → 11.3 ms; on ordinary payloads it is
  noise. The contract is now written down in
  [`docs/javascript-api.md`](docs/javascript-api.md#record-shape-on-the-wire),
  since "the same call returns the same object" is what everyone assumes.

  **Verified by driving a scaffolded app on two engines against a control build
  of the released CLI**, calling one typed command 400 times and comparing what
  the page received: on `WKWebView` the control produced 3 distinct
  serializations of an unchanged record (the `JSON.stringify` comparison false),
  and the fixed build 1, with keys alphabetical; WebKitGTK 6.0 and WebView2
  likewise each returned a single alphabetical order. A scaffolded app, not an
  Example, since the Examples carry fallbacks the scaffold never emits.

- **HEIC, HEIF and AVIF are served as themselves, not `application/octet-stream`.**
  `AssetProvider.mimeType(for:)` had no case for any of the three, so a file the
  platform decodes perfectly well was announced as an opaque byte stream — the
  one thing a save path, a download, or any consumer that doesn't sniff has to
  take at face value. HEIC is not exotic: it is what every photo an iPhone puts
  in an iCloud Drive folder actually is. The Android file-dialog filter table
  gained the same three, so a picker filtered on those extensions no longer
  widens to `*/*`.

  **This is a correctness fix, not a rendering fix, and the reporting adopter's
  premise for holding the formats out of their importers does not survive
  measurement.** Driving a scaffolded app serving real HEIC and AVIF files:
  Apple's WebKit renders both *even under the octet-stream fallback* — `<img>`,
  a blob URL, and `createImageBitmap` all decoded at full size on macOS and on
  the iOS Simulator, before this change. It sniffs, so the wrong type cost
  nothing there. WebKitGTK is the opposite: with the correct type served, both
  formats fail on GTK4/WebKitGTK 6.0 — `<img>` `naturalWidth: 0`, blob URL
  broken, `createImageBitmap` `InvalidStateError` — while PNG in the same page
  renders fine. That is not the fixtures: neither WebKitGTK 6.0 nor 4.1 links
  libheif or libavif in the builds the distros ship (they carry JPEG XL
  instead), so those engines have no decoder to reach at any MIME type. On
  WebView2 and on Android's `WebView`, AVIF renders and HEIC does not (Chromium
  has no HEIC decoder on either). So across all four engines HEIC renders on
  exactly one — Apple's, where it already worked before this change — and an app
  that must show iPhone photos everywhere has to transcode on import. Android
  *does* honour this table (`image/heic` and `image/avif` served correctly on a
  Fold7); Windows is the one backend that doesn't, see below.

  Windows also turns out not to consult this table for bundle assets at all:
  the bundle is served natively by `SetVirtualHostNameToFolderMapping`, so
  Chromium picks the type from its own extension mapping (measured: `.avif` →
  `image/avif`, `.heic` → `application/octet-stream`, whatever `AssetProvider`
  says). The table governs the interception path — `serveDirectory` mounts, the
  SPA fallback, single-file embedded assets — and every other backend end to
  end. Both facts recorded in
  [`docs/swift-api.md`](docs/swift-api.md#serving-extra-directories-content-packs).

  `swift-pwa dev` had its **own second copy** of the MIME table, which had
  already drifted — it was missing every audio and video type the bundled app
  serves, so a `<video>` that streams from a built app would not stream under
  `dev`. It now calls the same `AssetProvider.mimeType(for:)`, deleting the
  copy rather than adding a third place to fix.

  Queued as a follow-up: [`docs/proposals/image-transcode.md`](docs/proposals/image-transcode.md),
  an `image.*` plugin that would let an app transcode on import. The decoder is
  already there on two of the platforms, both now measured: Apple's `ImageCodec`
  path is ImageIO, which reads HEIC and AVIF today, and Android's is
  `BitmapFactory`, which decoded both on a Fold7 and round-tripped them to PNG
  through the `image.decode` / `image.encodePng` RPCs every generated app
  already carries. So it is mostly a matter of exposing what a build already
  contains rather than adding a codec.

- **A document's bridge state no longer outlives the document.** Navigating a window — a link, `location.assign`, a router doing a real page load — used to leave every stream, session, and in-flight `invoke` the old document opened still running natively. `BridgeRuntime.stop()` was the only thing that cancelled a window's subscriptions and it ran from `windowWillClose`, so nothing observed a navigation on *any* of the five backends. Reproduced here on a real `WKWebView`: with three documents loaded in turn, one `emit` was delivered **three times** — once per document ever loaded in that window — and both native tasks and `EventBus` sinks accumulated without bound. Reported by an adopter porting a desktop e-reader, who measured the same 1:1 growth.

  **The half that made it a correctness bug, not a leak:** `bridge.js` allocates correlation ids from a per-document counter that restarts at `1`, and `deliver()` routes an inbound frame by that id alone. A leaked stream keeps emitting frames stamped with the *old* document's id, which the *new* document resolves against its own table — so as soon as two pages allocate ids in a different order, a live channel is delivered to a handler for something else entirely. Not a race and it does not self-correct: same two pages, same misroute, every time. What it looked like in the adopter's app was a `prefs:changed` payload arriving at a `permission:denied` handler, which drew a "can't read this folder" warning naming no folder — for a channel nothing in the app could even emit — and read as a TCC bug for as long as the channel name was believed.

  Both halves are closed on the wire rather than at each backend's navigation seam. `bridge.js` mints an **epoch** per document (it is injected at document start, so a fresh document mints a fresh one) and announces it with a `hello` frame before the page's own scripts run; the runtime treats a new epoch as a navigation and tears down everything the previous document opened, then drops any later frame still stamped with it. Every frame carries the epoch in both directions, so a stream torn down mid-`deliver` — cancellation is cooperative, so that window exists — cannot bind to whatever the new document has since put in that id. Doing it in Core means all five platforms behave identically, including the three whose webviews expose no `WKNavigationDelegate` equivalent, and it needed no per-backend code at all.

  Only the top frame takes part: `bridge.js` is injected into subframes as well (`forMainFrameOnly: false` on Apple, and the equivalent elsewhere), and a subframe announcing its own epoch would read as a navigation and cancel the parent's subscriptions. Subframes therefore send unstamped frames and keep exactly the behaviour they had — sharing the window's id space, with replies delivered to the top frame — which is its own latent hazard, but a different change.

  **Verified on four of the five engines by driving a real two-page app**, each against a control build with the epoch protocol neutered, so the measurement isn't vacuous: macOS/`WKWebView` (in the test suite, three documents → 3 deliveries before, 1 after), WebKitGTK 4.1 and 6.0 via `swift-pwa drive`, and Android's `WebView` on a device over CDP — 2 before, 1 after on each. Windows/WebView2 is inferred rather than driven: nothing in the change is platform-specific, and `AddScriptToExecuteOnDocumentCreated` gives the same per-document injection Android's Chromium `WebView` was just measured doing.

  The teardown is triggered by the *new* document announcing itself, so a window navigated to content that runs no JavaScript (a PDF or an image loaded straight into the webview) keeps the previous document's streams alive until the next real document or the window closes; they can no longer misroute, but they do keep running. Documented in [`docs/javascript-api.md`](docs/javascript-api.md#navigating-away).

  One thing the fix had to grow on the way: because ids are reused across a navigation and cancellation is cooperative, a task torn down by the navigation runs its own cleanup *afterwards*, by id — deleting the entry the new document had since put in that slot. That took the emit count from 3 to **0** before subscription bookkeeping was tagged with a document generation.

## [0.10.2] - 2026-08-17

### Changed

- **On-device TTS is ~1.5x faster on Apple and desktop** — `QwenTTSBackend` now derives its ONNX graph-optimization level per platform (`.basic` on Android, `.all` everywhere else) instead of pinning every platform to `.basic`.

  The `.basic` ceiling was inherited from a real Android constraint and never revisited: the extended fusions rewrite standard ops into `com.microsoft.*` contrib ops, the Android ONNX Runtime package has no **float16** kernels for those, and this pipeline's talker is fp16 — so a fused fp16 Gelu has no kernel and the session fails outright (the same root cause as the Stable-Diffusion Gelu-fusion gotcha). Apple and desktop packages *do* carry the fp16 contrib kernels, and those transformer fusions are precisely what this pipeline is made of, so holding every platform to Android's ceiling was leaving the win on the floor.

  Measured on an M-series MacBook (release build, 65-char prompt, best of 3 interleaved rounds): the real-time factor drops from **3.70 to 2.52** — and an adopter's independently reported 3.3x-slower-than-real-time matches the old number closely. **The audio is unchanged**: fusions are numerically approximate and this pipeline samples with a *seeded* RNG, so a small logit shift could have forked the token stream into different-but-plausible speech; a new test decodes both WAVs and compares them, giving 140,160 samples at correlation 0.999999999822609 with identical length. Override via `QwenTTSBackend(graphOptimization:)` if a specific model needs the old level.

  Reference: [`docs/on-device-ai-performance.md`](docs/on-device-ai-performance.md), including the levers *not* yet pulled — on-device TTS is still ~2.5x slower than real time, so treat it as generate-then-play.

### Added

- **The CoreML execution provider can now be requested per ONNX session on Apple** (`OrtCoreMLOptions`, plus a `coreML:` parameter on `QwenTTSBackend`). The vendored Apple ONNX Runtime has always contained the EP — `_OrtSessionOptionsAppendExecutionProvider_CoreML` is in the binary and `coreml_provider_factory.h` is in the module map — but nothing ever appended it, so every ONNX session on Apple silently ran on the CPU EP, and `ai.vision.info` reporting `provider: "cpu"` there was accurate rather than a bug. It follows the same discipline as the existing desktop GPU tier: appended before the CPU EP, and a failure to append or create logs once and retries on CPU, so inference is never broken by an unusable accelerator.

  **It defaults to off for the TTS pipeline, because it loses** — measured, not assumed. On the talker graph CoreML claims 2119 of 2629 nodes but spreads them across **170 partitions**, and this pipeline runs the talker plus 15 code-predictor calls *per audio frame* (~750 session runs for six seconds of speech), so handoff cost dominates before any arithmetic happens. Three of five configurations are refused at session creation (`error code: -14`); the `NeuralNetwork` format loads and then fails on the **first token**, naming the blocker outright — a zero-element KV-cache tensor, which is step 0 of every autoregressive generation and not an edge case to route around; and the one configuration that runs (`requireStaticInputShapes`) is slower than the CPU EP *and* changes the output. The transferable rule: CoreML pays off for one big static-shape graph invoked a few times, and loses for a small dynamic graph invoked hundreds of times. A vision encoder is the first thing and the obvious next candidate to measure, so `MobileSAMBackend` is deliberately untouched pending that measurement.

  Two traps documented along the way. The vendored `coreml_provider_factory.h` documents the `MLComputeUnits` values as `MLComputeUnitsAll` / `MLComputeUnitsCPUAndGPU` / …, and **the implementation accepts none of those spellings** — ORT 1.27 takes the bare `CPUAndGPU` / `CPUAndNeuralEngine` / `CPUOnly`, with "all" not settable at all (it's the default you get by omitting the key). A documented-but-wrong value throws at session creation, which the fallback path turns into a *silent* CPU run: the first version of this benchmark produced a tidy table showing CoreML performing identically to CPU, because it was CPU. So `QwenTTSBackend.activeProvider` now reports what a session actually loaded on, and the benchmark asserts against that rather than against intent.

- **`ai.info` now reports `provider`** — which ONNX execution provider a backend actually loaded on (`"cpu"` / `"coreml"` / `"cuda"` / `"directml"`), mirroring the field `ai.vision.info` has carried since the desktop GPU tier landed. Wired through `QwenTTSBackend`, `StableDiffusionBackend`, `LaMaBackend` and `MultiModelImageBackend` (which reports whichever model is currently *resident*, since the router keeps one loaded at a time).

  This exists because a requested accelerator that can't be appended **falls back to CPU silently** — by design, so inference is never broken by a missing GPU, but it means "I built the CUDA tier" and "I am running on CUDA" are different claims and nothing surfaced the second one. It's diagnostic rather than a routing signal: `nil` until a session exists (the EP is only chosen at `CreateSession`), and `nil` on backends that don't model it. `unload()` clears it rather than leaving a stale value.

- **A TTS performance benchmark in the normal test suite** (`QwenTTSBenchmarkTests`), opt-in via `QWEN_TTS_MODEL_DIR` + `QWEN_TTS_BENCH=1`: a timing matrix, the CoreML outcome probe, and the `.basic`-vs-`.all` audio-equivalence check. It interleaves configurations round-robin and reports the best sample per configuration rather than running each to completion in turn — a straight-through run measured everything ~1.5x slow once the laptop had heated up under sustained ORT load, which would have been read as a property of whichever configuration ran last.

- **`Scripts/remote-linux.sh` — drive a remote Linux box from a non-Linux dev machine.** The GTK targets are `#if os(Linux)` so they never compile on macOS, and CI only *compiles* them, so every runtime check means rsync-to-a-box-and-build by hand. The script makes that repeatable: `sync` / `build` / `test` (GUI-gated suite under Xvfb with the known-good headless WebKit env) / `provision` (builds the libxml2 compat shim above) / `shell`. The host comes from `--host` or `$SWIFT_PWA_LINUX_HOST` — never baked in. It also excludes `Vendor/` and the per-example `build/` trees from the sync by default: they're several GB of Apple/Android artifacts the Linux box re-resolves anyway, and transferring them dominated the wall clock (`--with-vendor` opts back in).
- **`Scripts/ci-test-linux.sh` takes swift-testing filters.** With no arguments — how CI invokes it — it still runs the same two backend-agnostic targets, so CI behavior is unchanged. The reason to parameterize it: the Linux crash-at-exit truncates swift-testing's block-buffered output, and the GUI-gated GTK suites are short enough that the truncation lands squarely on the passing tail, so a plain `swift test` reports a fully green run as `exited with unexpected signal code 6`. Reading the verdict from the structured event stream is the only way to tell that from a real failure, and that logic already lived here — one GTK3 run needed three attempts before a clean verdict. `Scripts/remote-linux.sh test` now routes through it rather than calling `swift test`.

### Fixed

- **`ai.info` no longer queues behind a running generation.** Every ONNX-tier backend is an `actor` and `AIPlugin` serves `ai.info` as `await backend.info()`, so a capability read — which only assembles a struct and stats a few files — could not enter the actor while a synthesis or an image generation was running inside it. Reported by an adopter and reproduced here exactly: **6 ms idle against 9,873 ms** four seconds into an `ai.generateAudio`, returning the instant generation finished. Their user-visible symptom was a voice picker that stayed blank for ten seconds — opened, naturally, while a book was being read aloud.

  `info()` (and its `modelInfo()` helper) is now `nonisolated` on `QwenTTSBackend`, `StableDiffusionBackend` and `LaMaBackend`. Everything it reads is immutable configuration or a filesystem probe; the one piece of mutable state it touches, the recorded execution provider, moves behind an `NSLock` so it can be read without entering the actor. Measured after: **0 ms** during synthesis, and 0 ms during a Stable Diffusion denoise loop — which mattered more, since a real image takes tens of seconds rather than ten.

  **Mutating entry points stay isolated on purpose.** `generateAudio`, `generateImage`, `ensureModel` and `unload` all touch the lazily-populated session cache, and serialising them is the actor earning its keep — `unload()` racing a generation would free the sessions out from under it. What changed is only that *reads* no longer pay for that.

  This unblocks live state generally, not just the reported symptom: an `availability` that flips to `ready` after `ai.ensureModel`, a model switcher, or a progress read all have to ask **while** the backend is busy, and previously could not. The adopter's workaround — resolve `ai.info` once at page load and cache the promise — is no longer necessary, and never generalised.

- **`swift test` could not link at all on libxml2 2.14+ distros, and the documented fix made it look like it should.** libxml2 2.14 (Ubuntu 25.10, 26.04) bumped its SONAME to `libxml2.so.16` *and dropped the versioned symbols*; Swift's prebuilt `libFoundationXML.so` still has a `DT_NEEDED` on `libxml2.so.2` and imports `xmlInitParser@LIBXML2_2.4.30` and friends. [docs/linux-setup.md](docs/linux-setup.md) told you to symlink `.so.16` to `.so.2`, which satisfies the *name* and gets the toolchain running — so the advice looked like it worked — but the ABI is still wrong, and linking the test bundle dies on a wall of `undefined reference`. Two CLI test files import `FoundationXML`, so that takes down the whole suite; product builds are unaffected. Neither of the obvious fixes terminates: distros no longer package a `.so.2` compat build, and the archived one needs ICU 74, which those distros also no longer ship. The doc now carries the fix that does — a user-local libxml2 2.12 built `--without-icu` — plus the non-obvious detail that it must be wired in with **`-rpath-link`**, because the unresolved symbols come from `libFoundationXML.so`'s own `DT_NEEDED` and plain `-L`/`LIBRARY_PATH` never covers that case.
- **`libsecret-1-dev` was missing from the documented Linux dependencies.** It's an unconditional Linux build dep — `SwiftPWACore` pulls the `CSecretShim`/`CLibSecret` pair behind `LinuxSecretStore` whether or not an app registers `SecretsPlugin` — and it's installed by CI and the release workflow, but [docs/linux-setup.md](docs/linux-setup.md)'s `apt-get install` lists never gained it when the `secrets.*` plugin landed. Following the doc on a clean box got you as far as `'libsecret/secret.h' file not found`. Added to both the GTK3 and GTK4 lists, with a note on why it's not optional.

## [0.10.1] - 2026-08-16

### Added

- **`ble.*` — Bluetooth LE, on all five platforms.** `ble.availability` (invoke), `ble.scan` (subscribe) and `ble.connect` (a duplex session), over a `BluetoothCentral` / `BluetoothLink` seam. Central role only: scan, connect, discover, read, write with and without response, notify/indicate, disconnect.

  Unlike the rest of the device surface, **there is no web fallback to fall back to**. Web Bluetooth has never shipped in WKWebView or Safari, and Android's embedded `WebView` doesn't expose it either (Chrome does). Nothing here is "the web API but nicer" — it's the difference between the capability existing and not existing, which is also why `bluetooth` is declared under a new **`permissions.device`** key rather than `permissions.web`: no page can ask for it on its own. `WebPermission` is renamed `DevicePermission` to match, with the old name kept as a deprecated typealias.

  No new bridge primitives: a BLE connection *is* a duplex session, so `ble.connect` opens with the peripheral, takes writes as pushes and yields notifications downstream, and the bridge ties the connection's lifetime to the session's. Pushes carry an optional `token` echoed on the `ack` / `read` / `failed` that answers them — without it, `withResponse: true`, whose entire point is confirmation, has nowhere to report success. A failed operation is a downstream `failed` event rather than a stream error, because the bridge ends a session on an error and a write the peripheral rejects shouldn't cost the page its connection. **A link survives a drop**: going out of range emits `state{connected:false}` and the backend keeps trying, re-emitting `ready` on reconnect since the handles are new. The shape this exists for is a machine that browns out mid-job.

  **One UUID spelling, in both directions.** CoreBluetooth returns `"FFE1"` for an assigned 16-bit UUID and upper-case 128-bit otherwise; BlueZ and Android always return lower-case 128-bit; WinRT returns a `GUID`. A page written against one (`event.characteristic === 'ffe1'`) breaks silently on the other three — a mismatch, not an error, so nothing is reported and the notifications just never seem to arrive. The wire is always full 128-bit lower-case; short forms are accepted as input because that's how the assigned-numbers documents write them.

  Backends: **CoreBluetooth** (macOS + iOS), **BlueZ over GDBus** (both GTK backends from one gio-only shim, the same reasoning as GeoClue — BlueZ's GATT interface *is* D-Bus, with no usable C library), **WinRT `Windows.Devices.Bluetooth`** (built-in, so it joins the existing WebView2 shim with no NuGet), and **`BluetoothLeScanner` + `BluetoothGatt`** on Android. Availability is checked in Core rather than per backend: an adapter that's switched off scans happily and finds nothing, which a page can't tell from "no peripherals nearby".

  Verified end-to-end on real hardware — scan, connect, discover, subscribe, a written `ping` echoed back as a notification, a read, and a streaming counter — on macOS, **iOS** (an iPad, driving the HelloPWA card by hand — a device's driver socket is on its own loopback, so `swift-pwa drive` can't reach it), Linux GTK3 (BlueZ 5.83), Linux GTK4 (5.85), Windows arm64 and a Galaxy Z Fold7, each against `Scripts/ble-test-peripheral.*`. Guide: [`docs/tutorials/talking-to-a-bluetooth-peripheral.md`](docs/tutorials/talking-to-a-bluetooth-peripheral.md); reference [`docs/bluetooth.md`](docs/bluetooth.md). `Examples/HelloPWA` gains a **Bluetooth** card that works with whatever hardware is already in the room — scan, pick a device, read its GATT tree — and only writes when the peripheral is one of the shipped fixtures.

  **Findings only the hardware could produce.** Android needs `connectGatt` on the main thread *and* the device object from the scanner rather than `getRemoteDevice(address)` — that call assumes a public address type, so a peripheral advertising a random one is unreachable; both surface as the same catch-all status 133, and a lone 133 reads as "this peripheral doesn't work". Android also serialises GATT strictly: a second operation issued before the first completes doesn't queue, `writeCharacteristic` returns false and nothing is reported. Windows has no `Connect()` at all — reading the service tree *is* the connection — and closes the link the moment nothing needs it unless a `GattSession` holds it open, which surfaces as `ready` firing over and over. A C++ exception could unwind across the shim's C ABI into Swift, showing up as the process vanishing with no message. On Linux, BlueZ raises a `Value` property change for `ReadValue` as well as for a notification, so a read came back to the page as unsolicited data.

  **One documented limit.** Connecting from Linux to a *dual-mode* peripheral — a Mac, a phone, anything that also speaks classic Bluetooth — fails `br-connection-key-missing`: it advertises over LE from the same address its classic radio uses, so BlueZ keeps one device object with both identities and takes the classic route. Measured, not assumed: removing the cached device and rebuilding it from an LE-only scan doesn't change BlueZ's mind, and `bluetoothctl` "succeeds" only by starting a classic pairing and asking the user to confirm a passkey. Pairing once is the fix, and the error says so. An LE-only peripheral — which is what a real device is — never takes that path.

### Fixed

- **One pending `invoke` froze the whole bridge for that window.** `BridgeRuntime`'s pump was `for await frame in stream { await handle(frame) }`, and `handle` awaited the command to completion — so every `invoke` was serialised, and one slow handler stalled every frame behind it, including other invokes, `subscribe` and `unsubscribe`. Found while verifying the v0.10.0 release by running the published assets: `__platform.info` answers, then `geo.current` parks on the first-run location prompt, and `__platform.info` never returns again. The app looks hung, and the page can't even render the outcome of the prompt it's waiting on.

  **Pre-existing rather than a 0.10 regression** — that pump long predates the device surface. `geo.*` is simply the first command that can pend *indefinitely on user input*; `ai.generateImage` takes ~35 s but nothing else is usually invoked meanwhile, which is why it went unnoticed. Any adopter whose handler awaits a network call or a dialog has been paying a quieter version of it.

  Invokes now dispatch concurrently, tracked so `stop()` can cancel work that would otherwise keep running against a torn-down web view. **`subscribe`, `unsubscribe` and `push` deliberately stay ordered**: `dispatchSubscribe` registers its inbound sink *synchronously before* dispatch precisely so a following `push` finds it, and `unsubscribe` has to find what `subscribe` registered — making those concurrent would trade this bug for a race.

  Two consequences worth knowing. Replies may now arrive out of request order, which is correct for a promise-based API (each `invoke` correlates by id) but is a change if anything downstream assumed otherwise. And two invokes of the same command can now overlap, so a handler that quietly relied on being serialised needs its own synchronisation — the registry's lock protects registration, not handler bodies.

## [0.10.0] - 2026-08-16

### Added

- **`geo.*` — device location as a native plugin, on all five platforms.** `geo.current` (invoke) and `geo.watch` (subscribe) over a `GeolocationProvider` seam. Location is the one capability the permission work above can't reach through the web API: **macOS WKWebView gives an embedder no public way to grant `navigator.geolocation`**, so a page there stays denied however the app is configured. That's measured rather than assumed — in one process, with location authorized by the user, `geo.current` returns a fix while `navigator.geolocation` still fails `code 1 "User denied Geolocation"`. iOS, on the same framework, prompts and grants; the asymmetry is macOS alone, which is worth stating because an earlier draft had it as Apple-wide.

  `GeoFix` mirrors the web platform's `GeolocationCoordinates` — same field names, same units — so moving off `navigator.geolocation` isn't a re-learn; the one difference is `timestamp` in seconds rather than JS milliseconds, matching the rest of the bridge. `accuracy` is a two-value hint (`high` / `balanced`) because that's what all four platform APIs actually express; a metre budget would imply a promise none of them make. It goes through the **same gate** as the web API — undeclared or vetoed fails `E_GEO_DENIED` *before the provider is touched*, so a refusal never spins up the hardware and an app's own location switch has no documented bypass — and `E_GEO_UNAVAILABLE` always means this machine right now, never "this OS".

  Backends: **CoreLocation** (macOS + iOS), **GeoClue 2 over D-Bus** (both GTK backends, from one gio-only shim — GeoClue needs no development package and no toolkit, so unlike the tray it doesn't duplicate per GTK version), **WinRT `Geolocator`** (built-in WinRT, so it joins the existing WebView2 shim with no NuGet and no App SDK bootstrapper), and **`LocationManager`** on Android. The last is a deliberate deviation from the proposal, which listed `FusedLocationProviderClient` first: fused lives in Play Services, and adding a Google dependency to every generated project to reach what is otherwise a framework API is a poor trade — worse on a device with no Play Services, where fused isn't there at all.

  Verified with a real position on every platform: macOS 35 m, iOS 6 m on an iPad, Linux ~26 km on both boxes (IP-class, no WiFi source configured), Android 100 m, Windows 115 m. Plus a **Device & location** card in `Examples/HelloPWA` — driven, not just built: `geo.current` reads `±35 m`, the watch toggle streams and stops, and the app-level switch flips the same call to `E_GEO_DENIED: this app has turned location off`.

  Three findings worth keeping. **CoreLocation:** calling `requestLocation()` while authorization is still `.notDetermined` fails *immediately* with `kCLErrorDenied` — a denial for a dialog the user hasn't answered — and leaves the app switched off in System Settings afterwards, so the next run is denied for real. It survived an ad-hoc signature and a LaunchServices launch, so it looked exactly like a signing or TCC constraint; (commit `5bcd2de` also lists a fresh bundle identifier among the things ruled out — that one was a no-op, not a negative result: `swift-pwa init` seeds `ios.bundle_identifier` / `macos.bundle_identifier` explicitly, so changing `id` alone never changes the bundle id.) the tell was the app appearing in Settings at all, which can only happen if the prompt was shown. **GeoClue:** it hands out nothing without an **agent** running for the session — a desktop session has one, an SSH session doesn't, and without it the failure reads as "this feature doesn't exist" rather than "it's gated". **GDBus:** `signal_subscribe` attaches its dispatch source to whichever context is thread-default *at subscribe time*, so a session with its own context has to push it first or updates go to the global default — iterated by the GTK main loop on a desktop app and by nobody at all headless.

  Guide: [docs/tutorials/using-the-camera-and-location.md](docs/tutorials/using-the-camera-and-location.md). Reference: [docs/permissions.md](docs/permissions.md).

### Fixed

- **Camera, microphone and location never worked on Linux — on either GTK backend — and the page was told the user had denied them.** WebKitGTK asks its embedder before letting a page use a device, through a single `permission-request` signal that carries every permission type. Neither backend connected it, so the signal took its default, which is to refuse. Measured on real hardware: `getUserMedia({audio: true})` returned `NotAllowedError` in **83 ms** with a real microphone attached, and `getCurrentPosition` returned `code 1 PERMISSION_DENIED` in **1–2 ms** — no dialog window was ever created (`xwininfo -root -tree` is byte-identical across the request), so nothing was ever asked. Millisecond refusals against the 6–7 *seconds* the platforms that do ask take is the whole tell. Both are now answered from a new app-wide `ctx.permissions` policy, which every backend will consult as this lands on the rest of them.

  **Nothing is permitted until the app declares it** — `ctx.permissions.declare(.microphone, .geolocation)` in `configure` — so no app silently gains a capability on upgrade, and the refusal that used to be silent now prints a one-off line naming the exact call to add. That message earns its place: by the time a refusal reaches JS it is indistinguishable from a user denial, so the console is the only place the real cause can surface. There's also a `setVeto` hook for an app's own in-app privacy switch ("microphone: off"), which sits *above* the OS prompt so a vetoed permission is refused **without** asking the user about something the app has already ruled out.

  Verified on both boxes with a freshly scaffolded app (not an Example — those carry fallbacks the scaffold never emits), across three variants. Undeclared: refused, plus the diagnostic. Declared, on the box with a real microphone: **`{ok: true, tracks: 1}`** — a live audio track where there had been `NotAllowedError` — and `enumerateDevices()` returning the device's actual name instead of `audioinput:(no label)`, since WebKit gates device *labels* behind their own permission too. Declared, for location: the error changes from `code 1 PERMISSION_DENIED` to `code 2`/`code 3`, which is how you see the gate open on a headless box whose GeoClue has no usable provider. Vetoed: straight back to `code 1` in **35 ms** against the allowed path's 12 s, which is the veto's "refused without asking" visible as latency — while the microphone kept working in the same run, so the veto is per-permission and not a blanket switch. `Scripts/verify-linux-permissions.sh` is that matrix, repeatable.

  One thing checked rather than assumed: `enumerateDevices()` never settles at all on a box with **no** media devices. That reproduces with the handler removed, so it predates this change and is a WebKitGTK behaviour, not a regression.

  **This is one platform of five.** iOS and Windows already prompt and grant unaided and are untouched; macOS capture already worked while location did not; **Android remains broken** for both, and needs two layers rather than one (there is no `WebChromeClient` at all, *and* the manifest requests neither permission). Declaring on those backends is currently a no-op that changes nothing either way. The full measured matrix and the sequence is in [docs/proposals/permissions-bridge.md](docs/proposals/permissions-bridge.md); the adopter-facing API is [docs/permissions.md](docs/permissions.md).

- **Camera, microphone and location never worked on Android either — same silent denial, two layers deep.** The generated `MainActivity` set **no `WebChromeClient` at all**, so `onPermissionRequest` and `onGeolocationPermissionsShowPrompt` took their default (deny), and the manifest requested neither `CAMERA` nor `RECORD_AUDIO` nor location — so wiring the client alone would only have moved the denial one layer down. Measured on the device before: `NotAllowedError` in 18 ms (audio) and 51 ms (video), `code 1 PERMISSION_DENIED` for location, with `enumerateDevices()` listing the hardware the whole time. After: **a live audio track, a live video track, and a real 100 m location fix**, each behind the OS's own prompt.

  The decision has to round-trip, because the policy is in Swift, the WebView asks on the JVM's UI thread, and Android's runtime prompt is asynchronous by construction: Kotlin pushes a host event, Swift answers from `ctx.permissions`, Kotlin then raises the OS prompt and grants or denies the WebView request. Kotlin owns the OS half deliberately — by the time `onPermissionRequest` fires Android has already established the app doesn't hold the permission, so *something* has to ask, and only an Activity can.

  Two findings that only a device could produce. **A microphone needs `MODIFY_AUDIO_SETTINGS` as well as `RECORD_AUDIO`**: Chromium's Android audio manager requires both before it will open a recording device, and without it `getUserMedia` fails **`NotReadableError` — "Could not start audio source" — with the runtime permission granted**, which reads as broken hardware rather than a missing declaration. The device said so plainly in logcat (`cr_media: Requires MODIFY_AUDIO_SETTINGS and RECORD_AUDIO`) and nothing else would have. It's install-time, so it adds no prompt. And **the undeclared diagnostic was invisible on Android**, because an app process's stdout and stderr go to `/dev/null` there — a message whose entire job is to explain a silent refusal was itself silent. Core diagnostics now route through an installable sink (`RuntimeDiagnostics`, the same single-hook shape as `MainThread`'s dispatcher) which the Android backend points at logcat.

  Verified on a real device (Android 16) over CDP, on the final build, with the control run too: strip the declaration and it's back to `NotAllowedError` / `code 1`, the manifest carries no permission lines, and the diagnostic names the missing call in `adb logcat`.

- **`pwa.json` gains `permissions.web`, and the build refuses to let it drift from the code.** The runtime ceiling is `ctx.permissions.declare(…)`, but a cross-compiled build can't run the app to ask what it declared — the same limit `agent.expose` has — and Android and iOS are precisely the platforms whose *artifact* needs the declaration. So `permissions.web` drives the platform artifact (today the Android `uses-permission` entries) and `swift-pwa build` compares the two, failing on disagreement in either direction. Both are real bugs and they fail differently: declared only in `pwa.json` and the artifact asks the user's OS for something the app then refuses; declared only in Swift and the runtime says yes while the platform says no — and on Apple a missing usage description **terminates the app**. An unknown name is refused before anything is built, since a typo would otherwise silently omit a manifest entry and leave the adopter debugging a device denial. Accepts a plain list or an object carrying Apple's mandatory per-permission purpose string, the way `window.background_color` takes a hex string or a `{light, dark}` pair. Verified end-to-end on a scaffolded app: drift fails, agreement builds, a typo fails fast.

  Note for anyone who conforms to `AppContext` themselves: it gains a `permissions` requirement (`public let permissions = PermissionPolicy()` satisfies it). Adopters receive an `AppContext` rather than implement one, so this should reach nobody, but it is source-breaking if it does.

### Added

- **`swift-pwa drive eval` now returns a promise's settled value instead of failing.** An expression that produced a promise didn't resolve — it *failed*, with a serialization complaint that never mentions promises (`… returned a result of an unsupported type`), because no backend awaits on its own: Apple's `evaluateJavaScript`, WebKitGTK, WebView2 and Android's WebView all hand the `Promise` object straight back. Anything genuinely async — `fetch`, `navigator.mediaDevices.*`, an `async` IIFE, any `await` at all — was therefore unreachable from the driver, and the error pointed at result types, so the workaround you land on is stashing the result on a `window` global and reading it back in a second call. Found while probing webview permission behaviour across all five platforms, where every interesting API is promise-shaped. `drive` now does that stash-and-poll itself, client-side over the existing `eval` verb (as `--wait` already works) so there's no app-binary change and every backend behaves the same, draining its own `window` key so a repeatedly-driven page doesn't leak one per call. A rejection surfaces as `E_EVAL_REJECTED` with its message rather than a timeout, `--timeout` bounds the wait, and a page that navigates mid-flight fails `E_EVAL_LOST` instead of hanging.

  **No flag**, because a capability you have to know about is one that fails first and works second. Making it automatic is safe because the script is run through **indirect `eval`** rather than wrapped in parentheses, so it stays a *program* with today's exact semantics — statements work, declarations still land on the global object and persist for the life of the app, and the value is still the completion value (`window.a = 1; window.b = 2` → `2`); all verified against a running app, alongside a resolved promise, a 1.5s delayed one, a rejection, an `async` IIFE, and a user exception still surfacing as an exception. The one page this can't serve is one whose CSP forbids `unsafe-eval`; there `drive` falls back to evaluating the script directly, exactly as before. The probe that detects it runs a harmless constant through `eval` **before** the script, so a blocked page can never execute it twice. CI covers the await itself in both `bundle-smoke` jobs — every other `drive eval` in the workflow is synchronous, so a green run would otherwise say nothing about it; the assertion resolves a *delayed* promise so at least one poll comes back pending rather than reading one that had already settled.

## [0.9.12] - 2026-08-14

### Fixed

- **`swift-pwa build --target linux` never returned — the AppImage was complete on disk and the build just sat there.** `linuxdeploy` and its plugins are themselves AppImages, and each one self-mounts over FUSE by default; on that path the tool finishes its work and our direct child ends up an unreaped zombie while the runtime's mount daemon lingers, so the CLI waits forever. Measured on a clean box with the **shipped v0.9.11 binary**: still waiting at 84 minutes, artifact byte-complete since minute two. It reproduced on both a GTK3 and a GTK4 box, which means Linux bundling has been unusable for anyone whose machine takes that path — and CI never caught it because the Linux jobs only *compile* the backend; **nothing in CI had ever bundled an AppImage.** Now one does: a `bundle-smoke-linux` job scaffolds a fresh app, bundles a debug AppImage, deletes `.build`, relocates it, launches it under Xvfb and drives it, asserting the bridge is live — the Linux counterpart of the macOS job added in 0.9.10, and it fails on both of the bugs in this release (a hang trips its timeout; a non-self-contained bundle never announces a driver port). Fixed by running linuxdeploy with `APPIMAGE_EXTRACT_AND_RUN=1`, the mode AppImage documents for automation (where FUSE frequently isn't available at all): the same build completes in **26 seconds**, so skipping FUSE is faster as well as unstuck. There's a sting in the tail: the release workflow `swift-pwa init` generates has set that very variable since it was written, commented "linuxdeploy needs a FUSE-less extraction on CI runners" — so the workaround existed in the *generated copy* and never in the tool, which is why an adopter's release pipeline was fine while building on your own machine wedged. Two verification notes worth keeping: killing a wedged run leaves *stale FUSE mounts* behind, and those poison every subsequent measurement on that box — several of mine, until I unmounted 72 of them and started over — and `Process.waitUntilExit()`, polling `isRunning`, and `terminationHandler` all wait forever alike here, so this was never fixable on our side of the spawn.

- **`swift-pwa build --target linux` crashed for any app that both declared `agent.expose` and installed a tray — which is the combination the agent surface documents.** Validating `agent.expose` runs the app headlessly to dump its command catalog, and on the GTK backends that happens *before* `gtk_init`, so the app's own `configure` reached `app_indicator_new` with no display — where GTK **aborts the process** rather than returning an error ("Can't create a GtkStyleContext without a display connection"). The build failed with a 150-frame backtrace and `command failed (5): swift run -c release HelloPWA`, which points at the app rather than at the tool, and `xvfb-run` didn't rescue it (nothing had connected to a display, because nothing had called `gtk_init`). A tray is now inert when there's nothing to put an icon on: no display, or a catalog dump in progress. The second half matters even where it can't crash — the GTK4 tray speaks D-Bus rather than GTK, and would have put a real status item in the user's panel as a side effect of running a *build*. The guard lives in `SystemTray` rather than `TrayPlugin` because an app constructs the tray itself (that's the documented way to install the agent indicator), so a plugin-level check would miss it. Verified on both Linux backends: reproduced on GTK3 at the same commit, then `build --target linux` completes for the same app on GTK3 *and* GTK4 (~30s each, `agent.expose` validation included) — and, because a guard that silently disables a feature is the failure mode here, the built AppImage was launched under Xvfb on both boxes and **still registers a real tray item** (`org.kde.StatusNotifierItem-…` on GTK4; `/org/ayatana/NotificationItem/swift_pwa` on GTK3, against a stub StatusNotifierWatcher — without a watcher, libayatana falls back to XEmbed and registers nothing, so its absence proves nothing).

- **`build --target ios --simulator` could hang forever before printing a single line — a deadlock in the CLI, not a slow build.** `Shell.capture` read a child's stdout **after** `waitUntilExit()`, so any command that says more than a pipe holds (64 KiB on macOS) wedged permanently: the child blocked in `write`, the CLI blocked in `wait`, neither ever moved. Measured directly with that exact ordering: 64 KiB returns, 128 KiB never does. The command over the line is `xcrun simctl list runtimes -j`, and the sting is that it's only a **diagnostic** — a pre-flight whose entire job is to turn xcodebuild's opaque "Unable to find a destination" into a sentence naming the fix. It runs before the build emits anything, so the last thing in the log was the caller's "building for the simulator", and three CI jobs in a row (39, 30 and 45 minutes) died at their step timeout looking like slow compiles. The 0.9.10 note below blamed `xcodebuild` on exactly that evidence, and was wrong; what settled it was noticing that the only orphan process the runner killed in all three stalls was `simctl`, never `xcodebuild` — which inherits our stdout and had printed nothing, because it was never reached. Now: the drain happens before the wait (a child that wedges *without* closing stdout is still bounded, since the timeout's `terminate` produces the EOF); `Shell.capture`'s timeout reports `timedOut` rather than a bare non-zero exit, so a bound reads as a bound; the pre-flight is bounded at 120s and **advisory** — if `simctl` won't answer, the build says so and lets xcodebuild speak for itself, because a diagnostic must never be able to block the thing it's diagnosing; and it announces itself, so the phase can't hide behind the previous line again. CI now records the byte counts, which settle it: on a GitHub runner `simctl list runtimes -j` is **133,117 bytes**, more than double the buffer — and `simctl list devices available -j` is **71,890**, over it as well, so `deploy --target ios --simulator` failed at its own (bounded) device lookup on such a machine. That was latent in every one of the CLI's ~30 `Shell.capture` calls, several of which query similarly large JSON (`swift package describe`, `security find-identity`), on any machine with enough installed for the output to cross the line. The simulator job now completes in 8½ minutes, having never once finished before.

### Fixed

- **`drive type --key <any named key>` arrived in the page as `key: "Dead"`.** Not just the arrows: `Enter`, `Tab`, `Escape` and `Backspace` too — every key that isn't a single character. The rest of the event looked perfect (`code: "ArrowRight"`, `keyCode: 39`, no modifiers), which is what made it so misleading; `key` is the property nearly every web app switches on, so an adopter's reader ignored every arrow key while the same code worked when the event came from `eval`. Cause: a named key was synthesized with `characters: ""`, and an empty string is not "no character" to WebKit — it reads as a **dead key**. Named keys now carry the character macOS itself sends: AppKit's private-use code points for the navigation and function keys (`ArrowRight` → U+F703) plus the `function` / `numericPad` flags a real event has, and control characters for `Enter` / `Tab` / `Escape` / `Backspace`. `Backspace` and `Delete` were also the *same* virtual key code (so `--key Delete` deleted backwards) and are now distinct, as are `Home` / `End` / `PageUp` / `PageDown` / `Insert` / `F1`–`F12`, which had no mapping at all. Reported by an adopter. Verified in-page for all 15: every one now reports the `key`, `code` and `keyCode` a keyboard produces.

- **Synthetic input made the system alert sound.** Every `drive type` keystroke the page didn't consume produced an audible beep on the host — a dozen in one scripted pass — which undercuts the driver's whole promise that a run can happen in the background while you keep working. It's AppKit's unhandled-`keyDown` feedback (`NSResponder.noResponder(for:)`), and the fix needed a measurement rather than a guess: a scope around `sendEvent(_:)` doesn't work, because WebKit decides a key event's fate **asynchronously** — it ships the event to the web process and re-sends the unhandled ones on a later turn of the main loop, long after any such scope has exited. Instrumenting `noResponder` showed exactly that: four keys sent, four beeps, all after the fact. A driver build now registers each injected event's timestamp and swallows the feedback only for events it recognises, so a key *you* press that nothing handles still beeps. Measured before and after (4/4 beeping → 4/4 suppressed). Note the adopter also reported clicks beeping; driving clicks, right-clicks and scrolls into a page with no handlers at all never reached that path here, so if it persists it's a different mechanism and worth a fresh report.

### Added

- **The driver reports whether a window is actually on screen, and warns when it isn't.** WebKit throttles `requestAnimationFrame` for a window the compositor isn't showing — **measured at 1 frame in 3 seconds while minimized, against 183 when visible** — so a page that draws or restores its state in a rAF callback silently does nothing while it's covered, and `drive shot` returns a perfectly clean screenshot of the stale content. That reads as an app bug and isn't one; it cost an adopter an hour twice ("EPUB renders nothing", "reading position isn't restored", both fine when visible). `drive windows` now reports each window's `visibility`, and every verb warns on **stderr** (so a piped result is unaffected) when its target isn't visible. New `Window.visibility()` in Core, default-implemented as `unknown` so an external conformance keeps compiling: **macOS** answers properly via `NSWindow.occlusionState` (which also covers another Space and a sleeping display), **Windows** detects minimized only, and **Linux** / **Android** report `unknown` rather than guessing — X11 and Wayland expose no occlusion query. The driver can't stop WebKit throttling; it can stop you debugging the wrong thing.

## [0.9.10] - 2026-08-11

### Added

- **`swift-pwa build --target macos --arch arm64 --arch x86_64` produces a universal `.app`.** The bundler ran a hardcoded `swift build -c release` with no architecture passthrough, so the app was always the build host's — and [docs/macos-setup.md](docs/macos-setup.md) listed "build twice and `lipo -create` them yourself" as a known limitation, which is a strange thing to ask when SwiftPM's own `--arch` is repeatable and does it. `--arch` is now repeatable on `build` and `deploy`; omitting it keeps today's host-arch behaviour, and a value that isn't a macOS architecture is refused rather than silently ignored. Two or more slices also relocate SwiftPM's products (`.build/apple/Products/Release`), so the bundler asks `--show-bin-path` where they landed instead of assuming. The build reports the slices it read back out of the binary with `lipo -archs`, not the ones you asked for. Reported by an adopter, who had already confirmed the plain `swift build --arch arm64 --arch x86_64` works on a real project with GRDB and ZIPFoundation in the graph. Pairs with the bundle fix below: a universal binary is only interesting for an app that can leave the machine that built it.

- **`swift-pwa drive --simulator` drives an app on the iOS Simulator.** The driver is the reason UI work is verifiable from a script at all, and going to iPad lost it: the control socket is compiled into debug builds only, `deploy --target ios` built release, and neither `build` nor `deploy` had a `--configuration`. So checking a safe-area or full-bleed change meant deploy → `simctl launch` with `SIMCTL_CHILD_SWIFT_PWA_INITIAL_ROUTE` → `simctl io screenshot` → crop → look, once per iteration, with anything time-dependent (a chrome that auto-hides after 3s) caught by burst-screenshotting and picking the frame. Nothing in the app was missing — the iOS runtime has started the socket since the driver shipped, and the simulator shares the host's network stack, so loopback just works. `drive --simulator` now owns the loop: debug `.app` → `simctl install` → launch with the driver env var → read the port and token off the app's console → verb → `simctl terminate`. `eval`, `shot`, `windows`, `info`, `--route`, `--wait` and `--device <name>` all work; **synthetic input doesn't** (iOS has no public event-synthesis API, and `drive info` reports `input.pointer: false` rather than pretending), and a *physical* device still can't be driven because its loopback isn't the host's. Reported by an adopter. Verified on a booted simulator with both an Example and a freshly scaffolded app: JS evaluated in the page, a real iPhone-viewport screenshot taken from the app's own renderer, and the app terminated afterwards.

- **`--configuration debug|release` on `build` and `deploy`.** Every bundler hardcoded release, which is right for a shipping artifact and wrong for anything you intend to drive or attach a debugger to. Applies to macOS, iOS, Linux and Windows (`swift build -c` / `xcodebuild -configuration`); on Android the Swift library stays release and the APK variant remains `--release`, as before.

### Changed

- **Each target now bundles into its own directory under `build/`.** Both Apple bundlers wrote `<output>/<name>.app` and `--output` defaulted to `./build` for every target, so `swift-pwa deploy --target ios` silently overwrote the macOS `.app` a previous `build --target macos` had put there. The damage was invisible at the moment it happened and surfaced later somewhere else: double-clicking the survivor gave Finder's "this application is not supported on this Mac", which points at signing or architecture rather than at the actual cause, and it recurred on every device deploy until you knew to pass `--output`. The defaults are now `build/macos`, `build/ios`, `build/ios-simulator`, `build/linux`, `build/windows`, `build/android` — which also makes `build/` self-describing once several targets have been built, and separates the simulator bundle from the device one (installing a simulator build to a device fails just as opaquely). An explicit `--output` is still used verbatim, and is backed up by the second half of the fix: a build **refuses to overwrite** a bundle made for a different platform or destination, naming both, instead of clobbering it. Detection uses a small stamp file the build leaves behind, falling back to the shape of any `.app` already present (macOS bundles have `Contents/`, iOS bundles are flat) so a bundle from an older swift-pwa is caught too. Reported by an adopter, who lost a confused half hour to it. **Breaking** for anything with a hardcoded `build/<name>.app` path — including a `release.yml` scaffolded by an earlier version; the emitted template is updated, so `swift-pwa generate-ci` regenerates it.

### Fixed

- **A bundled app read its own JS runtime out of the build machine's `.build/` directory, so every `.app`, AppImage and portable `.exe` crashed on launch anywhere else.** `BridgeScript.source()` loaded `bridge.js` from a SwiftPM resource bundle, and SwiftPM's generated accessor checks exactly two locations: next to `Bundle.main.bundleURL` and an **absolute path into the build directory**. No desktop bundler staged the resource bundle, so only the second existed — the app worked perfectly on the machine that built it and died with `Fatal error: could not load resource bundle` on anyone else's, naming a path that had never existed there. Reported by an adopter who found it while testing a universal build; reproduced here by moving `.build` aside, and it applied to macOS, Linux and Windows alike (iOS escaped it because a flat `.app` bundle root *is* `Bundle.main.resourceURL`). Staging the bundle isn't the fix: for a `.app`, `Bundle.main.bundleURL` is the bundle **root**, and `codesign` refuses to seal anything there ("unsealed contents present in the bundle root") — so a placement that works can't be signed, and a placement that can be signed doesn't work. `bridge.js` is instead **compiled into the binary** (`BridgeJSData` in Core, generated from the canonical `Resources/bridge.js` by `Scripts/regenerate-bridge-js.sh`, with `swift test` failing on drift), which is the same embed the Android bundler has used since 0.7.2 for the same class of reason. Core declares no resources at all now, so no app on any platform needs a resource bundle beside it. An adopter target or a dependency that *does* declare `resources:` is still staged — beside the binary on Linux/Windows, where `Bundle.module` genuinely resolves, and into `Contents/Resources` on macOS with a build-time note that reaching them needs a path rather than `Bundle.module`. **The check that was missing is now in CI**: a new `bundle-smoke` job scaffolds a fresh app (not an Example — those carry fallbacks the scaffold never emits), bundles it, deletes `.build`, moves the bundle, and drives it, asserting the bridge is live; the same job drives it on a simulator. That is the whole test the adopter suggested — build a `.app`, delete `.build/`, launch it — and it would have caught this on the day it landed.

- **CI's simulator drive is opt-in, not a PR gate.** Two runs in a row spent 28+ minutes inside `drive --simulator` and had to be killed, with nothing to show for it. (This entry originally blamed the `xcodebuild` it shells out to; it was a deadlock in the CLI's own output handling, found later — see the v0.9.12 entry above.) It is not slowness: the *same scaffolded app* bundles for macOS on the same runner in **45 seconds**, its graph has no heavyweight C target, and the same cold simulator run takes ~16s on a local Mac with every simulator shut down. Rather than pretend a cause, the job that gates a PR keeps the part that guards the shipped regression (scaffold → bundle → delete `.build` → relocate → drive, ~1 minute), and the simulator counterpart moved to a `workflow_dispatch` + weekly job with a 45-minute cap. Its stdout goes to a file with stderr flowing straight to the log, so the next stall shows which phase it reached — the first two logged nothing, because stderr was captured into a file that only got tailed after the command returned.

- **Every `simctl` call the CLI makes is now bounded, and says which phase it's in.** `simctl` doesn't reliably fail — on a cold machine it wedges — and `deploy --target ios --simulator` had always waited on it forever. The new CI job caught it the hard way: one run sat inside a single simctl call for **39 minutes**, produced no output at all, and had to be killed, which looks exactly like a slow build rather than a stuck tool. Boot gets 300s (a genuine first boot on a cold machine is slow), everything else 120s, and a timeout terminates the child and reports the command with a hint (`xcrun simctl shutdown all`). `drive --simulator` also prints its phases — build → boot → install → launch — so a stall names the stage instead of showing nothing. The wedge itself doesn't reproduce on a local Mac (a cold, all-shutdown run completes in ~16s), which is precisely why the bound and the phase lines matter more than a guess at the cause.

- **An AppImage staged the app's `web/` where nothing looks for it, so a scaffolded Linux app died in `configure`.** The bundler copied it to `usr/share/<exe>/web` — a path with a "for MVP" comment on it — while the runtime resolves a bundled web root beside the binary (`Bundle.main.resourceURL` for a bare ELF binary is its own directory). A scaffolded app's AppImage therefore threw *"couldn't find the app's web/ directory: tried usr/bin/web"* on launch, and only the in-tree examples ran, because they declare `resources: [.copy("web")]` and fall back to their own resource bundle. Same lesson as v0.9.5's: the examples are not the scaffold. `web/` now goes to `usr/bin/web`, next to the binary, matching what the Windows bundler already did. Found while verifying the resource-bundle fix above on a real Linux box, and verified there the same way: a freshly scaffolded app's AppImage, with `.build` deleted and the image moved elsewhere, launches, serves its page, answers `eval` and screenshots itself.

- **The `swift-pwa-macos-x86_64` release asset was an arm64 binary, and had been for several releases.** The release workflow's build matrix declared an `arch` per job and the build step never used it, so on Apple-silicon `macos-15` runners both macOS jobs produced the same arm64 binary — an Intel Mac downloading the asset named for its architecture got `bad CPU type in executable`. Confirmed on the published v0.9.5, v0.9.8 and v0.9.9 assets, which are all arm64 under both names. The macOS jobs now pass `--arch`, and a new step reads the staged binary's actual architecture and **fails the job** rather than uploading an asset that lies about itself. Found by downloading and running what v0.9.9 actually published instead of trusting a green release build — the same check that caught the broken Windows CLI in v0.9.7, which is now the standing habit. Adopters' generated pipelines are unaffected: the `generate-ci` template installs the arm64 asset by name.

## [0.9.9] - 2026-08-11

### Changed

- **Linux tray art now follows the panel's likely polarity, so the agent indicator is legible there too.** The mark was drawn in dark ink on Linux regardless — the same invisible-on-a-dark-panel problem the Windows fix in this release solved by reading the taskbar's theme. Both GTK backends now read the XDG desktop portal's `org.freedesktop.appearance` / `color-scheme` preference and answer `Tray.prefersLightArt`, which an app can use for its own icon as well. The mapping is deliberately asymmetric: only an explicit *prefer light* asks for dark ink, because `color-scheme` describes the user's **app** theme rather than the panel (GNOME's top bar is dark in both modes) and default panels skew dark — so no preference, no portal, no Settings backend and no session bus all choose light. The case that gets wrong is a light panel on a desktop with no portal, which is the rarer one. Verified on real GTK4 and GTK3 boxes across all four answers by standing up a **fake Settings portal**; two measurement traps had to be fixed before the results meant anything (a shared driver port let later cases attach to the first case's surviving process, and a GTK app activates the *real* `xdg-desktop-portal`, which then owns the bus name for the life of that session — so each case needs its own bus).

- **The agent indicator's mark is drawn, adapts to the tray's own theme, and shows whether anything is actually connected.** It was one embedded PNG: a thick ring around a large filled dot, authored as a macOS *template* image — pure black with alpha, which AppKit tints for the menu bar. Nothing else tints, so on Windows and Linux it rendered as a dark blob on a dark taskbar, and the same image stood for both "the door is open" and "an agent is connected". Now the mark is a **ring** while access is open and gains an **inset dot** once a client attaches — the distinction the tooltip already made, readable without hovering — and its ink follows the platform: macOS keeps templating, and the Windows backend reports the taskbar's polarity from `SystemUsesLightTheme` through a new `Tray.prefersLightArt` (defaulted, so no conformance breaks; also useful to an app shipping two variants of its own icon). Four variants is too many to hand-author as byte blobs, so the shape is rasterized in Core behind a ~60-line PNG writer using stored deflate — no dependency, no platform image library, and the geometry is legible as code instead of a hex dump. Verified on the real macOS menu bar in both states, with an actual agent client attached for the second.

### Fixed

- **`SwiftPWACore` hasn't compiled for Android since v0.9.4 — no Android app could be built at all.** `LoopbackSocket` (the BSD/Winsock abstraction under the dev server, the app driver and the agent surface) guards itself with `canImport(Darwin) || canImport(Glibc) || canImport(WinSDK)`. Android is none of those: Bionic's Swift overlay is the `Android` module, so on that platform the whole file vanished while `LoopbackServer` — added in the same PR, with no platform guard — kept referring to it: `cannot find type 'SocketHandle' in scope`, five times, before anything of the app itself was compiled. Nothing caught it because the Android CI job is scaffold-only (the GitHub runner can't reliably cross-compile) and Android verification happens on a device, so the gap is only visible to whoever runs `swift-pwa build --target android` next — which is what surfaced it. `LoopbackSocket` now compiles on Android too (Bionic is POSIX; the only real difference is that glibc alone types `SOCK_STREAM` as an enum, so three near-identical branches collapse to two). Verified by cross-compiling `SwiftPWACore` and then a full `deploy --target android` to a real device. **Note the design question this leaves open:** the agent tool surface now compiles on a platform with no system tray, and so no runtime-owned indicator — the safeguard the surface's consent model depends on. `AgentPlugin` is opt-in and the docs list agent tools as unavailable on Android, so nothing regresses today, but "Android has no way to show the user an agent is attached" wants a decision rather than a default.

- **A folder the user picked on iOS came back unreadable, and no app could work around it.** `dialog.openDirectory` presented `UIDocumentPickerViewController` and returned `urls.map(\.path)` — but a location outside the app container is *security-scoped*, and the grant belongs to the `URL` object, not the path. Nothing ever called `startAccessingSecurityScopedResource()`, and a `String` can't be promoted back into a scoped URL, so the one thing the API handed the app was the one thing that couldn't be used: reads failed immediately, and there was nothing to resolve on the next launch. That breaks the whole "add a library folder" story on iPad, where the interesting folders — iCloud Drive, another app's documents — are exactly the ones outside the container. Reported by an adopter. `dialog.openFile` had the identical defect (same in-place picker, same bare `.path`), and [docs/ios-setup.md](docs/ios-setup.md) claimed both "all work". The runtime now activates each picked URL's scope and holds it for the session **before** flattening the pick to a path, which is the only point at which that's still possible. The launch-file paths (`app.openFile`) already did exactly this on both Apple platforms — the pickers simply never got the same treatment. Verified on a real iPad on the case that was broken: an iCloud Drive folder picked, the app cold-relaunched, the bookmark resolved, and 45 entries listed back — with the minted token read straight out of the device container to confirm it was real bookmark data and not a path in disguise.

- **Android had the same bug in its own idiom: a picked `content://` URI stopped working at the next launch.** Neither the tree picker nor the document picker took a *persistable* permission, so a URI an app stored — the obvious thing to do with the only handle it's given — threw a `SecurityException` on the following launch. Both picks now take a persistable grant (read+write for a tree; falling back to read alone when a read-only document pick refuses the write flag, rather than losing the grant over it). Verified on a Galaxy Z Fold7: pick, `force-stop`, cold start, resolve — the URI comes back, with `dumpsys activity permissions` showing `persisted=0x3` for the app.

- **The runtime-owned agent-access indicator never appeared, on any platform, since it shipped in v0.9.4.** The tray item is the one part of Track B that isn't the app's to opt out of — the design goal being that a developer who skips asking for consent can't also make the fact invisible — and it has never once been shown. `AgentPlugin.register` read `AgentIndicator.installed` and handed the result to the surface, but `register` runs inside the app's `configure`, and every backend installs its tray hook *after* `configure` returns: the value snapshotted was always `nil`. Verified rather than reasoned about, on macOS and Windows, before and after: the menu bar / notification area is byte-identical with access open and closed, and now shows a status item that appears on `agent.enable` and disappears on `agent.disable`. The surface resolves the hook when it has something to publish instead of capturing it at wiring time, so the fix doesn't depend on four backends keeping two lines in the right order. Every piece here had unit tests — the holder's appear/hide/menu behaviour, the surface's state transitions — and the seam between them had none, which is exactly where it broke; there's now a test that drives the real startup order, confirmed by reintroducing the bug.

- **On both Linux backends, a second tray item collided with the app's own and one of them vanished.** Two tray items in one process is not exotic — any app using `TrayPlugin` plus the runtime's agent indicator is exactly that — but it had never happened before, because the indicator never appeared. On **GTK4** the SNI spec fixes an item's object path at `/StatusNotifierItem` and GDBus permits one object per path *per connection*, so the second `register_object` on the shared session-bus connection failed, and failed **quietly** because the shim passed `NULL` for the `GError`; two icons appeared, both answering with the first item's title, tooltip and menu, so the indicator's "Turn off agent access" was unreachable. Each tray now opens its own private bus connection, and the registration errors are reported instead of dropped. On **GTK3** libayatana derives the item's object path from the indicator *id*, which was the fixed string `swift-pwa`, so the second indicator landed on a path the first had registered and the panel was told about only one — the indicator registered nothing at all. Ids are now unique per instance, with the first keeping the bare name so a panel's remembered position for the app's own tray survives. Verified on real GTK4 and GTK3 boxes by standing up a **fake `StatusNotifierWatcher`** — headlessly neither backend is observable without something claiming to be a panel — and confirming two items register, each serving its own menu, with the indicator flipping to `Passive` on revoke. Both bugs were found by looking, not by reasoning: the first diagnosis was confirmed only after a full clean rebuild, because SwiftPM does not rebuild a C target on a *header* change.

- **A PNG tray icon silently didn't load on Windows, leaving a blank slot in the notification area.** `Shell_NotifyIconW` needs an `HICON`, and `LoadImageW(IMAGE_ICON, LR_LOADFROMFILE)` reads `.ico` files only — hand it a PNG and it returns null with no error set, so the icon was simply absent while the tooltip and menu worked. That's the documented cross-platform contract broken on one platform: macOS and both GTK backends take a PNG, `docs/javascript-api.md` shows `tray.setIcon({ path: 'icon.png' })`, and `Examples/HelloPWA` (and the agent indicator) pass exactly that. The Windows backend now repackages PNG bytes into a single-entry icon container before loading — 22 bytes of header, no new dependency, detected by signature rather than extension since the loader sniffs content. Icons are also requested at `SM_CXSMICON` instead of `LR_DEFAULTSIZE`, so tray art is resampled once from the source rather than twice via the 32 px metric, and a load failure now says so on stderr instead of nothing. Verified against the real notification area on a Windows box, blank before and drawn after. Note the art still isn't *legible* there: macOS template images are pure black silhouettes and Windows doesn't tint them, so black-on-dark-taskbar is faint — see the tray notes in [docs/windows-setup.md](docs/windows-setup.md#known-limitations-windows-specific).

- **Refusing `agent.expose: agent.*` explained the wrong thing.** Both forbidden namespaces shared one error string, so an app declaring `agent.enable` was told the `secrets.*` story — that an agent could read any key it can name — and pointed at a fix ("expose the command that uses the key") with no bearing on the actual problem, which is that a tool able to open the gate makes the gate decorative. Each refusal now carries its own reason. On the one surface where a developer is being told *no*, a plausible-but-wrong explanation is worse than a terse one; the test that let it through asserted only that the message mentioned the namespace, and now checks the explanation belongs to the refusal.

- **The release workflow the CLI *emits* still pinned the toolchains we'd just moved off — including one that had shipped broken.** v0.9.8 raised the Linux floor to 6.2 in `.swift-version`, our own `ci.yml` / `release.yml` and [docs/linux-setup.md](docs/linux-setup.md), but missed `swift-pwa generate-ci`'s template, so a project scaffolded or regenerated by 0.9.8 shipped a workflow building Linux on **exactly the toolchain the release notes said renders nothing** — and it would only fail in the cloud on a tag push, as a blank GTK4 window with nothing logged. Reported by an adopter. Sweeping for the rest turned up a second, worse one in the same file: the emitted **Windows** job still pinned **6.1.2**, whose Foundation silently truncates file writes and crashes `init` (the defect v0.9.7 fixed in our own pipeline). Both now match what we ship — 6.2 and 6.3.1 — and both carry a comment naming the symptom, since the previous omission is exactly what a bare version number invites. A new test asserts the emitted workflow's pins are a subset of our own release workflow's and contain no known-bad toolchain, so the template can't quietly fall behind again; verified by reintroducing the reported bug and watching it fail. The generated pipeline is a second copy of our own, and it's the copy nobody notices going stale.

- **`swift-pwa drive`'s default timeout is now 60s, not 30s.** On a software-rendered headless Linux box the *first* WebKit start after a clean build can take longer than 30s, and the resulting timeout is indistinguishable from a broken page — it cost a full investigation into a rendering bug that wasn't there, and it would hit adopters following the CI recipe in the testing tutorial at exactly the wrong moment. A too-low default fails runs that would have worked, while a higher one only costs waiting on runs that are already failing; `--timeout` overrides either way.

### Added

- **Bookmarks: `dialog.openFile` / `dialog.openDirectory` return a durable token per path, and `dialog.resolveBookmark` redeems it.** Holding the grant for the session fixes reading a pick *now*; nothing about a path survives a restart on the two sandboxed platforms, so the results gained `bookmarks` (index-aligned with `paths`, `null` where the platform couldn't mint one) plus a `bookmark` convenience mirroring `openDirectory`'s `path`. The token is **opaque and platform-defined** — Foundation bookmark data on Apple (app-scoped when the app is sandboxed, which is where macOS loses access at relaunch too), the SAF URI behind its persisted permission on Android, and the path itself on Linux / Windows, where there is no grant to preserve. That last case is why the shape is uniform rather than Apple-only: JS stores a token and calls `resolveBookmark` on every platform, instead of branching on `platform.os` for a capability three of five have for free. Resolving re-activates the grant for the session and returns `{ path, stale, bookmark }`; a location that's been deleted or revoked comes back as a `null` path — the app's cue to ask for a fresh pick — while a malformed token, or one minted on another platform, throws. The Swift seam is two defaulted `Dialog` requirements (`makeBookmark(forPath:)` / `resolveBookmark(_:)`) whose default *is* the path-token behaviour, so the GTK and Windows backends inherit it with no code and an external conformance predating this still compiles. `HelloPWA`'s dialogs card demos the full pick → quit → relaunch → resolve → list loop. **Deliberately not built:** surfacing not-yet-downloaded iCloud files. `ubiquitousItemDownloadingStatusKey` and `startDownloadingUbiquitousItem` are plain Foundation on a URL the app already has once access works, so wrapping them would add a command that earns nothing.

## [0.9.8] - 2026-08-11

### Fixed

- **Linux needs Swift 6.2, and building with 6.0.x produced a blank window with no error.** Under **6.0.3** the GTK4 backend never renders: the window opens on `about:blank` and stays there because the custom `pwa://` scheme handler is **never invoked** — `webkit_web_view_load_uri` is called with the right URL and `webkit_web_view_get_uri` accepts it, and the request simply never arrives. Nothing is logged, which makes it about the worst failure shape available: it looks like the app's fault. Verified on a real GTK4 box, same commit either side — an empty document under 6.0.3, a fully loaded page (body 49,243 bytes, bridge present) under 6.2 and 6.3.1. The floor moves to **6.2** in `.swift-version`, the Linux CI + release jobs, and [docs/linux-setup.md](docs/linux-setup.md), which now leads with the symptom so a blank window sends you to `swift --version` rather than into your own code. The trap that hid this: **swiftly honours the `.swift-version` file inside a checkout**, so builds were silently using 6.0.3 while the login shell reported 6.2 — and the GTK4 verification that passed earlier had gone through `Scripts/remote-linux.sh --toolchain 6.2.0`, which pins a working toolchain. Two plausible explanations were tested and **refuted** on the way (the dispatch hook is installed before the load closure runs, and registering the scheme before view creation changes nothing) — recorded so they aren't re-tried. The `android` job keeps its exact 6.2.0 pin: the Swift Android SDK requires the matching compiler.

- **`swift-pwa build` failed for any app declaring `agent.expose`, over web assets the build doesn't use.** Resolving that allowlist means *running* the app for its live command catalog, and that headless dump stages no `web/` and sets no `SWIFT_PWA_WEB_ROOT` — so the generated `configure`'s `WindowContent.bundledWeb` threw and took the build with it. `swift-pwa init` puts `web/` outside the SwiftPM target and declares no resource, so this was the **default scaffold**, not an exotic layout; it was reported by an adopter whose web directory lives outside the package entirely (`../public`), where it can't be a SwiftPM resource and **no `fallbacks:` value could have helped**. The dump creates no window and never reads the path, so `WebRoot.resolve` now returns rather than throws while `HeadlessDescribe.isDumping` — fixing it in the runtime instead of asking every app to pass a workaround. Deliberately *not* fixed by having `agent check` set `SWIFT_PWA_WEB_ROOT` the way `drive` does: that variable is honoured only in driver-compiled builds, so it would have left the same failure in a release-configuration dump. A genuinely missing web bundle still fails loud in the bundler, which is where that check belongs, and that's verified rather than assumed.

## [0.9.7] - 2026-08-11

### Fixed

- **The published Windows CLI couldn't write files, and had shipped that way for three releases.** `swift-pwa init` died with an access violation (`0xC0000005`) having written nothing at all, and `drive shot` printed `Wrote … (419738 bytes)` while leaving **6 zero bytes** on disk — both silently, the CLI reporting success either way. The cause is the **Swift 6.1.2** toolchain the Windows binary was built with, whose Foundation file writing is broken on that platform; it is not the source and not the release configuration, isolated by building the same commit in release mode with 6.3.1 on the same machine against the same running app minutes apart, where both operations are correct. So the Windows CI jobs *and* the release job move to **6.3.1** together — a toolchain we build with but don't ship is one whose bugs we never see, and the reverse. It affected the **published Windows binary only**: building from source with your own 6.2+ toolchain was fine, as were the macOS and Linux binaries, which is why it went unreported on top of `drive` not starting on Windows at all before 0.9.6. The v0.9.4 / v0.9.5 / v0.9.6 Windows assets carry the defect; v0.9.6's notes now say so. The `android` job deliberately stays on 6.2.0 — the Swift Android SDK 6.2 requires the matching compiler, since `.swiftmodule` format isn't ABI-stable across patch releases.

- **CI now runs the Windows CLI it builds instead of only linking it.** Both Windows jobs compiled and link-checked without ever executing the binary, and `swift test` can't run on Windows at all (swift-testing discovery emits 0-byte stubs) — so "green on Windows" only ever meant "it compiled", and that blind spot is what let the two bugs above ship through a fully passing build. `init` is the probe: it writes files and needs no network, git or device, so it exercises exactly the path that broke, and asserting the scaffolded files exist **and** have plausible sizes catches a silent truncation as well as a crash. `release.yml` runs it against the **staged** exe — the bytes actually uploaded — rather than something merely built alongside them. Validated by running the same logic against the defective 6.1.2 binary and confirming it fails.

## [0.9.6] - 2026-08-10

### Fixed

- **The agent-facing CLI surfaces never worked on Windows at all.** `swift-pwa drive` and `swift-pwa agent check` / `codegen` both shell out to `swift`, and both did it as `/usr/bin/env swift` — a path that doesn't exist on Windows, so every invocation died before doing any work with a Foundation error that named no file: *"The file doesn't exist." … WindowsError Code=2*. `Shell.resolveExecutable` has had a full Windows PATH search (including `.exe` / `.cmd` / `.bat` suffixes) since the bundlers needed one, and `Dev.swift` and `Doctor.swift` both carry an explicit `#if os(Windows)` branch for exactly this — the two v0.9.4 surfaces simply didn't get the memo. They now call `swift` by bare name and let the resolver do its job, which is the same binary `env` would have found on POSIX. A third caller, `ExecutableNameResolver`, was failing the same way but **silently**: it catches the error and falls back to the manifest's `binaryName`, so on Windows the "discover the executable from the package" feature had quietly not been discovering anything. Found by running the driver against a real Windows app for the first time — CI builds the code but never launches it, so nothing was exercising these paths.

- **`drive shot` on Windows wrote a correct screenshot and then failed to read it.** `CapturePreview` renders to an `IStream` over a temp file, and the shim opened that file `STGM_SHARE_EXCLUSIVE`, releasing its own reference in the completion handler on the assumption that this closed the file. It doesn't — WebView2 holds a reference of its own and drops it on its own schedule — so the PNG was complete on disk (419,738 bytes of correct, verified render) but still locked when the Swift side read it. Every screenshot failed as `E_HANDLER: the snapshot reported success but wrote nothing`, and because the cleanup couldn't open the file either, each one **leaked a PNG into the temp directory**. The stream now opens `STGM_SHARE_DENY_NONE`. Fixed alongside a doubled path separator (`…\Temp\\swift-pwa-snapshot-….png`) that Win32 normalizes but swift-corelibs `FileManager` does not — a real second bug on the same line, though the share mode was what actually broke it.

- **The Android toolchain is discovered, not demanded — and `deploy` fails up front instead of deep inside Gradle.** `swift-pwa deploy --target android` on a machine with a normal Android install but nothing exported ran the full cross-compile (minutes, ~130 MB of `.so` staging) and only then died on Gradle's own errors: `Unable to locate a Java Runtime`, then `SDK location not found`. Neither mentions swift-pwa, and the first is actively misleading — macOS ships a `/usr/bin/java` **stub** that exists and is executable with no JDK installed, which is exactly why `doctor`'s PATH probe reported the JDK present on the very machine that couldn't run Gradle. New `AndroidToolchain` resolves the SDK, NDK, and JDK from the environment first (an explicit `ANDROID_HOME` / `ANDROID_NDK_HOME` / `JAVA_HOME` always wins) and then from each platform's standard locations — including Homebrew's **keg-only** `openjdk*`, which is never linked where `/usr/libexec/java_home` can see it, and Android Studio's bundled JBR. `deploy` resolves both of Gradle's prerequisites *before* the build (a gap is now a 0.03s error carrying the fix), and passes whatever the ambient environment lacks to `gradlew` as `JAVA_HOME` / `ANDROID_HOME`; `build` writes the resolved `sdk.dir` into the generated project's `local.properties`, so `cd build/<Name>-android && ./gradlew assembleDebug` and opening it in Android Studio work unconfigured too (`sdk.dir` only — an `ndk.dir` AGP doesn't need gets version-matched against its own default and warns `CXX1104` on every module task). `doctor --target android` now *runs* `java` rather than looking it up, gains an Android SDK check, and reports **where** each piece was found — the useful answer on a machine carrying three JDKs; when several are installed it prefers 17 (what the generated project targets), then the newest inside Gradle 8.10's supported 17–22 range, and never one below 17. Verified end-to-end on a real device with `JAVA_HOME` unset and only the broken stub on `PATH`: full build → assemble → install → launch. Docs: [docs/android-setup.md § Toolchain discovery](docs/android-setup.md#toolchain-discovery).
- **Moving or upgrading the NDK broke the next Android cross-compile with an unactionable clang error.** The cached `.pcm` files under `.build/<triple>` embed the NDK's header paths, so a relocated NDK makes the same module resolve through two paths and the build dies with `error: module '_Builtin_stddef' is defined in both …-12XADZNGFAU7K.pcm and …-SRKHNJT8UHKO.pcm` — which names nothing you can act on, and whose fix (`rm -rf .build/*android*`) you have to already know. The existing stale-cache guard covered the *other* hazard (a changed swift-pwa runtime ABI → startup SIGSEGV) but fingerprinted only the runtime sources, so a toolchain move sailed through. The fingerprint now carries the resolved NDK path + Swift Android SDK bundle id alongside the runtime digest, and the stamp file stores the two halves separately so the printed reason names the actual culprit: `note: cleaned .build/aarch64-unknown-linux-android28 — the Android toolchain changed: ndk=<old> → ndk=<new>`. Verified live by pointing `ANDROID_NDK_HOME` at a second path to the same NDK: the first build cleans and succeeds, a repeat build doesn't clean (incremental stays fast). Also fixes a spurious full rebuild the guard caused on its own: the stamp is now written before the *first* cross-compile too, so the second build no longer finds an unstamped cache and wipes a perfectly good one.
- **A Homebrew-installed `swiftly` was invisible to the Android cross-compile.** `locateSwiftly` deliberately avoids `PATH` (swiftly's own `swift` shim narrows `PATH` for child processes) and probed only `$SWIFTLY_BIN_DIR`, `$SWIFTLY_HOME_DIR/bin`, and two pre-1.0 XDG-style paths — none of which is where swiftly 1.x actually keeps its home, `~/.swiftly`. So a normal `brew install swiftly` setup with no env exported fell through to the ambient `swift`, and the cross-compile failed deep in the build with `module compiled with Swift 6.2 cannot be imported by the Swift 6.3 compiler`. `~/.swiftly/bin` is now checked ahead of the legacy locations.

- **A silently unstripped Android APK when the NDK wasn't in the environment.** The strip pass fell back to a bare `strip` on `PATH`, which on macOS is *always* Xcode's Mach-O `strip` — it rejects `--strip-unneeded` on every ELF file, so all ~54 staged `.so` files failed, each logging a `note:`, and the pass then reported `130 MB → 130 MB (saved 0 MB, 0%)` as though that were a result. The APK shipped ~110 MB heavier than it should. `llvm-strip` is now resolved through the discovered NDK (so an SDK-manager NDK at `<sdk>/ndk/<version>` works with no `ANDROID_NDK_HOME` set), a bare `strip` is only trusted on Linux/Windows, and the first failure aborts the pass with a `warning:` naming the tool instead of burying it in per-file notes.

### Documentation

- **Windows needs an interactive desktop to be driven, which nothing said.** WebView2 refuses to create a controller in Windows' non-interactive services session, which is where an SSH shell lands — so over SSH the app starts, the driver attaches, `info` answers correctly, and then every page-dependent verb times out behind one line of stderr (`CreateCoreWebView2Controller failed: 0x80070578`, `ERROR_INVALID_WINDOW_HANDLE`). Nothing is broken; there's just no desktop to put a window on. [docs/app-driver.md](docs/app-driver.md) and the testing tutorial now say so and give the `schtasks /it` recipe for launching into the logged-on session and attaching across it — the control socket is loopback TCP, so it crosses the session boundary fine. The per-backend table's Windows row no longer says "not yet exercised against a running Windows app".

## [0.9.5] - 2026-08-09

### Fixed

- **`swift-pwa drive` now works on an app scaffolded by `swift-pwa init`** — which, embarrassingly, it didn't. Two adopters reported the same thing independently within days of the release: the app dies with *"web bundle not found"* before the driver can attach, and both had hand-written the same workaround (symlink `web/` next to the binary). `drive` runs the bare SwiftPM product, and a plain `swift build` stages no `web/` — only `swift-pwa build` does — so the generated `App.swift` hit its own `fatalError` first. **It escaped every check because both in-tree examples declare `resources: [.copy("web")]` *and* carry a `Bundle.module` fallback the scaffold never emitted**; the examples aren't representative of what `init` produces, so "verified on macOS" verified the one configuration that happened to work. Three cases had to be covered, and only the first had any workaround: web inside the SwiftPM target and declared as a resource; inside but *not* declared (declaring it copies the tree on every build — one adopter's is **2.2 GB of art**); and outside the target entirely (`../public`), where it can't be a SwiftPM resource at all. Fixed on both sides. `drive` now sets **`SWIFT_PWA_WEB_ROOT`** to the project's real `web.directory` — no copy, no staging, and it handles the outside-the-target case — *and* symlinks that directory next to the binary, which rescues apps scaffolded before this change without them touching a line of code.

- **Finding the web bundle is the runtime's job now, not generated code's.** The resolution used to be ~30 lines copied into every `App.swift` at `init` time — the Android asset path, the single-file-exe case and the failure message all frozen in user code, so a fix reached only projects created afterwards, an adopter with a non-standard layout had to hand-edit, and tooling had no way in. New `WindowContent.bundledWeb(entry:spaFallback:fallbacks:)` resolves in order — embedded overlay, `SWIFT_PWA_WEB_ROOT`, Android's asset host, `Bundle.main.resourceURL/web`, then any `fallbacks` (pass `Bundle.module.bundleURL` if you declare `web` as a SwiftPM resource) — and **throws listing every path it tried** instead of calling `fatalError`, because a blank window is the hardest thing to debug. The scaffold is one line. The override is read **only in driver-compiled (debug) builds**: honouring it in a shipped binary would let anyone aim an installed app at web content of their choice, which then runs behind the app's full `invoke` surface.

- **`drive`'s "never announced a driver port" now leads with what happened.** It used to open with "the control socket is compiled into debug builds only — was this a release build?", which is the wrong first hypothesis when the app has just printed a fatal error and exited. It now checks whether the process is still alive: an app that *exited* is reported with its status and pointed at the web-bundle cause, and the release-build theory is offered only when the app is genuinely still running.

## [0.9.4] - 2026-08-08

### Added

- **`swift-pwa mcp --agent` — a running app's own tools, served to any MCP host.** The last piece: the app declares a ceiling, the user opens the door, and this connects an agent to what's behind it. The host spawns the CLI, the CLI attaches to the running app, asks it `describe`, and serves the answer as MCP tools — argument shapes lowered from `BridgeSchema` to JSON Schema **in the CLI**, so fixing a mapping bug is a CLI update rather than an app rebuild, and the developer's `readOnlyHint` / `destructiveHint` passed through untouched for a host to decide what to confirm. Every `tools/call` is forwarded to the app, which **re-checks its allowlist** — the relay is an ordinary local process, and nothing in the security story depends on it behaving. The transport is the one the driver already used (identical frames, identical token), so agent mode is a flag rather than a second protocol; what differs is the verb set, the tool catalogue, and the `initialize` instructions, which now tell an agent it's holding one app's commands for one session rather than general control of a debug build. Deliberate non-behaviours: it **never launches the app** (a second copy would have its agent surface off) and it caches nothing across sessions, so a stale config fails with a clean auth error instead of half-working. No app ships an HTTP server for any of this — the spec notes a local HTTP server needs `Origin` validation and localhost binding against DNS rebinding, which is real attack surface in every shipped binary to save one CLI. **Verified end to end on macOS** with a 19-check probe that speaks MCP over the relay's stdio exactly as a host would: the consent page's own pasted config is what's executed; `initialize` negotiates and returns agent-flavoured instructions; `tools/list` returns the app's two declared tools with correct JSON Schema (`required: ["critter"]`, an empty object schema for the no-argument one) and no driver tools leaking in; `tools/call` returns the app's real result; an undeclared tool is rejected; a failing handler comes back as `isError: true` with the session surviving; and after the user revokes access mid-session the next call is refused. Docs: [docs/agent-tools.md](docs/agent-tools.md).

- **The user's gate on the agent surface — `agent.enable` / `agent.disable`, and a control channel that actually serves the tools.** The ceiling below says which commands are *eligible*; this is the other yes, from the person who's actually exposed. `AgentPlugin(tools:)` compiles the declared list into the app (a manifest isn't reachable from inside a shipped bundle, and a reviewer shouldn't have to read Swift — so `pwa.json` stays the reviewable copy and `swift-pwa build` **fails if the two drift apart**, in either direction, including a changed description or a changed risk annotation). It registers `agent.status` / `agent.enable` / `agent.disable` plus an `agent.state` subscription for the app's *own* consent UI — swift-pwa owns the state, the app owns the asking, because a swift-pwa-drawn dialog would look foreign on five platforms at once. Properties, each of which is a real behaviour rather than a claim: **off at launch always** (no key makes an app exposed from startup); **per session** (nothing persisted — allowing an agent once isn't allowing it forever); **revocation reaches an already-connected client**, not just the next one, since someone turning access off means now; and **a fresh token per enable**, so one written down doesn't outlive its session. The socket half is a new `LoopbackServer` extracted from the driver's accept loop — two real consumers now, and the agent half has to sit *outside* `#if SWIFT_PWA_DRIVER` because unlike the driver it ships in release builds. Two verbs: `describe` (tools + argument shapes as `BridgeSchema`, so fixing a schema-mapping bug doesn't need an app rebuild) and `call`. **The allowlist is enforced in the app**, not in the relay — a relay is an ordinary local process and can't be trusted to filter on the runtime's behalf — and calls resolve by *tool* name, so passing a raw command name that was never declared is refused too. `agent.*` joins `secrets.*` as a refused prefix: a tool that could call `agent.enable` would widen its own access, which would make the user's gate decorative. **Verified end-to-end on macOS** with a 24-check probe that drives the real consent calls through the Track A driver and then speaks the control protocol to the app: off at launch, enable → describe → call, an undeclared tool refused (by tool name *and* by raw command name, with the window title confirmed untouched), a wrong token refused, the app observing that a client is attached, `disable` dropping a live connection mid-session, and a re-enable minting a token that leaves the old one dead. `Examples/HelloPWA` wires the plugin up. Docs: [docs/agent-tools.md](docs/agent-tools.md).

- **The indicator, and a reference consent UI in `CritterFacts`.** While agent access is open, swift-pwa shows a **system-tray status item** — waiting or connected, with a menu item to turn access off. It's runtime-owned: the app doesn't create it, can't restyle it and can't hide it, which is the whole point, since consent can't be *enforced* in native code and the achievable goal is that a developer who skips asking can't also make the fact invisible. A window-title suffix was the cheaper option and fails exactly that test — the app's next `setTitle` overwrites it — where a separate status item doesn't, reuses the tray backends that already exist on macOS / GTK3 / GTK4 / Windows, and gives the user somewhere to revoke from when the app's own window isn't in front of them. It appears from the moment access is **enabled** rather than when a client connects (the port is open either way, and someone who forgot they'd allowed it should still see something); it's **desktop-only**, since iOS and Android have no equivalent surface and the relay is a desktop CLI anyway. The behaviour lives in Core with backends supplying only a `Tray`, so there's one definition of what a user sees rather than five. `Examples/CritterFacts` gains the reference consent UI (`web/agent.html`): the tool list with each command's risk tier read from its annotations, a summary line that says *"2 tools — 2 read-only"* rather than "allow agent access?", a live subscription so it updates when a client attaches, and — once on — the exact MCP host-config snippet to paste, with the port and per-session token. It exposes two of the app's **own** verbs (`critter.list`, `critter.fact`), which is also the "expose the function, never the key" rule in practice: the fact comes from a model, and the agent gets the verb rather than anything it could use to call the model itself. **Verified on macOS**: the consent page rendered and reviewed as a screenshot through `swift-pwa drive` (light/dark tokens, the risk tiering, the enabled/disabled states), the real AppKit `NSStatusItem` path exercised end to end (the app survives show, hide, and repeated cycles, and the embedded icon is written and valid), and the indicator's own behaviour unit-tested against a `MockTray`. The one thing **not** verified is how the status item *looks* in the menu bar: capturing the macOS menu bar needs a Screen Recording grant this environment doesn't have.

- **`agent.expose` — declare, and have the build verify, what your app may offer an AI agent.** An agent driving an app's *own verbs* (`book.open({id})`) beats one poking at pixels on every axis: it's typed, it's a finite list the author chose, it doesn't break when the layout moves, and it can't do anything the author didn't expose. The catalog to build that from already exists — every `registry.register` call carries its argument and result shapes — so what was missing was the part that decides *which* commands, and who gets to decide. That's **two decisions with different owners**, and collapsing them is the mistake this design avoids: the **developer sets the ceiling** at build time (which commands are eligible at all — off by default, so an app that says nothing exposes nothing), and the **user opens the door** at runtime (whether anything is exposed right now). A build flag alone is the developer consenting on the user's behalf; a runtime toggle alone asks the user to approve a surface nobody bounded. This change ships the first half. `pwa.json` gains an `agent.expose` list — command, a required one-line description (it's what the agent reads to decide whether to call it), and MCP risk annotations (`read_only` / `destructive` / `idempotent` / `open_world`) that carry through to `readOnlyHint` &c. and let an app's consent sheet say *"4 read-only tools, 1 that can delete"* rather than "allow agent access?". A stringly-typed allowlist fails **quietly in both directions** — a typo exposes nothing, a rename silently *un*-exposes — which for a security surface is the worst available failure mode, so `swift-pwa build` resolves the list against the app's live command catalog (the same headless `SWIFT_PWA_DESCRIBE` dump `swift-pwa codegen` uses, now shared as `CommandCatalog`) and **fails the build** on a name that isn't there, naming the closest registered commands. `swift-pwa agent check` runs it standalone; `--json` prints the resolved tools exactly as an agent would receive them. Validating means *running* the app, so a cross-compiled Android / iOS build says it skipped rather than skipping silently. Rules the check enforces, each with the reason in the message: unary only (an MCP tool call is one request and one result); object-or-no arguments (MCP's `inputSchema` is an object, and a bare `String` has no field name to give the agent — swift-pwa won't invent one); **never `secrets.*`** — a hard error rather than a warning because it's the one case the risk annotations *can't* describe honestly: `secrets.get` genuinely is read-only, so a consent sheet built from "Read a stored setting, `read_only: true`" stays accurate right up to the moment an agent walks off with the API key. The rule it backs up is *expose the function, never the key*: whatever needs a credential, the app does natively (`myapp.translate`), so the key never crosses the tool boundary — an agent can't do anything with a key that a command couldn't do for it, and everything it *could* do is unbounded. Also never the `__` internals; a warning, not an error, for the general built-ins (`fs.*`, `process.*`, `net.*`, …) because `fs.readText` gives an agent the filesystem rather than a verb from your app's vocabulary. New `BridgeSchema` → JSON Schema lowering: optionals are described but left out of `required`, objects are strict (`additionalProperties: false`) so an invented field is reported rather than silently dropped, string enums become `enum` constraints, and `Int`/`Double` split into `integer`/`number`. **Verified end-to-end against a real app** (`Examples/HelloPWA`, which now declares a three-command surface): the good path reports "3 tools eligible — 2 read-only, 1 unannotated", a renamed command fails both `agent check` and `swift-pwa build` with exit 64 and suggests `demo.importDest`, and a reflected struct lowers to the expected schema (`title` required, `id` optional, `additionalProperties: false`). **Nothing is exposed yet** — the runtime consent gate and serving these tools over `swift-pwa mcp --attach` are the next two cuts. Docs: [docs/agent-tools.md](docs/agent-tools.md); design: [docs/proposals/swift-pwa-app-driver.md](docs/proposals/swift-pwa-app-driver.md).

- **`swift-pwa mcp` — hand a running app to an agent as MCP tools.** The driver's verbs are exactly the loop an agent needs to check its own UI work — change a stylesheet, screenshot the webview, look at the result — but today that loop costs a screen takeover and two TCC grants, which is why nobody runs it and why UI regressions land unverified. `swift-pwa mcp` serves them over stdio as `app_screenshot`, `app_eval`, `app_click`, `app_type`, `app_press_key`, `app_scroll`, `app_windows` and `app_capabilities` (namespaced because an agent host merges tools from every connected server, where a bare `click` would be ambiguous). Screenshots come back as MCP **image content**, so the agent sees the app rather than a description of it, with a `maxWidth` argument that downscales aspect-correctly — a full-resolution Retina capture is ~900 KB of base64 in the agent's context, where 640px wide is ~105 KB and still legible. Hand-rolled JSON-RPC rather than a package, keeping the repo's dependency-free default: the surface needed is `initialize` / `tools/list` / `tools/call` / `ping`. Written against the **2025-06-18 spec** (fetched, not recalled) and verified with a conformance probe that spawns the real server and checks the handshake, version negotiation in both directions, notification handling, tool-descriptor shape, image content, and the `isError`-vs-JSON-RPC-error split. Two spec details it turns on: stdout carries the protocol stream and **must contain nothing else**, so `Shell.run` gained a stdout redirect and every line of build progress now goes to stderr; and messages must not contain embedded newlines, so responses are never pretty-printed. The app is built and launched on the **first tool call** rather than at connect time — an MCP host spawns its servers eagerly, and a window appearing before the agent asked for anything would be a surprise — and the page-ready wait runs before that first call, so an agent doesn't screenshot `about:blank` and conclude the app renders nothing. **Dev-only**, inheriting the driver's three gates; exposing a *shipped* app's own commands to an agent is a different feature needing runtime consent from the end user, tracked as Track B in the proposal. Docs: [docs/app-driver.md](docs/app-driver.md).

- **Synthetic input for the app driver — `input.pointer` / `input.key` / `input.wheel`, and `drive click` / `type` / `scroll`.** Cut 1 could look at an app and evaluate JS in it, but not *use* it: driving the UI meant dispatching DOM events from `eval`, which arrive `isTrusted: false` and skip default behaviour, so a click that should focus a field, insert text or scroll a container simply doesn't. These verbs deliver events into the app's **own event queue** instead — `NSEvent` + `NSWindow.sendEvent` on macOS, `gtk_main_do_event` on GTK3 — so the page gets genuinely trusted events with real hit testing, while nothing goes near `CGEvent.post` / `SendInput` / the HID tap: the cursor never moves, the app needn't be frontmost, and no Accessibility grant is involved. **Verified on macOS**: a driven click produced `pointerdown` / `pointerup` / `click` on the right element with `isTrusted: true` and drove the app's real behaviour end to end (button → DOM handler → bridge invoke → native window title, read back through `window.list`), 20 out of 20 clicks landing; typing `hello` into a real `<input>` produced `value === "hello"` through the responder chain; a `deltaY: 200` wheel event scrolled the page exactly 200px; and all of it worked with the window moved to `(-984, -768)`, almost entirely offscreen. **Verified on Linux GTK3 under Xvfb** — i.e. on a display server with no input device at all, which is what makes this usable in CI: the same click, trusted, driving the same rename; the same typing landing in a real `<input>`; and the wheel scrolling 100 / 250 / 500px on request. GTK3's wheel needed a calibration the DOM contract hides: GDK's smooth-scroll deltas aren't pixels, and measurement (deltas of 1/2/5/10 scrolling 83/166/415/830px — exactly linear at 83) gave the conversion, so `deltaY: 250` now scrolls 250px there as it does everywhere else. The contract is modelled on the DOM's **`PointerEvent`, not a mouse** — `pointerType` (`mouse` / `pen` / `touch`), `pressure`, `tiltX` / `tiltY` — because stylus and touch are their own input paths rather than a mouse with extra fields, and a wire format that said "mouse" would have to break later to admit them. **A request a backend can't honour is refused rather than downgraded**: ask macOS for a `pen` and you get `E_DRIVER_UNSUPPORTED`, since AppKit exposes no synthesizable tablet-pointer event and the page would observe `pointerType: "mouse"` — a stylus test that silently ran as a mouse click would pass while proving nothing. `capabilities.input` is correspondingly structured (`pointer` / `key` / `wheel` / `pointerTypes` / `pressure` / `tilt`) rather than one bool. **Windows and GTK4 get nothing here and can't**: WebView2's `SendPointerInput` lives on `ICoreWebView2CompositionController` while swift-pwa creates a *windowed* controller, and GTK4 removed public event synthesis outright — both report honestly and point the caller at `eval`. CLI: `drive click --selector <css>` (measured and clicked in one round trip, so an animation can't leave you clicking where the button *was*), `--fraction` for viewport coordinates, `drive type <text> --selector <css>`, `drive type --key Enter`, `drive scroll <px>`. Docs: [docs/app-driver.md](docs/app-driver.md).

- **`swift-pwa drive` — script and screenshot a running app without taking over the machine.** Android apps have been programmatically drivable since `setWebContentsDebuggingEnabled(true)` put the page on a CDP socket; on macOS, Linux and Windows the entire story was "`Cmd+Opt+J` opens DevTools for a human", which is why a large share of [docs/manual-test-cases.md](docs/manual-test-cases.md) is marked human-only and why 0.9.2's release note had to say GUI verification was impractical over a headless session. The workaround adopters reach for — screen capture plus OS-wide synthetic clicks — needs the app frontmost (so the machine is unusable during a run), photographs whatever window drifted on top rather than the app, and on macOS wants both the Screen Recording *and* Accessibility TCC grants, which no CI runner can click through. `swift-pwa drive` replaces all of it with an **opt-in loopback control socket**: `drive eval "document.title"` runs JS in the page, `drive shot out.png` writes a PNG of the **webview's contents** (not the screen), `drive windows` lists window ids + geometry, and `drive info` reports what the backend in front of you actually supports. By default `drive` owns the app's lifecycle — build, launch, read the port + token off stdout, run the verb, tear down — so there's no harness to write; `--attach <port> --token <t>` drives an app you launched yourself. `--wait <js>` and the `document.readyState` poll are **client-side** on purpose: putting them in the runtime would buy nothing but round-trips and make every tweak to their semantics an app-binary change. **Three gates,** because a loopback port that evals arbitrary JS is reachable by every local account: the code is behind `#if SWIFT_PWA_DRIVER`, which is defined for **debug builds only** (a release binary doesn't contain the driver at all — build with `SWIFT_PWA_DRIVER=1` to override deliberately); a driver-capable build still doesn't listen until `SWIFT_PWA_DRIVE` names a port; and every frame carries a token minted fresh at launch. Pixels come from each backend's own renderer snapshot — `WKWebView.takeSnapshot` (Apple), `webkit_web_view_get_snapshot` → cairo (GTK3) / `GdkTexture` (GTK4), `ICoreWebView2.CapturePreview` (Windows) — reached through a new `PWAWebView.captureSnapshot()` / `supportsSnapshot` seam that defaults to "unsupported", so `capabilities` answers honestly rather than optimistically. The socket layer is the existing cross-platform BSD/Winsock abstraction written for `swift-pwa dev`, hoisted from the CLI into `SwiftPWACore` as `LoopbackSocket` (same code, `package` visibility, no new dependency) and run in the opposite direction. **Verified end-to-end on macOS** (eval, geometry, and a screenshot of a window moved to `(-984, -768)` — almost entirely offscreen — that came back a complete, correctly rendered 1024×768 viewport, which a framebuffer grab cannot do), and **on both Linux backends** on real boxes under Xvfb (GTK3 + WebKitGTK 4.1 and GTK4 + WebKitGTK 6.0: `capabilities`, `eval`, and a PNG of the real app page). Also verified that a `-c release` build ignores `SWIFT_PWA_DRIVE` entirely, and that `SWIFT_PWA_DRIVER=1` puts the driver back. Windows is implemented and compiles, but is not yet exercised against a running app. **Native synthetic input is not in this cut** — drive the DOM through `eval` — and when it lands it will cover macOS, GTK3 and Android only (WebView2's `SendPointerInput` needs a composition controller we don't create; GTK4 removed public event synthesis). Docs: [docs/app-driver.md](docs/app-driver.md), incl. the wire protocol for writing your own client; design: [docs/proposals/swift-pwa-app-driver.md](docs/proposals/swift-pwa-app-driver.md).

- **`SWIFT_PWA_INITIAL_ROUTE` — open the app's first window somewhere other than its entry.** To land on a specific screen without navigating there by hand, the documented-by-nobody workaround was to inject `location.replace(…)` into the **built bundle's** `index.html` — which mutates the artifact under test, and has to be undone afterwards. `SWIFT_PWA_INITIAL_ROUTE=/doc.html?id=42` makes it a property of the launch instead: the first bundled window loads that path (query string and fragment preserved), everything after uses the declared entry. It's the same shape as the file association an OS-launched app already receives on `app.openFile` — a launch argument that says *where to start* — and it's useful well beyond testing: reproducing a bug report, or a demo that opens mid-flow. Wired on **all five backends** at the point each builds its initial URL rather than by rewriting `WindowContent`, so `web.entry` stays the SPA-fallback document — which is exactly what a router-only deep-link route needs. A leading `/` is optional, an empty value is ignored, and a route containing `..` is refused with a message naming the env var (the scheme handlers guard traversal anyway; this makes the failure legible). `swift-pwa drive --route <path>` sets it for a driven launch. Verified end-to-end on macOS (`pwa://localhost/index.html?card=bridge#log`, with `location.search` / `location.hash` intact) and on both Linux backends.

### Fixed

- **Driven input reaches the page on macOS when the app isn't the active one — which is the whole point of it.** `input.pointer` was silently doing nothing whenever the app wasn't frontmost: the event was built correctly, `NSWindow.sendEvent` accepted it, and the page never saw it, with no error anywhere. The cause is AppKit's click-through rule — a `mouseDown` landing in a window that isn't key is consumed as "click to activate" rather than delivered, unless the view under it returns `true` from `acceptsFirstMouse(for:)`, and `WKWebView` returns `false`. (`window.focus` doesn't help either: making a window key inside an application that isn't active doesn't give it focus.) Driver builds now substitute a `WKWebView` subclass that accepts first mouse; **release builds keep the platform default**, because whether a click into an unfocused window should reach the page is the adopter's design decision, not swift-pwa's — at the cost of one input behaviour differing between debug and release, which is the narrower risk of the two. Re-verified on macOS against a backgrounded app (`document.hasFocus() === false`): 20/20 driven clicks landing at the exact coordinates asked for and `isTrusted`, a click reaching a real button's handler, typing landing in a real `<input>` through the responder chain, the page receiving the exact wheel delta requested (measured at 50 / 100 / 200 / 400 / 800 px), and all of it still working with the window moved almost entirely offscreen. This corrects the v0.9.4 claim that a driven run needs nothing of the sort — it does now, but it didn't before this fix.

- **An app that installs `AgentPlugin` can be built for release.** `AgentSession` used a `JSONValue` key subscript that lived in the driver's own file, which is compiled out of release builds — so the agent surface, which ships in release, failed to compile there while building fine in debug. The helper (and `stringArray` beside it) moved to `JSONValue` proper. Caught by building `-c release`, which the test suite doesn't do.

- **`evaluateJavaScript` now returns real JSON on Apple, matching every other backend.** The protocol documents the result as "the JSON serialization of the JS value", and WebKitGTK delivers exactly that via `jsc_value_to_json` — but the Apple adapter ran `String(describing:)` over WKWebView's bridged Objective-C result, which is Swift's *debug* description: a JS `true` came back as `1`, and an object came back as an unparseable Swift dump. It went unnoticed because the only in-tree consumer (`deliver`) ignores the result; it surfaced immediately once `drive eval` started returning values to a caller. Results are now serialized with `JSONSerialization` (fragments allowed), falling back to the description for the rare value JSON can't represent, and `null`/`undefined` resolve to `nil` rather than the literal string `"<null>"`. **This changes the shape callers see on Apple**: a JS string now arrives JSON-quoted (`"hello"`, not `hello`) — the same as it always has on Linux.

## [0.9.3] - 2026-07-20

### Added

- **`--allow-provisioning-registration` — `--team` now works for free personal Apple teams.** `swift-pwa build --target ios --team <TEAMID>` (and `deploy`) only worked for **paid** teams, whose portal pre-generates a profile for it to find; a **free personal team** has none, so `--team` gave up and every free-team adopter maintained a hand-rolled "minter" shell script instead. The new opt-in flag internalises that script: when `--team` finds no installed profile, swift-pwa generates a **throwaway one-file SwiftUI app project** with the app's own bundle id + `CODE_SIGN_STYLE = Automatic`, builds it against a target device with `xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration` (so Xcode registers the device, creates the App ID, and emits `embedded.mobileprovision`), extracts the profile + entitlements, and signs the real app with them — exactly as if `--provisioning-profile`/`--entitlements` had been passed. The generated project ships an explicit `.xcscheme` because Xcode 16 dropped the implicit-scheme synthesis `xcodebuild -scheme` used to do (without it the build silently produces nothing). New `PersonalTeamProfileMinter` (project-file generation is a pure, unit-tested function — the pbxproj is asserted to parse as an OpenStep plist and the scheme's `BlueprintIdentifier` to resolve to the target); the device is resolved through a **shared `IOSDeviceResolver`** (extracted from `deploy`, so `build` and `deploy` agree on device selection — sole connected device, `--device <udid|name>`, fail-fast on none/several). New flags on `build`: `--allow-provisioning-registration` + `--device` (iOS device UDID for the minter); `deploy --target ios` forwards its resolved device + the flag through. Also fixes signing-**identity** resolution for free teams: a free team's "Apple Development" cert carries a *different* 10-char id in its name than the profile's `TeamIdentifier`, so the old team-string match (`IOSSigning.selectIdentity`) couldn't find it — `IOSSigning.identityForProfile` now matches the identity to the profile's embedded `DeveloperCertificates` by SHA-1 (unit-tested), which is what makes `--team <freeTeamID>` actually sign. **Verified live end-to-end on a real iPad + a real free personal team**: the minter registered the device and minted a 7-day profile for a test bundle id (confirmed `TeamIdentifier` = the free team, `ProvisionedDevices` = the iPad), the identity resolved from the profile's cert, and a full `deploy` produced a signed `.app` and drove `devicectl install` — which Apple then declined only because the device was at the **free-tier 3-apps-per-device cap** (`ApplicationVerificationFailed`), an Apple limit, not a swift-pwa one. macOS-only, opt-in (nothing touches Apple's portal without the flag). Docs: [docs/ios-setup.md](docs/ios-setup.md) (Free personal teams, incl. the 7-day / 3-app caveats); proposal [docs/proposals/ios-free-team-provisioning.md](docs/proposals/ios-free-team-provisioning.md).

- **`swift-pwa deploy` — build → package → install → launch in one command, on every platform.** Getting a build onto a device was `build` plus by-hand steps the CLI didn't own — on Android that's `./gradlew assembleDebug` → `adb install -r` → `adb shell am start`, with wireless-connect and device-selection papercuts on top; an adopter had scripted the whole thing into a ~90-line wrapper, which was the signal to make it a first-class verb. `deploy` is a **superset of `build`** — it runs the full `build` pipeline (same preflight, AI gates, prebuild, web-bundle check, bundler, postbuild) and then owns the last mile `build` deliberately leaves out. Per platform: **android** cross-compiles → invokes the staged project's `gradlew` (the step `build` never runs — it stays staging-only) → `adb install` → `am start`; **ios `--simulator`** builds → boots a simulator if needed → `simctl install`/`launch`; **ios device** runs a **signed** build (`--team <TEAMID>`, or explicit `--sign`/`--provisioning-profile`/`--entitlements`, passed straight through to `build`) → `xcrun devicectl device install app` → `devicectl device process launch --terminate-existing`; **macos** opens the `.app`; **linux/windows** run the produced binary. Deploy-only controls: `--device <serial|ip:port|udid|name>`, `--no-build` (install/launch an already-built artifact — the fast re-test path), `--launch`/`--no-launch`, `--reinstall`/`--no-reinstall`, `--release`. **Device selection is by the platform's own rules** — the sole connected device by default, an explicit `--device` otherwise, and a **clear error, never a silent pick,** when several are attached or none is (Android honors `ANDROID_SERIAL` and `adb connect`s an `ip:port`; iOS resolves physical devices via `devicectl list devices` and passes an explicit `--device` through even when it currently shows disconnected). A real-hardware find is baked in: `adb devices` is tab-separated, and an mDNS/TLS serial contains a space, so a naive whitespace split would drop it and silently hide a multi-device ambiguity. Also folds in an independently-useful **Android cross-compile toolchain auto-discovery**: `build --cross-compile-android` no longer needs a hand-set `export TOOLCHAINS=…` — the CLI derives the Swift release the installed Android SDK bundle needs and selects the matching `.xctoolchain`, which otherwise fails deep with a cryptic "module compiled with Swift X cannot be imported by the Swift Y compiler". macOS-only (the `TOOLCHAINS`/xctoolchain mechanism; a Linux host matches via `swiftly`), non-fatal, explicit `TOOLCHAINS` wins. **Device-verified on a real Android tablet** (full build→assemble→install→launch over wireless adb, plus `--no-build`, `--device ip:port` connect, `ANDROID_SERIAL`, and the multi-device error), the **iOS Simulator** path (build → boot → install → launch), and **macOS** (`open`) on the host; the **iOS-device** path is verified up to the install call (the resolver + `devicectl install` invocation reach a real paired device and bring its connection up) — a full on-device install additionally needs a provisioning profile for the bundle id, the one prerequisite deploy doesn't mint (see [docs/deploy.md](docs/deploy.md); the free-team-provisioning follow-up automates it). Docs: [docs/deploy.md](docs/deploy.md); proposal [docs/proposals/deploy-command.md](docs/proposals/deploy-command.md).

### Fixed

- **An app that enables both `ai.local_llama` and `ai.local_onnx_runtime` can now build for iOS.** With both on-device AI tiers on, an iOS (`xcodebuild`) build failed at `ProcessXCFramework` with `error: Multiple commands produce '…/include/module.modulemap'`. Root cause: the `llama.xcframework` and `onnxruntime.xcframework` were `-library -headers` xcframeworks, and each shipped a `Headers/module.modulemap`; xcodebuild flattens every `-library -headers` slice's headers into one **shared** `Build/Products/<cfg>/include/`, so the two identically-named `module.modulemap` files collided (only that file collides — the `.h` names differ). `swift build` and single-tier apps never hit it (only the xcodebuild path flattens, and one xcframework alone is fine). Fix: both `Scripts/build-llama-xcframework.sh` and `Scripts/vendor-onnxruntime-apple.sh` now emit **framework-style** xcframeworks — a static `CLlama.framework` / `ONNXRuntime.framework` per slice carrying its own `Modules/module.modulemap` **inside the bundle**, which is never flattened into the shared `include/`, so the two coexist. The module maps stay `framework module` with the **explicit C-API headers** (an `umbrella` map would drag the C++ headers — `ggml-cpp.h` → `<memory>`, `onnxruntime_float16.h` → `<cmath>` — into the C module and fail). Module names (`CLlama`, `ONNXRuntime`) and every Swift `import` are unchanged; the re-vendored xcframework `.zip` assets are re-hosted and the `Package.swift` checksums re-pinned. Verified: a two-target package linking both framework xcframeworks builds for iOS (`BUILD SUCCEEDED`); `Examples/CritterFacts` (both tiers) now builds + installs on-device. Diagnosis + proof: [docs/proposals/dual-xcframework-ios-collision.md](docs/proposals/dual-xcframework-ios-collision.md).
- **Four on-device iOS papercuts in the sample apps, surfaced running them on a real device.** (1) **Biometric auth crashed the app** on `ai`/biometric `authenticate` when the bundle declared no `NSFaceIDUsageDescription` — a Face ID probe with the key missing is an uncatchable OS abort, not a throwable error. `SystemBiometricAuth` now **pre-checks** on iOS (`biometryType == .faceID` with no `NSFaceIDUsageDescription` in the bundle) and throws a clean `BridgeError` the JS side can handle, instead of letting the OS kill the process; `Examples/HelloPWA/pwa.json` declares the usage string so the real prompt appears. (2) **`dialog.saveFile` logged an immediate "cancel"** on iOS — HelloPWA's save button now routes to `dialog.exportFile` (the content-first save that actually presents a picker) on iOS, matching the v0.7.9 guidance that `saveFile` is a no-op there. (3) **Native-only demo buttons were enabled on iOS** — the tray and Windows-toast cards now carry `data-only-on` allowlists so they render disabled on platforms that don't have those capabilities. (4) **Content was top-aligned** on tall screens — both `Examples/HelloPWA` and `Examples/CritterFacts` now vertically center their content (`min-height: 100dvh` + `justify-content: center`) so a short deck sits centered on an iPad instead of hugging the top.

## [0.9.2] - 2026-07-18

### Added

- **`SwiftPWAONNX` is now a public product** — apps can author their **own** on-device ONNX backends against the shared `OrtRuntime` / `OrtModelSession` wrapper (arbitrary graph, fp32/fp16/int tensors, and the per-platform ONNX Runtime linkage — Apple xcframework / Android AAR / desktop CUDA·DirectML·CPU EPs — all already solved) instead of vendoring ONNX Runtime a second time or waiting on a bespoke upstream backend per model. The wrapper was previously an internal `.target` only the shipped backends (`SwiftPWASegmentation` / `SwiftPWAImageEdit` / `SwiftPWAStableDiffusion`) could see; its types were already `public`, so this is a one-line product export with no new code, no API change, and no behaviour change. An app runs a model via `OrtModelSession`, exposes it on an `ai.*` command with a `Plugin`, and fetches weights with `ModelDownloader` (`SwiftPWAModelStore`, already public) — entirely app-side. Gated with the rest of the tier behind the ONNX Runtime build flag (`ai.local_onnx_runtime` in the consumer's `pwa.json`), so a build without the tier never links it. Requested by an adopter building an app-side depth-estimation backend. Guide: [docs/ai-plugin.md](docs/ai-plugin.md).
- **File-association *declaration* is now generated on Linux and Windows** (it already was on macOS / iOS via `info_plist` and Android via `android.document_types`). The *receiving* half — an OS-launched file reaching the `app.openFile` JS channel — worked everywhere via the launch-argv scan, but Linux / Windows never emitted the OS-side declaration, so an adopter had to hand-roll it post-bundle. Now: **`linux.document_types`** (`[{ mime_types: [...] }]`) adds a `MimeType=` line to the generated `.desktop` entry **and** a `%F` field code to its `Exec=` (Linux associates by MIME type and needs the field code to actually pass the path); **`windows.document_types`** (`[{ extensions: [...], name? }]`, Windows associates by extension) becomes a `<uap:FileTypeAssociation>` in the generated `AppxManifest.xml` for MSIX builds, and for the portable `.exe` (no installer) the bundler emits `register-file-types.cmd` / `unregister-file-types.cmd` that write per-user `HKCU\Software\Classes` associations pointing at the exe's current location (`%~dp0`). Surfaced while writing [docs/tutorials/opening-files-with-your-app.md](docs/tutorials/opening-files-with-your-app.md), whose "declaring is manual" section is replaced with the two new keys. Generation is unit-tested (incl. XML well-formedness of the MSIX manifest); the CLI (with the Windows-only `WindowsBundler` bundle path) compiles clean on a real x64 Windows box. No runtime change.

- **SPA history-routing fallback under the custom scheme (`web.spa_fallback`).** Apps are served from a custom origin (`pwa://localhost/` on Apple/Linux, `https://swift-pwa.local/` on Windows/Android) that only served files that exist on disk — so a hard reload / deep-link of a nested history-mode route (e.g. `/settings` under a `BrowserRouter`) 404'd, and the documented workaround was hash routing. Opt in with `"web": { …, "spa_fallback": true }`: a request that names no file **and** looks like a client-side route (no file extension) is served `web.entry` instead of 404ing, so the app loads and the router takes over — while a missing *asset* (anything with an extension, like a JS chunk) still 404s honestly. Off by default (non-SPA apps keep strict 404s). Implemented on **all five platforms**: Apple (`WKSchemeHandler`) and Linux (WebKitGTK) via the shared `AssetProvider.resolve` fallback; Windows (native `SetVirtualHostNameToFolderMapping`) and Android (Kotlin `WebViewAssetLoader`) via their resource-interception paths, using a new `AssetProvider.spaFallback(for:)` seam. `WindowContent.bundled` gains a `spaFallback` flag (the `.bundled(directory:entry:)` convenience stays source-compatible); `swift-pwa init` seeds it from `pwa.json`. Surfaced while writing [docs/tutorials/wrapping-a-react-or-vite-app.md](docs/tutorials/wrapping-a-react-or-vite-app.md), whose routing section now leads with the flag. Verified on Apple with an end-to-end WKWebView deep-link test and **device-verified on Android** (a Galaxy Tab S10+: a hard navigation to a nested no-file route served `index.html` while the URL stayed at the route); the Windows backend (`SwiftPWAWindows` incl. `WebView2Adapter`) **compiles clean** on a real x64 box (behavior there mirrors the Android flow and rides the same unit-tested Core resolver; GUI behavior verification is impractical over a headless session).

### Fixed

- **`swift-pwa build` now fails loud when the web bundle is missing, empty, or lacks its entry file** — instead of silently shipping an app with no web assets that then `fatalError`s at runtime with "web bundle not found" (or, on some backends, hands the user a blank window). Every bundler copies `web.directory` with a bare `if fileExists { copyItem }` and no else, so forgetting `npm run build`, misnaming `web.directory`, or a `build.prebuild` that writes to the wrong place all used to fail only at launch — the hardest place to diagnose. `build` now checks the bundle **after** any `build.prebuild` (the declared place to generate `web/`) and before handing off to the bundler, with an actionable message tuned to whether a prebuild ran. Surfaced while writing [docs/tutorials/wrapping-a-react-or-vite-app.md](docs/tutorials/wrapping-a-react-or-vite-app.md), which documented the old silent-skip as "the #1 gotcha"; that note is now corrected to describe the up-front failure.

## [0.9.1] - 2026-07-17

### Changed

- **macOS builds cache the generated `.icns`, skipping the icon toolchain on an unchanged icon.** Building the macOS app icon spawned ~14 `sips` resizes plus `iconutil` on **every** `swift-pwa build --target macos`, even when the source PNG hadn't changed. The rendered `.icns` is now cached under `.build/swift-pwa/icon-cache/`, keyed by the source PNG's content **and** the CLI version (so a changed icon — or a CLI whose icon logic changed — misses and rebuilds). A rebuild with an unchanged icon is a single file copy instead of the full pipeline; `.build` is git-ignored and dropped by `swift package clean`. Behavior is otherwise identical (same `.icns`), and a cache miss / unwritable cache dir falls back to direct generation.

### Fixed

- **Android: `fs.readText` (and any bridge reply) no longer hangs forever when the payload contains `${…}`.** The Android bridge delivered Swift→JS frames by embedding the JSON payload in a **JS template literal** (`` __deliver(`…`) ``), escaping `\` and `` ` `` but not `${`. Any text payload containing `${…}` — e.g. `fs.readText` of a file holding a REST-plugin definition with a `${secret}` auth-header template — was parsed as template interpolation, so JS evaluated `${secret}` → `ReferenceError` inside `evaluateJavascript`, `__deliver` never ran, and the `invoke` promise **never settled** (the call silently wedged; `fs.readBinary` was unaffected because base64 has no `${`). The payload is now delivered as a double-quoted, JSON-escaped string literal (`org.json.JSONObject.quote`), where `${…}` is inert — matching how the Apple / GTK / WebView2 backends already escape it. Android-only (the other backends never used a template literal). **Device-verified on a Galaxy Z Fold7**: a file written with `${secret}`/`${model}`/`${prompt}` content now round-trips through `fs.readText` with matching content instead of hanging. Thanks to the adopter who reported and root-caused this.
- **`swift-pwa doctor` / the `build` tool-preflight no longer false-report every tool missing on Windows.** `doctor`'s toolchain and tool checks probed via `/usr/bin/env swift` / `/usr/bin/env which`, and `/usr/bin/env` doesn't exist on Windows — so a healthy VS Developer shell got `doctor --target windows` marking Swift and the MSVC linker as missing, and `build --target windows` printing a spurious `missing required tool(s): Swift toolchain, MSVC linker (link.exe)` heads-up on a build that then succeeded. The probes are now Windows-aware (`where.exe`); the POSIX path is unchanged. **Device-verified on an x64 Windows box**: `doctor --target windows` now reports Swift + link.exe present.

## [0.9.0] - 2026-07-17

### Added

- **Qwen3-TTS downloadable-model tier (`ai.ensureModel`).** The `SwiftPWAQwenTTS` backend shipped fixed-path only (stage the model directory yourself); it now has a checksum-pinned **download tier** matching the Stable-Diffusion / LaMa backends. `QwenTTSBackend(cacheDirectory:source:)` fetches the ~2.5 GB pipeline (resumable, per-file SHA-256-verified) from the `qwen-tts-vendor` GitHub release into the cache directory on first `ai.ensureModel` (Android routes through the Kotlin `net.downloadFile` RPC, as the image backends do); generation then loads from there. Because GitHub release asset names can't contain `/`, the new **`QwenTTSModelSource`** maps each flat asset back to its **subdir-qualified local path** (`embeddings/…`, `tokenizer/…`), so a fetch lands directly in the layout the fixed-path backend reads — enabled by a small `ModelDownloader` change that now creates each file's parent directory (a plain, non-subpath `fileName` is unaffected). Assembly + re-hosting is `Scripts/vendor-qwen-tts.sh` + `.github/workflows/qwen-tts-vendor.yml` (fetch the Apache-2.0 elbruno ONNX export → convert talker + text-embedding to fp16 → collect + checksum), mirroring `vendor-lama.sh` / `lama-vendor.yml`. **Verified end-to-end**: the full 30-file, ~2.58 GB fetch downloads + checksum-verifies against a local server and then synthesizes speech from the downloaded files (a test that also cross-checks the committed pins against the served bytes). Additive.
- **On-device text→speech (TTS) — the first `ai.generateAudio` backend, `SwiftPWAQwenTTS`.** The `ai.*` audio contract has shipped since v0.7.0 with no generation backend; this fills it with **Qwen3-TTS** (`Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`, Apache-2.0) running fully on-device on the shared `SwiftPWAONNX` tier — the audio counterpart to the Stable-Diffusion / LaMa image backends. New opt-in target **`SwiftPWAQwenTTS`** (`QwenTTSBackend`, an `AIBackend` actor reporting `audioGeneration: true`, backend id `qwen-tts`): `ai.generateAudio({ prompt, voice })` synthesizes 24 kHz mono WAV from text, with **9 preset voices** (ryan/serena/vivian/uncle_fu/aiden/ono_anna/sohee/eric/dylan) and a language selector. The pipeline is a faithful, from-scratch Swift port verified stage-by-stage against the PyTorch reference: a **Qwen2 byte-level BPE tokenizer** (`QwenTokenizer` — verified to reproduce the reference token ids exactly), a memory-mapped `.npy` embedding reader (`QwenNumpy` — the 1.2 GB text-embedding table is row-looked-up on demand, never fully resident), the host-side text projection + codebook embeddings (`QwenTTSEmbeddings`), an HF-faithful sampler (`QwenSampler` — repetition penalty, token suppression, min-new-tokens, temperature, top-k), and the nested autoregressive loop (a **decode-only** talker warm-up + generation, with the code-predictor filling codebooks 1–15) feeding a vocoder. Two subtle bugs were caught in the reference-diff bring-up and are baked into the port: the prompt must use the **non-streaming** prefill layout (full text in the prompt, constant `tts_pad` trailing), and the code-predictor's first codebook logits must be read from the **last** sequence position (a 2-token first step). **Shipping precision: fp16 talker + fp32 code-predictor + fp32 vocoder + fp16 text-embedding (~2.5 GB)** — the fp16-talker choice is quality-safe where naive int8 on the 28-layer talker perturbs sampling. **Verified end-to-end on the real models** (macOS, CPU EP): tokenize → prefill → talker/code-predictor loop → vocoder → WAV, terminating on the codec EOS and producing clean, non-clipping speech. A shared-tier enabler landed too: **`OrtModelSession` now accepts zero-element input tensors** (an empty KV cache on an autoregressive model's first step), which the existing int/fp16 ONNX tests confirm is non-breaking. Deferred follow-ups: a hosted model + `ai.ensureModel` download tier (fixed-path only today), a `CritterFacts` demo arm, on-device (Android) verification, and arbitrary-reference voice cloning (the Base model). Design + bring-up notes: [docs/proposals/v0.9-plan.md](docs/proposals/v0.9-plan.md); backend guide: [docs/ai-plugin.md](docs/ai-plugin.md).
- **On-device Stable Diffusion no longer OOM-kills the app on memory-constrained phones — `ai.unload` + opt-in low-memory eviction.** An adopter hit a whole-app kill at the *end* of a 512² text→image run on an 11 GB phone: logcat showed a device-wide kernel low-memory-killer (lmkd) cascade — the app sacrificed as the foreground process — timed to the **VAE decode** (the pipeline's single largest memory spike) landing **on top of the resident ~1.7 GB fp16 UNet**. `StableDiffusionBackend` loads text-encoder → UNet → VAE lazily but then held **all three sessions resident** for its lifetime, so the decode spiked on ~2 GB of already-live weights. Two fixes. (1) A new opt-in **`lowMemory`** flag on both `StableDiffusionBackend` initializers (default `false`, so desktop/Apple keep the resident-cache latency win) evicts the text-encoder after text-encoding and the **UNet immediately before VAE decode**, within each run — the ~1.7 GB UNet is freed *ahead of* the spike instead of stacked under it; the next run reloads lazily (the trade is per-run graph-reparse latency, incl. per image when `count > 1`, for a much lower peak). (2) A new JS-reachable **`ai.unload`** command (`AIPlugin`) calls the backend's existing `unload()` — previously reachable only as a side effect of a `MultiModelImageBackend` model switch, never from JS — so a shell can proactively free the ~2 GB pipeline after a run (e.g. from a `system.memoryPressure` listener) instead of holding it until the next switch. Default no-op for backends that cache nothing (remote, `NoneBackend`); routes through `MultiModelImageBackend.unload()` to free every entry. `Examples/CritterFacts` opts into `lowMemory` on Android and calls `ai.unload` after each generation. Additive. (Tiled VAE decode — capping the decode's own activation spike — is deferred pending device confirmation that UNet eviction alone resolves the kill.)
- **GTK4 system tray — closes the last plugin-parity gap.** `TrayPlugin` now works on the GTK4 Linux backend, where it had been a no-op stub. GTK4 removed `GtkStatusIcon`, and the GTK3 tray is built on `libayatana-appindicator3` — which links GTK3, so a GTK4 process can't use it; `libayatana-appindicator-gtk4` still isn't packaged on target distros (confirmed missing even on GTK 4.22). Rather than wait on that, the GTK4 tray speaks the two freedesktop tray D-Bus protocols — **StatusNotifierItem** and **com.canonical.dbusmenu** — directly over **GDBus**, with **GdkPixbuf** loading the icon into an ARGB `IconPixmap`. Both `gio-2.0` and `gdk-pixbuf-2.0` are already linked by the GTK4 backend, so this adds **no new external dependency** (new header-only `CStatusNotifierShim`; the GTK4 `SystemTray` mirrors the GTK3 one, differing only in the shim it drives). The cross-platform `Tray` API is unchanged — the same `TrayPlugin(SystemTray())` and `tray.*` JS work on GTK4. The item shows wherever the desktop runs a StatusNotifierHost (Plasma, Sway/waybar, XFCE, GNOME + AppIndicator extension); where none is present the app owns its bus name, registers when a host appears, and never crashes. As on GTK3, only menu-item activations reach the app (`tray.subscribe`); `.click` is never emitted on Linux (the panel owns click semantics). **Verified end-to-end over a real session bus on a GTK4 box** (Xvfb + `dbus-run-session`): a `StatusNotifierWatcher` stub receives `RegisterStatusNotifierItem`, `GetLayout` marshals the menu, a `com.canonical.dbusmenu.Event` routes to the `tray.subscribe` stream, and the icon round-trips as a 4×3 ARGB pixmap — covered by a new `SWIFT_PWA_LINUX_GUI`-gated integration test.
- **Typed JS↔Swift client codegen (`swift-pwa codegen`).** Roadmap #6, phases 1–2. `CommandRegistry` now records a **`CommandDescriptor`** — `{ name, kind (unary/stream/session), args, result, inbound? }` — for every command registered through a `typed:` variant, exposed via `CommandRegistry.descriptors()` and a new built-in **`__bridge.describe`** command (JS reads the typed catalog at runtime, e.g. to feature-detect). Type shapes are a small **`BridgeSchema`** (object/array/dictionary/optional/enum/scalar/void/unknown), **derived automatically with no annotation** by a reflecting `Codable` probe (`SchemaReflection`) — a plain command struct of scalars / strings / optionals / arrays / nested structs gets a full schema for free (no macro, so no swift-syntax in the build graph). Derivation is **lazy** (only when the catalog is materialized, never on the normal command path), so a type the probe can't handle (enums, custom `init(from:)`, cycles) safely degrades to `.unknown` and can be recovered with an explicit **`BridgeType`** conformance (`Codable & Sendable` + `static var bridgeSchema`). `register(_:typed:)`'s result generic is now named (`Result`) not opaque so its shape is capturable (source-compatible); raw `register(_:_:)` registrations get no descriptor but still appear in `__platform.info.commands`. The new **`swift-pwa codegen`** CLI turns a `__bridge.describe` catalog (a `[CommandDescriptor]` JSON) into a typed **TypeScript client** over `__SWIFT_PWA__` — typed command names, payloads, and results across all three call shapes (`invoke`→`Promise`, `subscribe`→`Unsubscribe`, `session`→`BridgeSession`), with dotted names nested into namespaces; `--check` is a CI drift guard (fail if the committed client is stale). Additive. **`swift-pwa codegen` now obtains the catalog headlessly by default** — no manual `__bridge.describe` capture: it builds the app and runs it once with a new **`SWIFT_PWA_DESCRIBE=<path>`** environment variable set (matching the `SWIFT_PWA_GTK4` env-flag convention), which the shipped backends check at the top of `run(configure:)` — when set, the runtime installs the built-ins, runs the app's own `configure` so every plugin (dynamically-named ones included) registers, writes the `[CommandDescriptor]` catalog to that path via a UI-less `HeadlessAppContext` (no-op `createWindow`), and exits **before opening a window**. `configure` must be pure up to registration (createWindow / serveDirectory / emit are inert during a dump, but other side effects still fire — guard them with `HeadlessDescribe.isDumping`). `--catalog <json>` still reads a pre-captured catalog; `--configuration release` overrides the default debug build. Desktop-only (codegen runs on the dev/CI machine, not the device); verified end-to-end generating a 64-command client for `Examples/HelloPWA`. Design: [docs/proposals/typed-bridge-codegen.md](docs/proposals/typed-bridge-codegen.md).
- **Bidirectional bridge sessions (duplex streaming).** The bridge was request → server-stream-out: once JS opened a `subscribe`, it could only *close* it. A new **duplex session** primitive lets JS push frames *into* an already-open subscription while receiving downstream events on the same correlated channel — for live, interactive streams a plain `subscribe` can't express (continuous-mic evaluation, an interactive generation loop, collaborative feeds). Swift side: **`CommandRegistry.registerSession(name, typed:)`**, whose handler receives the decoded open args, a typed **`BridgeInbound<Frame>`** async-sequence of pushed client frames, and returns its downstream `AsyncThrowingStream`. JS side: **`__SWIFT_PWA__.session(cmd, openArgs, {onChunk,onError,onEnd})`** → `{ push(frame), close() }`. Wire: one new inbound frame kind **`push`** (`{v,kind:"push",id,payload}`); no new outbound kind (downstream frames reuse `event`/`end`/`replyError`). Because every backend already funnels JS→Swift frames through one uniform `postMessage` → `inboundFrames()` path, this needed **zero per-backend code** — it works identically on WKWebView / WebKitGTK / WebView2 / Android. `BridgeRuntime` creates the inbound stream synchronously at open (before dispatch), so a `push` the serial pump handles next always finds a live sink; the stream is bounded **drop-oldest** (the native `postMessage` can't be back-pressured — a flooding client loses oldest buffered frames; ack-gate in your own protocol if you can't tolerate loss), with a **per-command bound** (`registerSession(maxBufferedFrames:)`, default 256) and overflow drops **counted** and surfaced to the handler as **`BridgeInbound.droppedCount`**; a malformed push is dropped + logged without ending the session. Verified end-to-end on macOS through a **real WKWebView + real `bridge.js`** (open → push → downstream echo → close) plus unit coverage of the race, malformed-drop, close, and unknown-id paths. Demo: the **Duplex session** card in `Examples/HelloPWA/web/index.html` (push numbers, the handler keeps a per-session running total and streams it back). Precursor to the typed-codegen layer (roadmap #6), which will model this third call shape. Design: [docs/proposals/bidirectional-bridge-sessions.md](docs/proposals/bidirectional-bridge-sessions.md).
- **Delta (binary-patch) updates — smaller updates for desktop.** An app can now ship the **binary diff** between the installed build and the new one instead of re-downloading the whole artifact. The manifest's per-target entry gains an optional additive `deltas` array (`{ from, url, size?, base_sha256? }`); the client picks the patch whose `from` matches its running version, downloads it, **reconstructs the new artifact locally**, and runs the **same** Ed25519 check against the reconstructed bytes before installing — so the delta carries no signature of its own, and trust is unchanged. Any failure (no matching patch, base-SHA mismatch, corrupt patch, reconstruction error) transparently falls back to a full download; the delta is a fast path, never a hard dependency. Apply lands on the three desktop backends. On **Linux AppImage** (`LinuxAppImageUpdater`, base = `$APPIMAGE`) and **Windows portable `.exe`** (`WindowsUpdater(installMode: .portable)`, base = the running EXE) the installed file *is* the signed artifact, so the patch base is on disk directly. **macOS** installs an *extracted* `.app`, so `AppleUpdater` caches the last verified **`.app.tar.gz`** (under `SwiftPWAUpdates/base/`) and patches that — the first update after adopting the feature full-downloads and seeds the cache, then subsequent updates go delta. Android (system-derived APK) is out of scope; MSIX stays full-only; iOS hands the transfer to Apple. **All three verified end-to-end on real hardware** — Linux/Windows updated a 4 MB artifact from a **391-byte** patch; macOS reconstructs a `.app.tar.gz` from a cached base, verifies, extracts, and re-caches the new base for the next cycle (a debunked worry along the way: gzip is *not* fatally diff-hostile here — DEFLATE resynchronizes within a ~32 KB window, so localized `.app` changes yield small patches, measured across incompressible binaries and compressible web bundles). Each backend also proves the corrupt-patch / base-mismatch (/ no-cached-base, on macOS) fallbacks. The zstd engine is **vendored and compiled from source** (a single-file decoder amalgamation as the `CZstd` SwiftPM C target, like `CStbImage` vendors stb) — so there's **no system libzstd, no prebuilt DLL to ship, and no CI provisioning** on any platform; the runtime links the decoder in-process. Publishing: `swift-pwa updater manifest --delta <target>=<from>=<old-artifact>=<patch-url>` generates the patch (via the `zstd --patch-from` CLI — `swift-pwa doctor` now flags it as an advisory for the linux/windows targets), embeds its size + base SHA-256, and writes the `.zstpatch`; standalone `swift-pwa updater diff` / `updater patch` expose the engine. Everything is additive — Tauri readers and older swift-pwa clients ignore `deltas` and full-download. Design: [docs/proposals/delta-updates.md](docs/proposals/delta-updates.md).
- **Automatic background update checks (`auto_check`).** `UpdaterPlugin` gains an opt-in polling mode — `UpdaterPlugin(updater, autoCheck: true, checkInterval: 21600)` (mirrors `pwa.json`'s `updater.auto_check` / `check_interval_seconds`; default 6h, floored at 60s). When on, the runtime checks on launch and every interval after, pushing any available update to JS on the **`updater.updateAvailable`** event-bus channel (payload is the `UpdateInfo`, including `mandatory`; retained, so a late subscriber still gets the latest). Transient check failures are swallowed and retried next tick. Default is unchanged (on-demand only). Closes the gap where the `auto_check` config fields weren't honored at runtime. Docs: [docs/auto-updates.md](docs/auto-updates.md).
- **Mandatory-update kill-switch (`min_supported_version`).** The update manifest gains an optional top-level `min_supported_version`; when a running build is *older* than that floor, `updater.check` and the `available` event from `updater.run` now set **`mandatory: true`** on the resolved `UpdateInfo`, so an app can force the update UI (e.g. block usage until it installs) — a security kill-switch for retiring a build with a critical bug. Builds at/above the floor, or manifests without the field, report `mandatory: false`. Publish it with `swift-pwa updater manifest --min-supported-version <v>`. Purely additive and cross-platform (the flag is derived in `UpdateManifest.updateInfo`, which every backend already routes through); `mandatory` decodes tolerantly so hand-built `UpdateInfo`s passed back through `updater.run` stay compatible. Enforcement is the app's call — swift-pwa surfaces the flag, it doesn't refuse to launch. Docs: [docs/auto-updates.md](docs/auto-updates.md).

### Changed

- **`swift-pwa dev` live-reload now works on Windows** (it was POSIX-only — Windows fell back to `--server <url>`). The built-in server serves your `web/` directory, injects a live-reload client, and refreshes the app on save — now on macOS, Linux, **and Windows**. The socket layer is isolated into a small `DevNet` shim (BSD sockets on Darwin/Glibc, **Winsock** on Windows — the `SOCKET` handle type, `WSAStartup`, `WSAPoll`, `recv`/`send`/`closesocket`, and a byte-written `sockaddr_in` that sidesteps the platform-divergent `sin_addr` union / `sin_family` field type), so the server body carries no per-platform branching and the file-watcher was already portable. Also fixes a latent bug where `swift-pwa dev` shelled out to `/usr/bin/env which` to locate `swift` — which doesn't exist on Windows, so the command failed there **even with `--server`**; it now uses `where.exe`. **Device-verified on an x64 Windows box**: the server binds, serves the injected client, 404s missing files, launches the app via `swift run`, and pushes an SSE `reload` event when a web file changes. Docs: [docs/windows-setup.md](docs/windows-setup.md).
- **The portable Windows `.exe` now embeds a crisp multi-size icon instead of one down-sampled image.** `pwa.json`'s `icon` was already injected into the `.exe` as an `RT_GROUP_ICON` / `RT_ICON` resource (via the Win32 `UpdateResource` API), but as a *single* source image — the shell then downscaled it on the fly for the taskbar / Alt-Tab (32 px) and Explorer small-icon view (16 px), which looked soft. The bundler now pre-renders the source down to dedicated **16 / 32 / 48 / 256 px** slots and lists them all in the group directory, so Windows picks a purpose-rendered image at each size. The largest slot embeds the source PNG verbatim (no re-encode); only sizes strictly smaller than the source are rendered (no upscaling / `.exe` bloat). The down-render is a pure-Swift **area-average, premultiplied-alpha** resize (`WindowsIcon.downscaleRGBA`) so transparent edges don't pick up a dark fringe — decode/encode go through the already-vendored `stb_image` (`CStbImage` gained RGBA decode + an RGBA PNG encoder; the CLI now links it on every host, so the resize + group-directory building are unit-tested in CI on macOS/Linux even though the embed itself only runs on a Windows host). A missing / non-PNG icon still leaves the default Windows icon and never fails the build (reported in the build's one-line icon summary). Docs: [docs/windows-setup.md](docs/windows-setup.md).
- **The webview now lets first-party app JS autoplay media without a user gesture** — across all five backends. The platform default autoplay policy (Android `mediaPlaybackRequiresUserGesture=true`, WKWebView `mediaTypesRequiringUserActionForPlayback=.all`, Chromium's `no-user-gesture` default in WebView2/WebKitGTK) is designed to tame *untrusted* web pages; in a first-party wrapper it just silently breaks `audio.play()` when a long async (e.g. on-device TTS synthesis) elapses between the tap and playback, dropping the transient user-activation so the play is rejected. Since swift-pwa serves the app's own trusted content from `pwa://`, autoplay is now enabled: Android `webView.settings.mediaPlaybackRequiresUserGesture = false`, WKWebView `configuration.mediaTypesRequiringUserActionForPlayback = []`, WebKitGTK 4.1 + 6.0 `webkit_settings_set_media_playback_requires_user_gesture(FALSE)`, and WebView2 `--autoplay-policy=no-user-gesture-required`. Device-verified on Android (a generated TTS clip now auto-plays start→finish). This is what makes the CritterFacts "🔊 Speak" button (below) play automatically.
- **`Examples/CritterFacts` gains a text-to-speech arm — on-device LLM → speech.** The AI testbed now demonstrates `ai.generateAudio` via the Qwen3-TTS backend: a new **Text-to-speech** deck card / `web/speak.html` (a 9-voice picker, the ~2.5 GB first-run download bar, and `<audio>` playback), plus a **🔊 Speak** button on the LLM fact card that speaks the just-generated fact — on-device LLM → TTS in one tap. Wiring: the example's `CompositeAIBackend` gains an `audio:` slot (routing `ai.generateAudio` to `QwenTTSBackend(cacheDirectory:)`, and `ai.ensureModel({ model: "qwen-tts" })` to its download) and — importantly — an **`unload()` that now forwards to every wrapped backend**, so `ai.unload` actually frees the resident on-device pipeline (this was a silent no-op on the composite before, so the image pages' `ai.unload` calls weren't freeing the ~2 GB SD model either — now fixed). A small framework touch enables the download UX: **`QwenTTSBackend.info()` now reports a `models` entry** (`text-to-speech` capability, `downloadable`/`ready` availability derived from on-disk presence, `Apache-2.0`), mirroring `MultiModelImageBackend`, so a page can show the size and flip to enabled once fetched. **Device-verified on a Galaxy Z Fold7**: `ai.info` advertises the model, the 2.58 GB pipeline downloads via the Kotlin `net.downloadFile` RPC (~47 s), then `ai.generateAudio` synthesizes audible speech on the phone CPU (~24 s for a 3.6 s clip). Two fixes came out of that device pass: **(a) an OOM when speaking a fact right after generating one** — device memory tracing showed the app peaking at ~3.95 GB as the vocoder loaded *on top of* the still-resident talker + code-predictor, right after Gemini Nano's fact-gen had eaten ~2.25 GB of device headroom. A new opt-in **`QwenTTSBackend.lowMemory`** (default `false`, `true` on Android in the example) evicts the talker + code-predictor **before** loading the vocoder within each `generateAudio` — the AR loop is done by then — capping the peak (~3.0 GB, verified: RSS drops to ~0.85 GB before the vocoder loads, no crash), mirroring `StableDiffusionBackend.lowMemory`; the example also calls `ai.unload` before speaking. Related: **`CompositeAIBackend.unload()` now forwards to every wrapped backend** (it was a silent no-op, so `ai.unload` wasn't freeing the on-device pipelines — the image pages were affected too). **(b)** a cross-platform build fix: `silu` routes its `exp` through `Double` (the Android NDK has no `Float` `exp` overload).
- **Auto-updater runtime: macOS + Linux (AppImage) + Windows (portable) verified end-to-end + hardened.** The desktop install paths (download → Ed25519 verify → atomic swap → detached-helper relaunch) were implemented but marked **Untested** — only Android's install path had been exercised end-to-end. Drove real v(N-1)→v(N) update cycles against a signed manifest on bundled apps, on each platform's own box:
  - **macOS** (`AppleUpdater`, `ditto` swap): happy path (streaming download, verify, swap, relaunch to the new version), wrong-key rejection (`signature verification failed`, bundle untouched), and a **codesigned** build (signature stays valid across the swap — no stale-codesign SIGKILL).
  - **Linux** (`LinuxAppImageUpdater`, atomic `rename(2)` onto the running AppImage; GTK4 build, headless Xvfb): full cycle confirmed via a self-perpetuating smoke loop plus the on-disk hash flipping v1→v2, **including the cross-filesystem EXDEV copy-then-rename fallback** (stage on tmpfs, install on ext4).
  - **Windows** (`WindowsUpdater` portable, `Move-Item` swap + `Start-Process` relaunch): full cycle confirmed headlessly via a console harness driving the real backend — download (streaming), verify, swap, and a directly observed relaunch. **Windows MSIX** is compile-verified; its `Add-AppxPackage` full E2E is preview (needs a signed package + trusted cert + sideloading).
  - Verification surfaced **four** cleanup gaps the manual test cases assumed but the code didn't do, now fixed: (1) the macOS relaunch **helper script deletes itself** instead of leaving a `swift-pwa-update-*.sh` in `$TMPDIR`; (2) a **failed download / signature check no longer leaves unverified bytes** in the staging cache (all backends); (3) macOS removes the **per-version staging dir after a successful install**; (4) **parity for (3) on Linux and Windows** — the now-empty (Linux) / consumed (Windows) staging dir is dropped post-swap, so it no longer accumulates one dir per version.
  - `UpdaterPlugin` flips to `Yes` for macOS / Linux / Windows in the feature matrix; iOS stays `Untested` (`itms-services://` needs an enterprise cert).
- **Example apps restructured around a horizontal card deck.** `Examples/CritterFacts` (the on-device-AI testbed) and `Examples/HelloPWA` (the native-capability showcase) both present their demos as a single horizontally scrolling, snap-aligned row of cards — one capability per card, the first/last centering in the viewport, and a scrollbar that stays hidden until you hover or scroll. A **dot-pager** under each deck gives a non-swipe, keyboard- and screen-reader-friendly way to jump between cards (each dot `aria-label`led from its card, the active dot tracks the centred card). CritterFacts' tagline is broadened to name its breadth (local LLM, segmentation, magic-erase, prompt-to-image, workflow runner); HelloPWA adopts the same dark/green visual styling and centered header (emoji + title + muted tagline), and collapses its three log panes into one frameless, newest-first, source-tagged log below the deck. Both apps are now **light/dark theme-aware** — dark stays the default, with a `prefers-color-scheme: light` palette that follows the system, and a `window.background_color` `{ light, dark }` pair so the native pre-paint colour matches (device-verified on Android, toggling the system theme both ways). The **duplex-session demo moved from CritterFacts to HelloPWA** (a "Duplex session" card) — it exercises the bridge, not on-device AI, so it belongs with the other bridge/native-feature demos; the `registerSession("demo.runningTotal")` handler moved with it.
- **`Examples/HelloPWA` is now a runnable updater test rig.** Its `Updater` backend is env-selectable — set `SWIFT_PWA_UPDATER_ENDPOINT` (+ optional `SWIFT_PWA_UPDATER_PUBKEY`) to drive the *real* platform backend against a live signed manifest instead of the built-in `DemoUpdater`, and `SWIFT_PWA_UPDATER_SMOKE=1` runs the whole check→download→install flow headlessly on launch (logging `UPDATER_SMOKE` markers). On Windows, `SWIFT_PWA_UPDATER_INSTALL_MODE=msix` selects the MSIX backend (fixing a latent example compile error — `WindowsUpdater` requires `installMode:`). The smoke driver now runs on a cooperative-pool `Task.detached` rather than a `@MainActor` task, so it works under `gtk_main` on Linux (where the MainActor executor isn't drained). This is how the updater manual test cases ([docs/manual-test-cases.md](docs/manual-test-cases.md)) are now driven; see that doc's per-release setup for the recipe.

## [0.8.13] - 2026-07-14

A documentation-focused release: the README is reworked as a current-state pitch, and the tutorial set grows from three guides to fourteen covering the whole "start → build → extend → ship" arc. Two small build/warning fixes ride along.

### Added

- **A full tutorial set under [docs/tutorials/](docs/tutorials/)** — beginner-friendly, Swift-optional, casual-tone walkthroughs, each with honest per-platform notes:
  - **Onboarding & the bridge:** [Hello, World](docs/tutorials/hello-world.md) (nothing → running native app, with a tour of every generated file and live reload) and [Talking to the native side](docs/tutorials/talking-to-the-native-side.md) (the `invoke`/`subscribe`/`on` bridge + registering your own command — unary, streaming, and server-push).
  - **Adoption:** [Wrapping an existing React / Vite app](docs/tutorials/wrapping-a-react-or-vite-app.md) (`--in-place`, `web.directory`, the HMR dev loop, `build.prebuild`, and the SPA-routing fix).
  - **Feature guides:** [Opening files with your app](docs/tutorials/opening-files-with-your-app.md) (`app.openFile` + file associations), [Calling a cloud API with a stored key](docs/tutorials/calling-a-cloud-api.md) (`secrets.*` + `net.*`), [Locking your app with biometrics](docs/tutorials/locking-with-biometrics.md) (`biometric.*`), [Making it feel native](docs/tutorials/making-it-feel-native.md) (window / notifications / tray), [Multi-window apps](docs/tutorials/multi-window-apps.md) (`createWindow` + `events.*`), and [Running a command-line tool](docs/tutorials/running-a-command-line-tool.md) (`process.*`).
  - **Release:** [Shipping your app](docs/tutorials/shipping-your-app.md) (build / sign / distribute on all five platforms + one-tag CI) and an [Auto-updates](docs/tutorials/auto-updates.md) stub (full walkthrough deferred to 0.9, when the desktop runtime updater is verified).
- **AI plugin rows in the README [feature matrix](README.md#feature-matrix)** — `AIPlugin` (text + images), `VisionPlugin`, and `AIWorkflowPlugin`, with footnotes for per-platform backends and opt-in flags. The matrix previously had no AI row at all.
- **An iOS free-team provisioning proposal** ([docs/proposals/](docs/proposals/)).

### Changed

- **README reworked as a current-state pitch.** The status block (a growing per-version changelog digest) is gone; the top is now a stable elevator pitch + capability bullets, with a dedicated [On-device & cloud AI](README.md#on-device--cloud-ai) section in the features zone. The **Why** section leads with concrete wins for indies and teams (web frontend + thin Swift shell; built-in native capabilities incl. App-Store-friendly bundling; built-in AI) rather than "because Swift," and the **Roadmap** is now forward-looking only (shipped work lives here in the CHANGELOG, not as a `(released)` list). Fixed several stale README claims (Windows `.exe` icon ships; image generation shipped in 0.8.3–0.8.6; iOS save works via `dialog.exportFile`; llama.cpp on Windows arm64 is CPU-only). Added a pre-1.0 / feedback-welcome note.
- **Corrected stale custom-command docs.** [docs/swift-api.md](docs/swift-api.md) and [docs/javascript-api.md](docs/javascript-api.md) showed `await ctx.registry.register("x") { … }`; registration is synchronous (no `await`) and uses the `typed:` label — corrected to `ctx.registry.register("x", typed: { … })`, matching the actual API.
- **CLAUDE.md steering notes** for the README: write to current state (never a per-version changelog, at the top or in the Roadmap); add new plugins to the feature matrix; grep for stale hedges when a capability ships.

### Fixed

- **No more spurious `pkg-config` / `libsecret-1` warnings on non-Linux hosts.** Building on macOS (or Windows) printed `failed to retrieve search paths with pkg-config` and two `couldn't find pc file for libsecret-1` warnings, even though the libsecret-backed `LinuxSecretStore` never compiles or links off Linux. Cause: `CSecretShim` depended on the `CLibSecret` `.systemLibrary` **unconditionally**, so SwiftPM kept `CLibSecret` reachable and probed its `libsecret-1.pc` on every host — unlike the GTK/WebKit shims, whose edges are gated `.when(platforms: [.linux])` and are therefore pruned (and silent) off Linux. The `CSecretShim → CLibSecret` edge is now gated the same way, matching the GTK pattern; the Linux `secrets.*` backend is unaffected (the edge is still present on Linux). Purely a build-graph fix — no runtime change.
- **Cleared two compiler warnings in the Apple `WKWebViewAdapter`.** Dropped a redundant `(unsafe)` from `nonisolated(unsafe) let stream` (its `AsyncStream<InboundFrame>` type is already `Sendable`), and switched `evaluateJavaScript(_:)` from the completion-handler `WKWebView.evaluateJavaScript` (which the compiler flags in favor of the async form) to the `async` variant, run on a `@MainActor` helper so the argument bridging stays on the main actor and only `Sendable` values cross the isolation boundary. Behavior is unchanged — verified by the WKWebView round-trip integration test (the `deliver` path evaluates to `undefined`, and the async form returns `nil` there without the historical nil-trap crash on the macOS 15+/iOS 18+ deployment targets).

## [0.8.12] - 2026-07-13

### Added

- **`RESTImageProvider` — one config-driven provider that adapts to arbitrary cloud image APIs from a descriptor, instead of a hand-written Swift conformance per service.** A declarative `RESTImageAPISpec` (Codable) describes an API — endpoint template, a JSON request template with `${key}` placeholders (or a multipart form for edit endpoints), one-shot or async submit→poll flow, and a tiny JSONPath (`a[*].b.c`) to the response images (base64 or a URL to fetch) — and the descriptor **travels in the call**, so a running web app can point at a new API with no rebuild. Auth/endpoint come from the `AIConnection` (a `secretRef` resolved into `${secret}` server-side, so the key never enters JS). It serves **both** surfaces: `AIWorkflowProvider` (`ai.run` / `ai.describeInputs` — generic pass-through, or a pinned preset) and `RemoteImageProvider` (`ai.generateImage` in the `MultiModelImageBackend` switcher, standard fields mapped by convention). Ships presets as data: `.imagen`, `.openAICompatible`, `.geminiImage` ("nano banana"), `.openAIEdit` (multipart edits), `.qwen` (async `qwen-image` / `wan*-t2i-*`), `.qwenImageMax` (the flagship `qwen-image-max` on DashScope's synchronous multimodal-generation endpoint). **Verified live against real APIs** with one config engine: Google **Gemini** `:generateContent` (2.0 MB), **Imagen** `:predict` (1.49 MB, 16:9), **OpenAI** `gpt-image-1` generations (1.47 MB) **and multipart edits** (2.2 MB), and **Qwen/DashScope** both the async `qwen-image` submit→poll (~8 s) and the synchronous `qwen-image-max` (2.6 MB) — DashScope needs the region base + model to match the account (an international key uses `dashscope-intl.aliyuncs.com/api/v1`). `Examples/CritterFacts` `web/workflow.html` gains a **Gemini image (nano banana)** picker option backed by `RESTImageProvider` + the `.geminiImage()` preset, keyed by `secretRef` (reusing the stored `google-ai` key — no key in JS). Findings + design in [docs/proposals/flexible-rest-image-provider.md](docs/proposals/flexible-rest-image-provider.md); usage in [docs/remote-ai.md](docs/remote-ai.md). Deferred: conditional parameter coupling (e.g. Imagen's seed→watermark) stays on the hand-written `RemoteImageProvider` seam.

## [0.8.11] - 2026-07-13

### Added

- **Runtime workflow surface is now provider-agnostic — `ai.run` / `ai.describeInputs` work beyond ComfyUI (Phase 2).** v0.8.10 shipped the runtime door with a single conformance (`ComfyUIWorkflowProvider`); the Core contract was already generic, so this adds the other providers so the *same* JS page drives all of them from a picker:
  - **`ImagenProvider` now conforms to `AIWorkflowProvider`** (`providerID: "imagen"`) — a **fixed-schema** cloud provider. `ai.describeInputs` returns a static control set (`prompt`, a `model` enum when more than one is configured, an `aspectRatio` enum, `count` 1–4, `seed`) with no graph and no network probe; `ai.run` maps the inputs onto its `:predict` call and streams a coarse `running` → `image`(s) → `done` (one-shot — no per-step progress). Auth for this path prefers a key carried on the **connection** (a header resolved from `secretRef` server-side — the fully-runtime route) and falls back to the key injected at construction, so an app can drive Imagen either way; no connection is required.
  - **`AIBackendWorkflowProvider` (Core) adapts *any* `AIBackend`** into a fixed-schema `AIWorkflowProvider`, so on-device image models (Stable Diffusion, LaMa) answer the runtime surface through the same UI. One generic adapter covers every current and future backend (they stay unaware of the workflow surface); the schema is derived from the backend's `AICapabilities` — a text→image backend advertises `prompt`/`negativePrompt`/`steps`/`guidanceScale`/`seed`/`count` (+ a `model` enum when it hosts several), a pure inpainter (`imageEditing` only, e.g. LaMa) advertises just `image`/`mask` — and `runWorkflow` bridges the backend's `generateImageStream` (per-step `progress` → `.progress`, terminal images → `.image`, then `.done`). No `jobId`/recovery (on-device runs aren't re-attachable).
  - **`AIWorkflowPlugin` no longer requires a `connection`** in `ai.run` / `ai.describeInputs` — it's optional now (fixed-schema and on-device providers ignore it; the plugin supplies an `about:blank` placeholder). ComfyUI still needs a real one to reach the box.
  - **`Examples/CritterFacts` `web/workflow.html` gained a provider picker** (ComfyUI / Imagen / on-device); the endpoint + graph fields show only for ComfyUI, and the same schema→controls renderer builds each provider's inputs. CritterFacts registers all three providers in one `AIWorkflowPlugin`. Docs in [docs/remote-ai.md](docs/remote-ai.md) and [docs/javascript-api.md](docs/javascript-api.md).

  **Resolves open question Q3** (schema for non-image modalities): `AIInputField.Kind` (`text`/`int`/`float`/`bool`/`enum`/`seed` + the image-specific `image`/`mask`) already generalizes to text/audio provider inputs — no new kinds were needed for Phase 2; a future audio/video *output* verb reuses the same field kinds and only adds a binary input kind if a provider needs one. Phase 2 of [docs/proposals/runtime-workflow-plugin.md](docs/proposals/runtime-workflow-plugin.md).

## [0.8.10] - 2026-07-13

### Added

- **Runtime, JS-reachable AI workflows — `ai.run` + `ai.describeInputs` (`AIWorkflowPlugin`).** v0.8.9's ComfyUI runner was Swift-only and build-time (one graph bound per `ComfyWorkflowProvider` in `App.swift`). This adds a runtime door: a web app can hand a provider a **graph *and* a connection per call** and run it — no Swift rebuild, no per-endpoint provider. New opt-in `AIWorkflowPlugin(providers:client:secrets:)` (shares the `ai.*` namespace like `VisionPlugin`) exposes:
  - **`ai.describeInputs`** → `AIInputSchema` — the workflow's overridable inputs (each an `AIInputField`: `key`/`label`/`type`/`value`/range/`options`/`isImage`), keyed `"<nodeID>/<inputName>"` so a run maps straight back to node locations. Degrades to a graph-only schema (`degraded: true`) when the box is unreachable, so a pasted graph is authorable before the box is up.
  - **`ai.run`** (subscribe) → `AIRunEvent` — `progress` (coarse `queued`→`running`) → `image` (echoing the resolved seed + PNG dimensions) → `done`. `unsubscribe()` (or window close) tears the stream down and the provider `POST`s `/interrupt`. A unary `invoke` form also works.
  The **connection travels in the call** (`baseURL` + open-bag `headers` + a `secretRef` resolved **server-side** against `secrets.*` and substituted into `${secret}` header placeholders, so key material never enters JS). New Core contract: `AIConnection`, `AIInputField`/`AIInputSchema`, `AIRunEvent`, `AIWorkflowConfig`, `AIWorkflowProvider`. The first conformance, **`ComfyUIWorkflowProvider`** (`SwiftPWARemoteAI`), is stateless w.r.t. the endpoint and reuses the v0.8.9 binding engine + `/upload/image` + seed policy. **Verified live** against a real ComfyUI: introspection off live `/object_info` (keys + types + ranges + option counts), a Qwen-Image txt2img run, and cancel-mid-run (`/interrupt`). Phases 1a + 1b of [docs/proposals/runtime-workflow-plugin.md](docs/proposals/runtime-workflow-plugin.md).
- **Per-step ComfyUI progress over a new `NetworkClient` WebSocket transport (Phase 1b).** `NetworkClient` gained **`openWebSocket`** (receive-only, `NetWebSocketRequest` → a stream of `NetWebSocketEvent`), implemented on **`URLSessionNetworkClient`** (Apple / Linux / Windows via `URLSessionWebSocketTask`'s async `receive()` — the completion-handler form isn't on swift-corelibs Foundation) with a throwing default so a client without it degrades gracefully. `ComfyUIWorkflowProvider` now opens `/ws?clientId=…` and translates ComfyUI `progress` frames into fine `.progress` events carrying `value`/`max`, alongside the coarse `queued`→`running` floor. **Verified live**: an 8-step Qwen run streamed 8 real per-step frames (`8/8`) then the image + echoed seed. (Phase 2 = cross-provider schema; Phase 3 = example + JS-API docs.)
- **`openWebSocket` on Android — the `net.ws.*` RPC (completes Phase 1b's cross-platform parity).** Android's `net.*` runs on `HttpURLConnection`, which has no WebSocket (and `java.net.http` isn't on Android), so `AndroidNetworkClient` previously inherited the throwing `openWebSocket` default and per-step ComfyUI progress stayed coarse there. It now opens the socket via a new Kotlin **`net.ws.open`/`net.ws.close`** RPC over **OkHttp** and forwards each inbound frame to Swift as a host-event (the side-channel pattern `net.downloadFile` already uses for byte progress), so `ComfyUIWorkflowProvider` gets the same `/ws` per-step `.progress` on Android as elsewhere. **On-device (Galaxy Tab S10+): a real 15-step run streamed every step live** (`1/15`…`15/15`) then the image. (Some mobile radios abort a fully *idle* LAN socket within seconds — a fast/cached run that never sustains traffic can lose the socket between events; the provider's reconnect covers it, and coarse `queued`→`running` polling is the floor.)
- **`ComfyUIWorkflowProvider` per-step progress now parses current ComfyUI `progress_state` frames**, not only the legacy flat `progress` type (recent ComfyUI emits `progress_state` with per-node `{value,max,state}` — the provider reports the *running* node's `value`/`max`). Without this, `/ws` progress silently produced nothing against a current server. `streamProgress` also **reconnects a dropped socket until the run ends** — best-effort, harmless on a stable connection, and it recovers on networks that reap idle sockets. Both frame types are covered by unit tests.
- **Example + JS-API docs for the runtime workflow surface (Phase 3).** `Examples/CritterFacts` gains a **`web/workflow.html`** page — paste/load a ComfyUI "Save (API Format)" graph, `ai.describeInputs` → controls built from the schema (text/int/float/bool/enum/image/mask/seed, with sliders from the box's ranges and dropdowns from its model-file lists), then `ai.run` with the values (including a picked reference image) → a live progress bar (coarse + per-step) → streamed images → cancel. Wired via `ctx.use(AIWorkflowPlugin(providers: [ComfyUIWorkflowProvider()], client:, secrets:))` (unconditional — it only needs a `NetworkClient`). `ai.run` / `ai.describeInputs` are now documented in [docs/javascript-api.md](docs/javascript-api.md) and [docs/remote-ai.md](docs/remote-ai.md) ("Running an imported workflow from JS"). (Phase 2 — the cross-provider schema for Imagen / on-device — stays deferred.)
- **`ai.run` job recovery.** Every `ai.run` event now carries a `jobId` once the job is submitted (`AIRunEvent.jobId`), and `ai.run` accepts a `jobId` (`AIWorkflowConfig.jobId`) to **re-attach to an existing job instead of submitting a new one** — for when a stream is torn down mid-run (e.g. the app is backgrounded and a `.local` mDNS poll fails). `ComfyUIWorkflowProvider` verifies the id against `/history` + `/queue` and resumes streaming, returns the finished outputs, or fails fast if the id is gone (no re-submit, no polling to the timeout). `web/workflow.html` remembers the id and reveals a **Resume last run** button on error. Unit-tested (re-attach returns outputs without re-submitting; unknown id fails fast).

## [0.8.9] - 2026-07-13

### Added

- **`ComfyUIProvider` can run *any* imported API-format workflow — a generic workflow runner with input introspection.** The shipped provider ran one hard-coded `txt2imgSDXL` graph and surfaced only `CheckpointLoaderSimple` checkpoints, so a real ComfyUI box's Qwen-Image / Flux / edit / upscale pipelines never appeared and there was no image input. The fix isn't a template per architecture (a treadmill chasing ComfyUI's whole node ecosystem) but the underlying primitive: **run an adopter-supplied graph, given named inputs.** ComfyUI's "Save (API Format)" export is a graph `POST /prompt` accepts verbatim, so the app owns importing/storing/selecting workflows and the framework owns *executing* them — no per-architecture code. Two new entry points on `ComfyUIProvider`:
  - **`runWorkflow(graph:inputs:bindings:client:outputDirectory:)`** — submit an API-format graph with named values bound into it, reusing the existing submit→poll→fetch choreography. Inputs are **arbitrary and open** (`WorkflowInputValue`: `text` / `int` / `float` / `bool` / `seed(Int?)` / `image(Data)` / `mask(Data)` / `raw(JSONValue)`) — not a fixed prompt/image/seed set; the bound set *is* the "overridable from the UI" whitelist. A binding maps an input to **a list of node-input locations**, so one logical input fans out to every node that uses it (e.g. a shared `width`); `.image`/`.mask` are uploaded to `/upload/image` first and the returned filename bound into the target `LoadImage`; a `.seed(nil)` gets a fresh random seed per run (resolved once, echoed on the results). Binding is either **explicit** (`.at(node:input:)` / `.at([…])` / `.imageAt(…)`) or by the **title convention** (a node whose `_meta.title` equals the input name — its like-named input, else its sole literal input).
  - **`inspectWorkflow(graph:client:titledOnly:)`** — list a workflow's overridable inputs so a UI (or an adopter's binding map) is built automatically instead of hand-declared. Crosses the graph's *literal* inputs (widget values — `[nodeId, slot]` connection inputs are excluded) with `GET /object_info` for each input's real type, range (min/max/step), combo options (sampler names, per-box model file lists), and image flag. Each `WorkflowInput` carries its `(nodeID, inputName)` binding location, so a chosen input becomes a `WorkflowBinding` directly. Returns *candidates* (the app filters; `titledOnly` narrows to author-tagged nodes). (Real exports don't title nodes semantically — the reliable path is introspect-then-bind-by-node-id, not the title convention.)
  - **`ComfyWorkflowProvider`** — the turnkey `ai.*` adapter: wraps one imported workflow + a `FieldBindings` map (which node each standard `AIGenerateImageRequest` field drives) as a `RemoteImageProvider`, so it drops into the shipped `MultiModelImageBackend` switcher next to on-device / other remote models and `ai.generateImage({ model: "comfy:workflow:…", prompt, image })` routes to `runWorkflow` — no ComfyUI-specific JS. (For inputs a request can't model, call `runWorkflow` directly.)

  The existing `txt2imgSDXL` template and checkpoint discovery are unchanged; the runner shares one copy of the ComfyUI job choreography with them (extracted as `submitAndFetch`). **Verified live against a real ComfyUI instance:** `inspectWorkflow` parsed a live `/object_info` (INT/FLOAT/STRING/COMBO with real ranges and per-box model-file lists); `runWorkflow` ran an imported Qwen-Image txt2img (bound prompt + seed) → a real 1024² PNG, an esrgan upscale (uploaded image → 4096²), and a Qwen-Image-**Edit** (uploaded image + prompt → edited image). Also validated offline against real exported Qwen / depth / upscale / IP-Adapter graphs (literal-vs-connection detection, object-valued rgthree widgets, binding). Phases A + B of [docs/proposals/comfyui-run-imported-workflows.md](docs/proposals/comfyui-run-imported-workflows.md).

## [0.8.8] - 2026-07-12

### Added

- **`secrets.*` plugin — store API keys and other small secrets in the OS secure store.** A new opt-in `SecretsPlugin` (registered like `net.*` / `process.*`: `ctx.use(SecretsPlugin(KeychainSecretStore()))` on Apple, `ctx.use(SecretsPlugin(AndroidSecretStore()))` on Android) exposes `secrets.get` / `secrets.set` / `secrets.delete` over a `SecretStore` seam. The motivation is the remote-AI tier: `ImagenProvider` takes its API key from an injected closure and swift-pwa never persists it — but every real app then needs a *secure* place to keep that key, and the honest answer is the OS keychain, not `localStorage` / a plaintext file / `pwa.json`. `secrets.get` returns `{ value: null }` for a missing key (not an error); a store failure is `E_SECRETS`. Three stores ship: **`KeychainSecretStore`** (Apple — `kSecClassGenericPassword`, service = bundle id, `kSecAttrAccessibleAfterFirstUnlock`; verified round-tripping through the real macOS Keychain), **`AndroidSecretStore`** (Keystore-backed `EncryptedSharedPreferences` over a new Kotlin `secrets.*` RPC — the Swift side can't reach the Keystore directly, same bridge pattern as `net.request`), **`WindowsSecretStore`** (DPAPI `CryptProtectData`, user scope → an encrypted blob under `%LOCALAPPDATA%`; `Crypt32` linked for `.windows`; DPAPI plumbing verified by a machine-scope round-trip on an x64 box — note user-scope DPAPI needs an *interactive* logon, so a network/SSH session hits `ERROR_ACCESS_DENIED`), and **`LinuxSecretStore`** (Secret Service via **libsecret** → GNOME Keyring / KWallet, through a small C shim `CSecretShim` over a `CLibSecret` systemLibrary — `pkgConfig libsecret-1`, `.apt(["libsecret-1-dev"])`; Linux-only, so macOS/Windows never probe pkg-config; **runtime-verified** on a Linux box — set/get/overwrite/delete round-trip against a real keyring, and a graceful `E_SECRETS` when no Secret Service is running). `NoneSecretStore` (throws `E_SECRETS`) is the default when no store is injected. **Runtime prerequisites:** Windows DPAPI needs an interactive session; Linux needs a running Secret Service (a desktop keyring — the runtime lib `libsecret-1.so.0` already ships as a WebKitGTK dependency, so any machine that runs the app has it; `libsecret-1-dev` is build-only). Enables the `needsSetup → enter key → ready` flow for cloud providers with no build-time key. `Examples/CritterFacts` demonstrates the whole loop: a **Google Imagen** arm now sits in the prompt-to-image switcher next to the on-device and ComfyUI models, advertising `needsSetup` until the user pastes a key (the page reveals a password field, `secrets.set` stores it, `ai.info()` re-reports `ready`), with a "clear key" affordance (`secrets.delete`) — the Imagen `apiKey` closure reads straight from the store, so no re-init on key change. **Device-verified end-to-end on a Galaxy Tab S10+** (via CDP): `secrets.set`/`get`/`delete` round-trip through the Keystore-backed store; a missing key returns `{ value: null }`; the stored key **survives a full app restart**; and with a real key stored, Imagen reports `ready` and returns a ~1.5 MB PNG from the cloud through the `net.request` RPC (then reverts to `needsSetup` on `secrets.delete`). Part 1 (+ the CritterFacts arm) of [docs/proposals/remote-ai-key-management.md](docs/proposals/remote-ai-key-management.md). See [docs/secrets.md](docs/secrets.md) and [docs/remote-ai.md](docs/remote-ai.md#secure-key-storage).
- **Remote AI image generators — `SwiftPWARemoteAI`, with Google Imagen and local-network ComfyUI providers.** A generalized *remote* image `AIBackend` so a cloud API or a LAN appliance is a drop-in next to on-device models in the same `ai.generateImage` surface (and the same `MultiModelImageBackend` switcher — a remote backend is just another `AIBackend`, routed by `request.model`, and inherits the no-op `unload()` so the switcher's evict-on-switch costs it nothing). `RemoteImageBackend` supplies the whole `AIBackend` conformance (info aggregation, inline-vs-`outputDirectory` output, error mapping) around a small **`RemoteImageProvider`** seam that owns the per-API choreography given an injected `NetworkClient` — so **a new API is just another conformance, no framework change.** Two shipped providers: **`ImagenProvider`** (Gemini REST `:predict`, `x-goog-api-key` from an injected `apiKey: () async -> String?` closure — the key is never stored by swift-pwa; catalog Imagen 4 + Imagen 3, routed by `request.model`; `width`/`height` → nearest `aspectRatio`; an explicit seed sends `addWatermark: false` + a single sample per Imagen's constraint) and **`ComfyUIProvider`** (raw `POST /prompt` → poll `GET /history/{id}` → `GET /view`, driven by a bring-your-own `ComfyWorkflowTemplate` graph + field patches with a turnkey `.txt2imgSDXL(checkpoint:)` default). Consumes the `net.*` plugin's `NetworkClient`, so it's cross-platform (on Android, plain-http LAN endpoints use `android.network.cleartext_domains`). **Verified live end-to-end** against real services — a 1024×1024 PNG round-tripped from both Google Imagen (cloud) and a real ComfyUI instance (LAN) through `URLSessionNetworkClient` → provider → decode; the live tests are opt-in (`GEMINI_API_KEY` / `SWIFT_PWA_LIVE_COMFY`, skipped otherwise). Phase 1b of [docs/proposals/remote-ai-backends.md](docs/proposals/remote-ai-backends.md). See [docs/remote-ai.md](docs/remote-ai.md).
- **`net.*` plugin — a native, CORS-free HTTP client for the web app, plus a shared `NetworkClient` transport.** A new opt-in `NetPlugin` (registered like `process.*`: `ctx.use(NetPlugin(URLSessionNetworkClient()))` on desktop/Apple, `ctx.use(NetPlugin(AndroidNetworkClient()))` on Android) exposes **`net.request`** (unary request/response — method, headers, base64 body, timeout → `{ status, headers, bodyBase64 }`; a non-2xx is a `status`, not an error, only a transport failure throws `E_NET`) and **`net.download`** (stream a file to a native path with `progress` events + a terminal `done`, optional headers and `sha256` verification). It runs on the Swift side of the bridge, so it isn't bound by the WebView's same-origin/CORS policy and can set headers a page can't (`Authorization`, custom `User-Agent`), reach LAN appliances, and call third-party APIs that omit CORS headers. Backing it is a new **`NetworkClient`** seam in `SwiftPWACore` (`send` / `download` over `NetRequest`/`NetResponse`/`NetDownloadRequest`) with two implementations — `URLSessionNetworkClient` (Apple/Linux/Windows, Foundation `URLSession`) and `AndroidNetworkClient` (routes through a new Kotlin `net.request` RPC, since swift-corelibs `URLSession` on Android has no injectable CA store). The same `NetworkClient` is the transport the forthcoming remote-AI image backends consume — one HTTP abstraction, one Android RPC, two consumers. This is Phase 1a of [docs/proposals/remote-ai-backends.md](docs/proposals/remote-ai-backends.md). See [docs/net-plugin.md](docs/net-plugin.md).
- **`android.network.cleartext_domains` — scoped plain-`http://` opt-in for LAN endpoints.** Android blocks cleartext traffic by default (`usesCleartextTraffic="false"`), which stops an app reaching a local-network appliance such as a ComfyUI instance on `http://192.168.x.x:8188` — enforced by the OS regardless of the HTTP client, and previously with no `pwa.json` knob. The new key generates a `res/xml/network_security_config.xml` whose global `base-config` keeps cleartext **off** and a scoped `domain-config` permits it **only** for the listed hosts (`"nas.local"`, `"192.168.1.50"`, or an mDNS-style `"*.local"`), then references it from the manifest — the least-broad fix, and the shape least likely to draw app-store scrutiny (no blanket `usesCleartextTraffic="true"` is offered). Omitting the key leaves the manifest byte-for-byte unchanged. `net.downloadFile` also gained an optional request-`headers` arg. See [docs/net-plugin.md](docs/net-plugin.md#androidnetworkcleartext_domains).

### Fixed

- **`ai.generateImage` with no `seed` is now actually random.** The contract has always documented `seed: nil` as "random" (the used seed is echoed back per image), but `StableDiffusionBackend` fell back to a fixed `0` — so the same prompt regenerated the *identical* image every run, and `count > 1` produced near-identical images (seed `0, 1, 2, …`). It now draws a fresh random base seed per call when none is given (bounded to the 32-bit range; `base + index` keeps a multi-image batch distinct), while an explicit `seed` stays fully reproducible. **Device-verified on a Galaxy Tab S10+**: two prompt-only generations returned distinct, non-zero seeds and different images.

## [0.8.7] - 2026-07-11

### Added

- **Runtime model/backend selection for `ai.*` — `request.model`, `ai.info`'s `models` list, and a `MultiModelImageBackend` router.** A running app can now offer a **switcher across several backends** — including **local *and* remote** (an on-device ONNX model vs a cloud image API), since a remote backend is just another `AIBackend` routed by model id. New in `SwiftPWACore`: `AIGenerateImageRequest.model` (which installed model to use; `nil` ⇒ default); `AICapabilities.models: [AIModelInfo]?` so `ai.info` advertises what's available; and the modality-agnostic **`AIModelInfo`** (`id`, `label`, `capabilities`, `availability`, `offlineCapable`, `license`). Capabilities are a `Set<AIModelCapability>` — a kebab-string enum covering the standard multimodal spread (`text-generation`, `image-generation`, `image-edit`, `inpaint`, `vision`, `speech-to-text`, `text-to-speech`, `audio-generation`, `text-embedding`) — so one picker can present text/image/vision/audio models together. **`AIModelAvailability`** is a `kind`-tagged union (`ready` / `downloadable(bytes)` / `needsSetup(reason)`) rather than a `downloaded` bool, so a cloud model (never "downloaded") and a present-but-unusable backend (missing API key, offline) both fit; it encodes to JS as `{ kind, bytes?, reason? }`. **`MultiModelImageBackend`** is the shipped router every multi-model adopter would otherwise hand-roll: it holds N backends, routes `generateImage` / `generateImageStream` / `ensureModel` by model id (delegating text/audio to the default), and aggregates each one's `AIModelInfo` into `ai.info`'s `models`. **It keeps only one model resident:** when a generate routes to a *different* model than last time, it first calls a new `AIBackend.unload()` (default no-op; implemented by `StableDiffusionBackend` / `LaMaBackend` to release their ONNX sessions via `ReleaseSession`) on the previously-active backend, so two multi-GB pipelines aren't loaded at once — without this, switching from one ~2 GB fp16 model to another OOM-killed the app mid-generation on a phone (**verified fixed on a Galaxy Tab S10+**: generate with LCM, switch to SD-Turbo, generate again — both return an image, process survives). Fully additive — `model == nil` / `models == nil` reproduces today's single-model behavior, and no shipped backend or page changes. (Text/audio request-level routing is a noted follow-up.) `Examples/CritterFacts` demonstrates it: the prompt-to-image page is now a **live switcher** between LCM_Dreamshaper (commercial) and SD-Turbo (non-commercial), populated from `ai.info().models` and routed by `request.model` — **device-verified on a Galaxy Tab S10+** (both models' `AIModelInfo` surfaced with capabilities/licence/size; an unknown id is rejected by the router). See [docs/proposals/image-gen-adopter-refinements.md](docs/proposals/image-gen-adopter-refinements.md) Part 1.

### Fixed

- **Android model downloads now report a smooth, byte-level progress bar instead of freezing per file.** `ai.ensureModel` sums a multi-file model into one aggregate `bytesDone / totalBytes` bar; on Apple/desktop the per-file download has a byte callback so the bar advances smoothly, but on Android the download routes through the Kotlin `net.downloadFile` RPC (Swift's `URLSession` has no injectable CA store there) which was **request/response only** — so `ensureModel` could `yield` progress just once per file, at each file's *start*. For the ~2 GB LCM weights (5 files, an **1.7 GB UNet = 83% of the total**) that stair-stepped `0% → 12%` then **froze on the UNet** for the whole download — reads as a hang. Fix: `net.downloadFile` gained an optional host-event `channel`; when set, the Kotlin read loop (which already streams bytes for the incremental SHA-256) pushes throttled (~1 MiB) `{ bytesDone, totalBytes }` frames on it, and a new shared `AndroidFileDownload.download(…)` helper forwards them to the backend's `ensureModel` stream — reaching parity with the Apple/desktop byte callback. The three model backends (`StableDiffusionBackend`, `LaMaBackend`, `MobileSAMBackend`) now share that one helper (each previously hand-rolled the RPC). Reuses the same host-event side-channel `GeminiNanoBackend` streaming already relies on; an absent `channel` keeps the old request/response behavior (backward compatible). **Device-verified on a Galaxy Tab S10+:** a fresh ~2 GB LCM download emitted **1978 progress events** (1973 distinct byte counts) sweeping smoothly `0 → 2.07 GB` with no per-file freeze — vs the pre-fix **5 events** (one per file). See [docs/proposals/image-gen-adopter-refinements.md](docs/proposals/image-gen-adopter-refinements.md) Part 2.

## [0.8.6] - 2026-07-11

### Fixed

- **`ai.generateImage` output was upside-down on macOS/iOS — the Apple `ImageCodec.encodePNG` flipped vertically.** A data-backed `CGContext` is **top-row-first** (buffer row 0 is the visual top), but `encodePNG` copied rows with a `(height-1-y)` flip on the mistaken assumption that bitmap memory is bottom-row-first — and the decode `render` had a *matching* flip. The two cancelled for decode→encode round-trips (`resizeRGB`, the LaMa decode→edit→encode path), so it stayed latent until a **producer fed a top-down image straight to encode with no decode to cancel it** — Stable Diffusion's VAE output, which came back inverted on Apple (desktop's stb and Android's Bitmap codecs were already top-down, so this was also an Apple-vs-others inconsistency). Fix: remove *both* Apple flips (encode + decode `render`), so the codec is uniformly top-row-first and matches the other platforms; LaMa round-trips stay correct because both sides changed together (real-weights inpaint still passes). Adds a `SwiftPWAImageIO` test target with an orientation guard that reads the encoded PNG's top row via an *independent* no-flip bitmap read — a round-trip test alone can't catch a double-flip cancellation.

- **fp16 ONNX models now run on Android — `OrtModelSession` gained a graph-optimization-level knob, and `StableDiffusionBackend` uses `.basic` there.** The fp16 SD-Turbo pipeline failed at session creation on Android with `Failed to find kernel for com.microsoft.Gelu … the node has the following type (tensor(float16))`. Root cause: the Android ONNX Runtime package has **no float16 kernels for the `com.microsoft.*` contrib ops** (Apple/desktop packages do — same 1.27.0, a build-config difference). The exports contain *no* contrib ops; ONNX Runtime's default (`ORT_ENABLE_ALL`) **GeluFusion** — an *extended*-level optimization — rewrites the text encoder's standard Erf-gelu pattern into `com.microsoft.Gelu` **at load time**, and that fused fp16 op has no Android kernel. Fix: a new `OrtGraphOptimizationLevel` parameter on `OrtModelSession.init` (default `.all`, so existing `MobileSAMBackend` / `LaMaBackend` callers are unchanged), and `StableDiffusionBackend` passes `.basic` on `os(Android)` — BASIC skips the extended fusions, so the standard ops (which *do* have fp16 Android kernels, including fp16 `Conv`) run directly. Apple/desktop keep `.all` (their fp16 contrib kernels work; the pipeline is verified there). **Device-verified on a Galaxy Tab S10+:** fp16 SD-Turbo `ai.generateImage` produces a coherent 512² image in ~35 s on the tablet CPU — so the ~2.5 GB fp16 weights are viable on Android, no fp32 fallback needed.

### Added

- **LCM (`LCM_Dreamshaper_v7`) — a commercially-licensed few-step image model for `StableDiffusionBackend`.** A second `stable-diffusion-onnx` model alongside SD-Turbo, and the **commercially-usable default**: SD-Turbo is non-commercial (Stability AI Community License), whereas LCM_Dreamshaper (SD-1.5 + Latent-Consistency distillation) is **OpenRAIL-M**. Lands a **scheduler registry** — a `DiffusionScheduler` protocol + `SchedulerKind` (`.euler` / `.lcm`), so the pipeline picks the sampler its checkpoint was distilled for — plus a pure-Swift **`LCMScheduler`** (consistency-model boundary scaling + per-step re-noising) and the LCM **guidance-scale embedding** (`StableDiffusionSampling.guidanceScaleEmbedding` — the VDM sinusoidal `timestep_cond` that replaces classifier-free guidance). New spec presets `.lcmDreamshaper` / `.lcmDreamshaperFp16` (768-dim CLIP, `timestep_cond` UNet input, 4 steps, guidance ~8) and a hosted, checksum-pinned `StableDiffusionModelSource.lcmDreamshaperFp16` (~2.0 GB fp16 on the `sd-vendor` release; reuses SD-Turbo's byte-identical CLIP tokenizer assets). **Verified end-to-end against a diffusers reference** (real weights): text-embedding / latent / decoded-image correlation all > 0.99999. The real-weights pass caught a checkpoint difference — SD-1.5's CLIP (ViT-L/14) pads with the **end-of-text** token (49407), not `"!"` (id 0) the way SD-2.1's OpenCLIP does (a wrong pad silently corrupts the embedding). `Scripts/vendor-sd.sh` now takes `KIND={sdturbo,lcm}`; the LCM scheduler unit tests match diffusers 0.39 exactly. See [docs/proposals/stable-diffusion.md](docs/proposals/stable-diffusion.md).

- **New tutorial: [On-device AI (text and images)](docs/tutorials/on-device-ai.md).** A beginner-friendly, hands-on guide (matching the other `docs/tutorials/`) covering the four ways to add on-device AI: using a backend we package (`ai.local_llama` + a few lines of Swift), bringing a model we don't package (a different GGUF; your own ONNX pipeline via `StableDiffusionModelSource`), writing your own `AIBackend` (e.g. a cloud-proxy fallback — only `info()` + `generate()` are required), and baking a **LoRA** style into an on-device image model (why a LoRA can't be loaded at ONNX runtime, and the merge→export→host recipe). Linked from the [`ai.*` reference](docs/ai-plugin.md) and the [tutorials index](docs/tutorials/README.md).

- **`Examples/CritterFacts`: a prompt-to-image demo for the Stable-Diffusion backend.** A new "🎨 Generate an image from a prompt" page ([web/generate.html](Examples/CritterFacts/Sources/CritterFacts/web/generate.html)) runs `StableDiffusionBackend` (SD-Turbo) fully on-device — type a prompt → `ai.generateImage({ prompt })` → a PNG — so the text→image tier shipped in 0.8.5 finally has a worked example (it previously had none). It joins LaMa on the example's `CompositeAIBackend`, which now routes `ai.generateImage` by whether the request carries a source `image` (**present ⇒ inpaint/LaMa, absent ⇒ text→image/SD**) and routes `ai.ensureModel({ model: "generate" })` to the SD download — the same "one `ai.*` surface, several purposes" pattern erase already demonstrates. Enabled by the existing `ai.local_onnx_runtime: true` flag; the fp16 SD-Turbo weights (~2.5 GB) are fetched on first use from the `sd-vendor` release. Example-only — no framework change.

## [0.8.5] - 2026-07-11

### Added

- **`StableDiffusionBackend` — text→image for `ai.generateImage` (`SwiftPWAStableDiffusion`), pipeline verified against real weights.** A Stable-Diffusion ONNX backend (`stable-diffusion-onnx`), the text→image consumer of `ai.generateImage` (a `prompt`, no input image), targeting a small distilled model (SD-Turbo / LCM — 1–4 denoising steps) so it's viable on-device. It reuses the shared `SwiftPWAONNX` tier (same `OrtModelSession` + desktop GPU providers as MobileSAM/LaMa) and reports `imageGeneration: true`. Lands: a fully-implemented, unit-tested **CLIP byte-level BPE tokenizer** (`CLIPTokenizer`); a pure-Swift **`EulerDiscreteScheduler`** port; deterministic seeded latent init (`StableDiffusionSampling`); a configurable `StableDiffusionModelSpec`; a multi-file downloadable `StableDiffusionModelSource` + `ai.ensureModel` wiring (Android via the Kotlin `net.downloadFile` RPC); and the full `runTxt2Img` pipeline (tokenize → text-encode → Euler denoise → VAE-decode). **Verified end-to-end against a diffusers SD-Turbo reference** (real weights, on the shared ONNX Runtime tier): every stage matches to within float noise — text embedding / latent / decoded-image correlation > 0.9999999, the decoded image pixel-identical to diffusers. The real-weights pass corrected the assumed contract: `input_ids` is **int64** (not int32), `timestep` a **float32 scalar**, the CLIP embedding dim **1024** (SD-2.1 OpenCLIP), the scheduler **`trailing`**-spaced `epsilon`, and — the one bug — CLIP pads with **`"!"` (id 0)**, not the end-of-text token. **`ai.generateImage` works end-to-end (prompt → PNG)**: it encodes the decoded pixels via the shared `ImageCodec` (writing a file when `outputDirectory` is set, else inline base64), `ai.generateImageStream` reports per-step denoising progress, and `count` is honored. A **fp16 variant** (`.sdTurboFp16`, an `optimum --dtype fp16` export — ~2.5 GB vs 4.9 GB, faster on GPU/CoreML, still CPU-runnable) is also verified against an fp16 diffusers reference (correlation > 0.99998, same image); it differs from `.sdTurbo` by one flag (`float16IO`). The ONNX Runtime team's fp16 exports (`tlwu`/`onnxruntime`) are *not* usable — Olive-optimized with a `com.microsoft.NhwcConv` op the CPU EP can't run. See [docs/proposals/stable-diffusion.md](docs/proposals/stable-diffusion.md).

- **Extracted a shared `SwiftPWAImageIO` target for image decode/encode.** `ImageCodec` / `RawImage` (CoreGraphics on Apple, stb_image on desktop, BitmapFactory-over-RPC on Android) moved out of `SwiftPWAImageEdit` into their own `package`-internal target so both on-device image backends reuse one implementation — `LaMaBackend` (inpaint) and `StableDiffusionBackend` (text→image) — rather than duplicating the platform codecs. `package` access (not `public`): no new public API. No behavior change; the LaMa suite (incl. the real-weights inpaint) passes unchanged.

- **`OrtModelSession` now accepts integer (int32 / int64) and half-precision (float16) input tensors.** The shared ONNX Runtime wrapper was float32-only; a new `OrtInput` enum (`.float` / `.float16` / `.int32` / `.int64`) lets a graph take integer inputs — the Stable-Diffusion text encoder's `input_ids` is int64 — and **fp16** inputs (fp16 model exports: half the download, faster on GPU/CoreML). `.float16` carries `[Float]` and converts to half at the ONNX boundary; fp16 outputs are read back and converted up to float32, so a pipeline stays in float32 regardless of the model's precision (outputs of any other element type error loudly). The existing float-only `run(inputs: [String: Tensor], …)` is unchanged (it delegates to the typed path), so `MobileSAMBackend` / `LaMaBackend` are untouched. Verified end-to-end against tiny real ONNX graphs on CPU — `Cast(int32)+Cast(int64) → float` and an fp16 `x*x`; the full segmentation suite still passes.

### Changed

- **`ai.generateImage` (LaMa) now runs the model on a crop around the mask, for sharper localized edits.** Previously the whole (capped) image was resized to the model's fixed 512² input, so a small edit on a large photo reached the model as a handful of pixels and came back soft. `LaMaBackend` now crops a padded, squared region around the mask's bounding box, resizes *just that crop* to 512², runs the graph, and composites the result back into the full image within the mask — so the edited region fills most of the model input and keeps detail. Two `LaMaModelSpec` knobs: `cropToMask` (default `true`; `false` restores whole-image behavior) and `cropPadding` (default `0.5` — context margin around the box, since LaMa fills from surrounding pixels). Falls back to the whole image when the padded box already covers most of it, and is a no-op when the mask is empty. Pure in-backend array math (no codec/RPC change), so it's identical on every platform. Device-verified on the Tab S10+ against the 24-megapixel demo photo.

## [0.8.4] - 2026-07-11

### Added

- **Android `ImageCodec` for `ai.generateImage` (LaMa inpainting) — completes inpainting on all five platforms.** The one platform the 0.8.3 image-edit tier didn't cover. Decode/encode run Kotlin-side over the same generic JNI RPC bridge segmentation's `AndroidImagePreprocessing` uses — two new handlers: `image.decode` (BitmapFactory decode + optional exact resize / fit-to-max-side, `inSampleSize`-downsampled → raw RGB or grayscale bytes) and `image.encodePng` (`Bitmap.compress`), which also handle SAF `content://` URIs (stb can't). Because the RPC is async, the internal `ImageCodec` API is now `async` throughout (Apple/desktop impls are otherwise unchanged; `LaMaBackend`'s inference path awaits accordingly). `LaMaBackend.ensureModel` also now routes its download through the Kotlin `net.downloadFile` RPC on Android (Swift's URLSession has no CA trust store there — the same reason `MobileSAMBackend` does). **Device-verified end-to-end on a Galaxy Tab S10+** (Android 16): a masked region inpaints away while unmasked pixels stay pristine, via BitmapFactory-RPC decode → ONNX inference → `Bitmap.compress`-RPC encode, on the real 24-megapixel demo photo.

### Fixed

- **`ai.generateImage` (LaMa) no longer fails on large source photos.** The backend decoded the source image + mask and composited the result at the photo's **full** resolution — for a 24-megapixel phone photo (e.g. 6018×4024) that's ~72 MB of RGB per buffer, which OOMs / overflows the Android JNI RPC payload (so on-device it silently did nothing / errored), and needlessly hammers memory everywhere. `LaMaModelSpec` gains `maxWorkingSide` (default 2048): the image + mask are now decoded (down-sampled during decode) and composited at a bounded working resolution, and the result is returned at that size. The model still runs at `inputSize` (512²). Device-verified on the real 6018×4024 demo photo (Tab S10+): output 2048×1369, masked region inpainted, unmasked pixels preserved.

## [0.8.3] - 2026-07-11

### Added

- **`LaMaBackend` — on-device inpainting for `ai.generateImage` (`SwiftPWAImageEdit`).** The first backend for the new editing path: give it an `image` + `mask` and it reconstructs the masked region (prompt-free), via a LaMa-family ONNX model. Reports `imageEditing: true` / `imageGeneration: false` (text generation throws unsupported — it only edits images). It pairs directly with the `ai.vision.*` segmentation tier — a SAM mask decoded to a white-on-black PNG *is* the `mask` — for a "tap to erase" flow. Reuses the shared ONNX Runtime tier (see below): the same `OrtModelSession` MobileSAM runs on, including the desktop CUDA/DirectML GPU providers (`ai.onnx_gpu`) with transparent CPU fallback, and a downloadable-model tier (`ai.ensureModel`) mirroring `MobileSAMBackend`. Opt in like segmentation — `ai.local_onnx_runtime: true` in `pwa.json`; no separate flag. The graph contract + pre/post-processing are a configurable `LaMaModelSpec` (defaulting to the big-lama fp32 export) so the model constants stay isolated from the model-agnostic plumbing — the same de-risking segmentation used. **Verified against the real big-lama fp32 weights on Apple/CPU and Linux/CPU** (hosted via `Scripts/vendor-lama.sh` + `.github/workflows/lama-vendor.yml` → the published `lama-vendor` release, so `LaMaBackend(cacheDirectory:)` fetches out of the box): a masked region inpaints away while unmasked pixels stay pristine, confirming the spec — with one correction from the assumed dynamic size, the export's input is **fixed 512×512** (image + mask resized to the square, the result resized back and composited over the original only within the mask). Image decode/encode (`ImageCodec`) is CoreGraphics/ImageIO on **Apple** and stb_image / stb_image_write (`CStbImage`) on **Linux/Windows**; the **Android** codec (BitmapFactory over the Kotlin RPC) is the one remaining platform (a clear `E_AI_GENERATION` there until it lands). GPU inference reuses the same `OrtModelSession` as the CUDA/DirectML-verified segmentation tier. `Examples/CritterFacts` gains a **tap-to-erase** demo (`web/erase.html`) chaining `ai.vision.segment` → a white-on-black mask → `ai.generateImage`, wired through a small example-side `CompositeAIBackend` that serves both text and image editing on the one `ai.*` surface. See [docs/proposals/image-generation-editing.md](docs/proposals/image-generation-editing.md).

### Changed

- **Extracted a shared `SwiftPWAONNX` target from `SwiftPWASegmentation`.** The ONNX Runtime C API wrapper (`OrtRuntime` / `OrtModelSession`, including the `ai.onnx_gpu` execution-provider selection + CPU fallback) and all ORT linkage now live in their own target with public types, so more than one backend can reuse the runtime tier — `MobileSAMBackend` (`ai.vision.*`) today and `LaMaBackend` (`ai.generateImage`) now, with `gemma-onnx` / `stable-diffusion-onnx` anticipated. `SwiftPWASegmentation` keeps its own ONNX-module dependencies (so `MobileSAMBackend`'s `canImport` gate and empty-stub behavior on a runtime-less destination are unchanged) and depends on `SwiftPWAONNX` for the wrapper types. No behavior change — the full segmentation test suite passes unchanged.

- **`ai.generateImage` generalized from text→image to a purpose-agnostic image op.** The command (contract-only since v0.7.0) now selects its operation by *which fields are present* rather than by a separate command per mode: `prompt` alone → text→image; `prompt` + `image` → image→image (img2img); `image` + `mask` (with or without a `prompt`) → inpaint. `AIGenerateImageRequest` gains optional `image`, `mask` (both `AIImage` — inline base64 or on-disk `path`, mask convention white=edit/black=keep), `strength` (img2img denoising), and `guidanceScale` (CFG); `prompt` relaxes from required to optional (a prompt-free inpainter like LaMa needs none — no shipped backend read it yet, so zero blast radius). `AICapabilities` gains **`imageEditing`** (accepts an input `image` ± `mask`) orthogonal to the existing `imageGeneration` (honors `prompt`): a prompt-free inpainter reports `imageEditing` alone, a Stable-Diffusion backend may report both. Result / streaming types are unchanged (an edited image *is* a generated image). Rationale + the SAM→inpaint pairing in [docs/proposals/image-generation-editing.md](docs/proposals/image-generation-editing.md): the model and the operation are a backend choice invisible to JS, and the backends we ship are examples of the contract, not doctrine. `AIBackendID` reserves `lama-onnx` for the first backend (LaMa inpainting on the shipped ONNX Runtime tier).

### Fixed

- **`ai.vision.*`: the Apple image preprocessing fed the MobileSAM encoder a vertically-flipped image.** `ImagePreprocessing`'s CoreGraphics path drew the source image without accounting for the bitmap context's bottom-row-first memory layout, so the encoder — and therefore every segmentation mask — was computed against an upside-down image (masks came back mirrored top-to-bottom vs. the tap). Fixed the flip; added an `ImagePreprocessingTests.topDownOrientation` regression (a top-red/bottom-blue image asserting buffer row 0 is the visual top). Apple only — the desktop (stb) and Android (BitmapFactory) paths were already top-down-correct.

## [0.8.2] - 2026-07-10

### Added

- **`ai.onnx_gpu` — desktop GPU execution providers for `ai.vision.*` (Windows DirectML / Linux CUDA).** The Linux x86_64 + Windows x64 `MobileSAMBackend` shipped CPU-only in 0.8.1; a new build-time opt-in — the sibling boolean `ai.onnx_gpu: true` in `pwa.json`, layered on `ai.local_onnx_runtime` (either flag now enables the tier) — ships a GPU-capable ONNX Runtime instead. **Windows uses DirectML** (cross-vendor — any DX12 GPU: NVIDIA/AMD/Intel — and in-box on Windows 10+, no external runtime); **Linux uses CUDA 12** (NVIDIA; the CUDA runtime + cuDNN are expected on the target, *not* bundled). There is **no** Vulkan-style one-artifact-all-vendors GPU layer for ONNX Runtime as there is for llama.cpp (the native WebGPU/Vulkan EPs are unshipped in Microsoft's prebuilt desktop binaries) — see [docs/proposals/onnx-gpu-execution-providers.md](docs/proposals/onnx-gpu-execution-providers.md) for the research behind the vendor-specific split. Runtime behavior is **auto-detect with transparent CPU fallback**, no user config: `OrtModelSession` appends the platform GPU EP before the default CPU EP at `CreateSession`, and if it can't initialize — no capable GPU, no driver, or (Linux) no/mismatched CUDA runtime — it logs once and retries on CPU, so inference is never broken by the absence of a usable GPU. `ai.vision.info` gains a **`provider`** field (`"cuda"` / `"directml"` / `"cpu"`, `nil` until the first session) so an app or `benchmark` can report which path engaged. Packaging reuses the 0.8.1 desktop infrastructure pointed at the GPU builds: `Scripts/vendor-onnxruntime-{linux-gpu,windows-directml}.sh` vendor the CUDA tarball (three `.so`s: runtime + shared-provider bridge + CUDA EP) and the DirectML NuGet (`onnxruntime.dll`/`.lib` + `onnxruntime_providers_shared.dll` + `DirectML.dll`); `.github/workflows/onnxruntime-desktop-gpu.yml` re-hosts them to stable `onnxruntime-vendor-{linux-gpu,windows-directml}` releases; and `OnnxRuntimeLinuxGpuArtifact` / `OnnxRuntimeWindowsDirectMLArtifact` (CLI) resolve them (env override → local `Vendor/` → checksum-pinned download) onto `LIBRARY_PATH` (Linux) / `LIB` (Windows). `AppImageBundler` hands all three CUDA `.so`s to `linuxdeploy --library` (SONAME-correct); `WindowsBundler` stages the DirectML DLLs next to the `.exe` (incl. `--single-file`). DirectML links against its **own pinned ORT 1.24.4 header set** (module `ONNXRuntimeDirectML`, adding `dml_provider_factory.h`), kept separate from the shared 1.27 `ONNXRuntimeDesktop` set because the DirectML NuGet runtime lags at 1.24.4 (a 1.27 header would request a newer `ORT_API_VERSION` than that runtime provides and crash); Linux CUDA reuses the identical-API 1.27 desktop headers. Desktop-only — ignored (with a warning) on macOS/iOS/Android, where the OS/EP owns GPU acceleration. Verified on real hardware against the real MobileSAM weights: **Windows DirectML** on an AMD Radeon 780M (`info.provider == "directml"`, mask IoU `1.00000` vs the CPU baseline) and **Linux CUDA** on an NVIDIA RTX 5080 (`info.provider == "cuda"`, IoU `0.99997`, ~27× faster encode), plus the CPU-fallback path (CUDA build with cuDNN absent → one log line → `provider: "cpu"` with an identical mask) — near-perfect IoU confirming the GPU EPs are numerically correct, not merely fast.

## [0.8.1] - 2026-07-10

### Added

- **`ai.vision.segmentAll` / `segmentAllStream` — automatic mask generation on `MobileSAMBackend`.** The reserved AMG surface now has a real implementation (previously `E_UNIMPLEMENTED`): a `pointsPerSide × pointsPerSide` grid of positive-point prompts through the multi-mask decoder, then greedy non-max-suppression (mask IoU) to dedup overlapping candidates — every distinct object as its own `{ bounds, rle, score }` mask, best-score-first. `segmentAllStream` (subscribe) yields a `progress(done, total)` frame per grid cell then a terminal `done`; the unary `segmentAll` drains the same pass. `ai.vision.info` now reports `autoMask: true`. Request knobs: `pointsPerSide` (default 16, capped at 32), `iouThreshold` (NMS dedup, default 0.88), `minAreaPx` (drop specks). Reuses the cached encoder embedding — the whole grid is cheap decodes against one `openSession`. Discovery runs at a reduced working resolution (the decoder upsamples masks to whatever `orig_im_size` it's handed) so a full sweep stays tractable; survivors are nearest-upsampled back to source pixels. Verified end-to-end on macOS against the real `Acly/MobileSAM` weights — a 12×12 grid on a 6018×4024 four-kitten photo returns distinct per-object masks (scores ~0.97–1.01) in ~5 s.

- **`ai.vision.benchmark` — real device-capability timing on `MobileSAMBackend`.** The other reserved surface now returns real numbers instead of `E_UNIMPLEMENTED`: it times a single encode, a single decode, and a small AMG sweep on a synthetic 1024² image (content doesn't affect timing, only tensor shape — so a gradient stands in with no image-codec dependency), and reports `{ encodeMs, decodeMs, segmentAllMs, deviceClass }`. Session/graph parse happens outside the timed regions, so the numbers reflect steady-state per-call cost. `deviceClass` is a coarse `high`/`mid`/`low` bucket keyed on encode time (the dominant, most stable cost). Kept low-priority per the proposal — the primary device-classing path is still an app timing its own first real `openSession`/`segment` — but it's now available for apps that want a one-shot gate. Measured on macOS (CPU): encode ~280 ms, decode ~17 ms → `high`.

- **`MobileSAMBackend` on desktop — Linux x86_64 + Windows x64 (`ai.local_onnx_runtime`).** Segmentation shipped on Apple + Android in 0.8.0; the two desktop backends (which had shipped a `NoneBackend`) are now real, completing cross-platform parity for `ai.vision.*`. Same CPU ONNX Runtime tier, mirroring the Apple/Android packaging: `Scripts/vendor-onnxruntime-{linux,windows}.sh` vendor Microsoft's official prebuilt CPU build into the committed-headers + fetched-lib shape (module `ONNXRuntimeDesktop`, a `.systemLibrary`); `.github/workflows/onnxruntime-desktop.yml` re-hosts both libs to stable `onnxruntime-vendor-{linux,windows}` releases; and `OnnxRuntime{Linux,Windows}Artifact` (CLI) resolve them (env override → local `Vendor/` → checksum-pinned download) and put the lib dir on `LIBRARY_PATH` (Linux) / `LIB` (Windows) for the link step. Because desktop ONNX Runtime is a *shared* lib (unlike llama's static desktop slice), the runtime lib is also staged into the artifact — `AppImageBundler` hands `libonnxruntime.so.1` to `linuxdeploy --library` (SONAME-correct), and `WindowsBundler` copies `onnxruntime.dll` next to the `.exe`. Image decode (no CoreGraphics / `BitmapFactory` on desktop) uses a tiny vendored public-domain **stb_image** (a `CStbImage` C target behind a two-function RGB API) plus a pure-Swift bilinear resize-longest-side, producing the same `PreprocessedImage` the Apple/Android paths do. Verified end-to-end on a real Linux x86_64 box (stb decode → ONNX encoder/decoder → `openSession`/`segment` on a real photo, best IoU ~1.01) and on Windows x64 (byte-identical result). **Requires Swift 6.1+ on Linux** for the segmentation target (the actor-isolated error-mapping helper trips a 6.0.x strict-concurrency diagnostic that region-based isolation in 6.1 resolved). All five backends now report `available: true` when `ai.local_onnx_runtime` is on; a GPU execution-provider desktop build is the remaining fast-follow.

## [0.8.0] - 2026-07-09

### Added

- **`ai.vision.*` segmentation contract.** The JS/Swift contract for promptable on-device image segmentation (SAM-family) is wired: `ai.vision.info` / `openSession` (runs the encoder) / `segment` (runs the decoder against a cached embedding) / `closeSession`, plus reserved (default-`E_UNIMPLEMENTED`) `segmentAll(Stream)` / `ensureModel` / `benchmark` surfaces so their request shapes are stable ahead of a real backend — mirroring how `ai.generateImage`/`ai.generateAudio` shipped in `AIPlugin` before an image/audio backend existed. A new `SegmentationBackend` protocol + `VisionPlugin` (in `SwiftPWACore`, dependency-free) is a **separate** plugin from `AIBackend`/`AIPlugin` — segmentation is discriminative (image + spatial prompt → masks) and needs an encode-once/decode-many **session** primitive that doesn't map onto `AIBackend`'s generate-only shape — sharing the `ai.*` namespace and reusing `AIImage`/`AIEnsureModelRequest`/`AIDownloadEvent`/`BridgeError` conventions. Installed exactly like `AIPlugin`: `ctx.use(VisionPlugin(MyBackend()))` or `ctx.use(VisionPlugin())` for the contract-only `NoneSegmentationBackend`. No backend yet — see the ONNX Runtime packaging spike below and [docs/proposals/segmentation-plugin.md](docs/proposals/segmentation-plugin.md) for the accepted design and 0.8 scope. Covered by unit tests in `SwiftPWACoreTests`.

- **ONNX Runtime packaging spike on Apple + Android (`SWIFT_PWA_ONNXRUNTIME`, not a shipped backend).** De-risks the 0.8 ONNX Runtime tier's cross-platform packaging story before investing in a real MobileSAM backend. **Apple**: Microsoft's official distribution (no GitHub Release asset — a versioned pod-archive zip on their own CDN) ships each slice as a `.framework` *bundle* with no `Modules/module.modulemap`, so `import onnxruntime` doesn't work out of the box, even though the binary inside is actually a plain static archive, not a dylib. `Scripts/vendor-onnxruntime-apple.sh` repackages it into the same flat static-lib + headers xcframework shape `SwiftPWALlama` already uses — verified end-to-end (`SwiftPWAONNXRuntimeSmokeTests`, real version string `"1.27.0"`). **Android**: unlike llama.cpp (which has no Android backend at all in this repo), Microsoft ships a usable prebuilt artifact — the `onnxruntime-android` Maven AAR bundles the plain C API headers plus a per-ABI `libonnxruntime.so` directly (no JNI glue needed; Swift calls the C API directly). `Scripts/vendor-onnxruntime-android.sh` downloads + sha1-verifies it and vendors headers (committed, `Vendor/onnxruntime-android-headers/`) + the `.so` (gitignored) in the same shape `Vendor/llama-headers` uses for Linux — found at cross-compile link time via `LIBRARY_PATH`, same mechanism, no `unsafeFlags`. Verified end-to-end and **on-device**: a throwaway executable linked against the vendored `.so` via `swift build --swift-sdk aarch64-unknown-linux-android28`, pushed and run on a Galaxy Tab S10+ via `adb shell`, printed the real version string `"1.27.0"`. Linux/Windows still have no ONNX Runtime story. Publish workflows exist for both artifacts (`onnxruntime-xcframework.yml` mirrors `llama-xcframework.yml` exactly, self-completing — it publishes then opens a PR pinning the checksum; `onnxruntime-android.yml` publishes but stops short of self-pinning, since there's no CLI-side resolver yet to pin into) and have now been run: Apple's xcframework is published and its checksum is pinned into `Package.swift`; Android's `.so` is published (checksum recorded for the still-needed `LlamaLinuxArtifact`-style CLI resolver, once something calls it).

- **`MobileSAMBackend` — a real `SegmentationBackend` (Apple + Android, `SwiftPWASegmentation`), verified against real weights.** The first consumer of the ONNX Runtime tier above: runs MobileSAM's encoder + one of two decoder variants as ONNX Runtime sessions, implementing `ai.vision.openSession`/`segment`/`closeSession` for real. Built on three independently-tested pieces: **(1)** `OrtRuntime`/`OrtModelSession` — a thin Swift wrapper over the ONNX Runtime C API (env/session creation, float32 tensor in/out, `Run`), proven end-to-end against a synthetic ONNX graph. **(2)** `ImagePreprocessing` — resizes so the longer side hits 1024, nothing else; padding/normalization/channel-transpose all turned out to be baked into the real encoder graph itself (caught by actually inspecting/running the real weights, not just their shapes — see below). **(3)** `MaskPostprocessing` — mask ↔ RLE encode/decode for the `ai.vision.*` contract; the low-res-to-source-pixel upsampling step from the first cut was deleted once real weights showed the decoder graph already upsamples to `orig_im_size` internally. **The full I/O contract is now verified against real, trained weights** — re-hosted at the `mobilesam-vendor` GitHub Release, sourced from [`Acly/MobileSAM`](https://huggingface.co/Acly/MobileSAM) (an ONNX export of the official Apache-2.0 `ChaoningZhang/MobileSAM` checkpoint). Structural inspection of the real graphs (not just size heuristics) turned up two contract corrections from the original (fake-weight-only) cut: the encoder takes a raw HWC `[height,width,3]` pixel tensor (0–255, RGB) with no external preprocessing, and `multimask` selects between two *separate* decoder graphs (`sam_mask_decoder_single.onnx`/`sam_mask_decoder_multi.onnx`) rather than one graph with a toggle. Confirmed end-to-end with point, box, and mixed positive/negative multi-point prompts against synthetic test images — predicted mask bounding boxes matched ground truth exactly. `MobileSAMBackend`'s init signature changed to `encoderPath`/`decoderSinglePath`/`decoderMultiPath` accordingly. **Android**: no CoreGraphics/ImageIO, so image decode + resize (`ImagePreprocessing`'s Android half) runs Kotlin-side via a new `vision.preprocessImage` RPC method (`BitmapFactory`/`Bitmap.createScaledBitmap`, same generic JNI RPC bridge `AndroidArchiveExtractor` uses for zip work) — `AndroidRPC.call` is now `public` so a separate optional target can call it. `SwiftPWASegmentation`'s Package.swift declaration moved out of the Apple-only `#if os(macOS)` gate to a host-agnostic one (so an Android cross-compile from either a macOS or a Linux host sees the target), and `OrtRuntime`/`OrtModelSession`/`MobileSAMBackend` gained a defensive `#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid)` guard so they compile to an empty stub on a destination with neither linked (Linux/Windows-native). Verified by cross-compiling to `aarch64-unknown-linux-android28`, confirming `OrtGetApiBase` resolves against the real vendored `.so` at link time (`nm` shows it versioned `VERS_1.27.0`, not a stub) — and then a full on-device `openSession`/`segment` round trip through the RPC bridge on a Galaxy Z Fold7 against a real photo, correctly segmenting the prompted subject with IoU ~0.99. (`Examples/CritterFacts` demonstrates the backend — see the `ai.vision.ensureModel` entry above for how it acquires the weights.) Linking the vendored xcframework on Apple needs libc++ (protobuf/exception-personality symbols an executable doesn't pull in by default) — the `SwiftPWASegmentation` target declares `.linkedLibrary("c++")` itself so this propagates to any consumer automatically, no app-level linker settings required. **Model hosting**: `mobilesam-vendor` release now exists, but no downloadable-model tier (`ensureModel`) wires it up yet — callers still supply on-disk paths directly (or bundle their own, per the CritterFacts pattern). Linux/Windows backends don't exist yet (no ONNX Runtime story on either).

- **`ai.vision.ensureModel` — the downloadable-model tier for segmentation, closing the last 0.8-scope gap.** `MobileSAMBackend` gains a downloadable initializer (`init(cacheDirectory:source:)`) mirroring `LlamaBackend`'s: `ai.vision.ensureModel` now fetches the three MobileSAM ONNX files (encoder + both decoder variants, ~60 MB total) on first use — resumable and SHA-256-pinned via the same modality-agnostic `ModelDownloader` the llama GGUF path uses — instead of throwing `E_UNIMPLEMENTED`. The default source (`MobileSAMModelSource.mobileSAM`) points at this repo's stable `mobilesam-vendor` release (the verified `Acly/MobileSAM` re-export; checksums pinned + byte-verified against the previously-bundled weights); pass a custom `MobileSAMModelSource` to host elsewhere. Progress streams as a single aggregate `AIDownloadEvent` bar (cumulative bytes over the known grand total across all three files, not three resets). Failures re-wrap the downloader's error as `VisionError.modelDownloadFailed` so JS still sees the stable `E_VISION_MODEL` code. The fixed-path initializer (bundled / bring-your-own weights) is unchanged and still reports `unsupportedPlatform`. **On Android this is the preferred path over bundling weights as APK assets** — the download writes straight to a real filesystem path, sidestepping the "an APK asset isn't a file ONNX Runtime can open" materialization step entirely. Verified end-to-end on macOS (real network download of all three files + a real `openSession`/`segment` on the downloaded weights) and on-device on Android (Galaxy Z Fold7, all three files downloaded, on-device SHA-256 matching the pinned checksum, then segmenting the downloaded weights). `Examples/CritterFacts` switched from bundling the ~60 MB weights (+ a `fs.writeBinary` materialization helper) to this downloadable tier — its `web/mobilesam.js` is now a thin `ai.vision.ensureModel` progress wrapper, and the committed weights + `FsPlugin` wiring are gone. It also gains a **tap-to-segment demo** (`web/segment.html`, reachable from a button on the main page): a full-screen canvas of a kittens photo where tapping a kitten draws its mask (tap elsewhere to reselect) — the canonical SAM interaction, on-device; device-captured working on a Fold7 (image → tap → downloaded-weights segment → RLE mask composited in place).

  **Android downloads route through the platform HTTP stack, not `URLSession`.** Discovered device-verifying the above: swift-corelibs-foundation's `URLSession` on the Swift Android SDK is libcurl + BoringSSL with **no injectable CA trust store** — `libFoundationNetworking` only sets `CAINFO` from a fixed list of read-only Linux paths (`/etc/ssl/certs/ca-certificates.crt`, …) that don't exist on Android, BoringSSL ignores `SSL_CERT_FILE`/`SSL_CERT_DIR`, and this libcurl build ignores `CURL_CA_BUNDLE` — so *any* HTTPS download from Swift fails with "unable to get local issuer certificate", with no env-var or writable-path hook to fix it. `MobileSAMBackend`'s Android `ensureModel` therefore downloads via a new Kotlin `net.downloadFile` RPC (`HttpURLConnection`, Android's own system TLS), mirroring Swift's `ModelDownloader` behavior (cache-reuse, streamed SHA-256 verification, atomic `.part`→final rename) so both platforms behave the same. This is the first `ModelDownloader` consumer on Android (llama uses Gemini Nano there, no download), which is why the gap surfaced now; the RPC is reusable for any future Android download.

- **`ai.local_onnx_runtime` `pwa.json` flag + Android bundler wiring for `libonnxruntime.so`.** Closes the packaging gap left by the ONNX Runtime spike above: until now, enabling segmentation meant setting `SWIFT_PWA_ONNXRUNTIME` by hand and, on Android, manually `cp`-ing the vendored `.so` into `jniLibs/<abi>/` before `./gradlew assembleDebug` (or the APK crashed at launch with `UnsatisfiedLinkError`). `ai.local_onnx_runtime: true` now drives this the same way `ai.local_llama`/`ai.gemini_nano`/`ai.phi_silica` already do: `swift-pwa build` sets `SWIFT_PWA_ONNXRUNTIME=1` (`Build.applyLocalOnnxRuntimeGate`), and a new `OnnxRuntimeAndroidArtifact` (mirroring `LlamaLinuxArtifact`'s resolution order — explicit env override, local `Vendor/onnxruntime-android/<abi>/` vendoring, then a checksum-verified download from the `onnxruntime-vendor-android` release) resolves `libonnxruntime.so` **per ABI** inside `AndroidBundler.stageJniLibs`'s existing per-ABI cross-compile loop — unlike llama (single host arch), Android cross-compiles multiple ABIs in one build, so the artifact fetch + `LIBRARY_PATH` override (via `Shell.run`'s existing `envOverrides` parameter) happen per iteration, not once up front. The same resolved `.so` is then staged into `jniLibs/<abi>/` alongside the app's own binary and the Swift runtime, mirroring how `stageSwiftRuntime` already stages the stdlib. Only `arm64-v8a` is published today (matching this repo's device-verification practice); requesting an unpublished ABI with the flag on fails the build with an actionable message rather than shipping a `.so`-less APK. `Examples/CritterFacts` switched from the hand-set env var to `"local_onnx_runtime": true` in its `pwa.json`.

## [0.7.10] - 2026-07-07

### Added

- **Device memory to JS — `system.memory`, a memory-pressure event, and two new `__platform.info` fields.** The only RAM signal the web platform gives is `navigator.deviceMemory`, and it's the wrong tool: quantized to powers of two, capped at 8 GB (an 8 GB and a 16 GB device both report `8`), **absent in WKWebView entirely** (so on iOS it's `undefined` and a memory-scaled cache has no device signal at all), and static — never "available" or "under pressure." Every platform swift-pwa targets exposes far better numbers natively; this bridges them. **(1)** `__platform.info` gains **`physicalMemoryBytes`** (total device RAM, `ProcessInfo.physicalMemory` — exact, uncapped, and present on iOS) and **`appMemoryLimitBytes`** (the per-app OS ceiling where one exists — Android's large-heap class — else `null`); both are static for the session, so they ride the existing cached call. **(2)** A new auto-installed **`SystemPlugin`** (`system.*`) exposes **`system.memory`** → `{ physicalBytes, availableBytes, appLimitBytes, lowMemory }`, a live point-in-time read (`availableBytes` is `os_proc_available_memory()` on iOS = remaining jetsam headroom, `host_statistics64` free+inactive on macOS, `/proc/meminfo` `MemAvailable` on Linux, `GlobalMemoryStatusEx` on Windows, `ActivityManager.MemoryInfo` on Android). **(3)** A **`system.memoryPressure`** event on the `events.*` bus (`__SWIFT_PWA__.on('system.memoryPressure', ({ level }) => …)`, `level ∈ 'warning' | 'critical'`) lets the OS tell the app to shed caches *before* it kills the process — wired via `DispatchSource.makeMemoryPressureSource` on iOS/macOS and `onTrimMemory` on Android. **Cross-platform parity per each OS's signal:** total RAM + the live `system.memory` read land on all five backends; the pressure event fires on iOS/macOS/Android but **not on Linux/Windows** (no portable signal — documented, not synthesized), so size caches from `system.memory` too and treat the event as best-effort. All new fields are optional/defaulted so existing adopters stay source-compatible; a plain browser without the native shell keeps falling back to `navigator.deviceMemory`. The `MemoryProvider` protocol (default `DefaultMemoryProvider` for macOS/iOS/Linux/Windows, JNI-backed `AndroidMemoryProvider` on Android) mirrors the `ProcessRunner` / `FsContentResolver` injection pattern. Verified with unit tests + a compile pass on all Apple backends, and **device-verified on a Galaxy Tab S10+**: `system.memory` returns correct live values (physical 12 GB, `appLimitBytes` = 512 MiB large-heap class, available ~5.7 GB), the new `__platform.info` fields are populated, and `system.memoryPressure` delivered `{ level: "critical" }` to JS in response to an OS `onTrimMemory(RUNNING_CRITICAL)`. See [docs/javascript-api.md](docs/javascript-api.md#system) and the [device-memory proposal](docs/proposals/device-memory.md).

- **Window state memory — remember a window's size and position across launches.** Set `"window": { "remember_state": true }` in `pwa.json` (the `swift-pwa init` scaffold now turns this on for new apps) and the desktop backends persist the window's geometry to a small `window-state.json` in the per-app data directory, restoring it the next time a window with the same `stateKey` opens. It's driven by a new `WindowConfig.rememberState` / `WindowConfig.stateKey` and a Foundation-only `WindowStateStore` in core — **no new dependency**, no `UserDefaults` / registry / GSettings. Restore is synchronous (the config is seeded before the native window is built, so there's no flash-then-jump), a new `WindowConfig.origin` carries the remembered position into window construction (macOS `setFrameOrigin` instead of `center()`, GTK3 `gtk_window_move`, Windows `CreateWindowExW` instead of `CW_USEDEFAULT`), and changes are saved continuously as you resize/move (debounced ~0.4s off the main thread, plus a synchronous flush when the last window closes). Multi-window apps give each window its own `stateKey` so their frames don't clobber one another. **Scoped per platform, following each one's window model:** macOS / GTK3 / Windows restore **both size and position**; **GTK4 / Wayland restore size only** (the compositor owns window placement — `setPosition` is a no-op there and no position is ever recorded); iOS / Android windows are full-screen, so `remember_state` is a no-op. Off-screen restore (e.g. a monitor was unplugged) isn't clamped yet — a documented limitation. Verified with unit tests (the store's record / restore / persist / track paths against a `MockWindow`) plus a compile pass on macOS, GTK4 (on the Linux box), and the CLI. See [README.md](README.md#configuring-pwajson) and [docs/linux-setup.md](docs/linux-setup.md#known-limitations).

### Fixed

- **Android cross-compile: auto-clean a stale `.build/<triple>` when the swift-pwa runtime changes, preventing a startup `SIGSEGV`.** SwiftPM's incremental Android build doesn't reliably recompile a *caller* module when a core type's stored-property layout changes (e.g. this release's own `WindowConfig` gaining `origin`/`rememberState`/`stateKey`) — the old and new layouts get linked together and the app crashes at launch with a `swift_retain` fault inside the type's value-witness copy. `swift-pwa build --target android --cross-compile-android` now fingerprints the swift-pwa runtime sources before each ABI's `swift build` and, on a change since that triple was last built, wipes `.build/<triple>` so everything recompiles against one consistent layout (a one-line `note:` when it fires; unchanged trees keep the fast incremental path). This surfaced device-verifying the memory feature above — the crash reproduced on clean `main` and was traced to a stale cache predating the window-state-memory change. Covered by unit tests for the fingerprint/clean logic. See [docs/android-setup.md](docs/android-setup.md#4-cross-compile--bundle).

## [0.7.9] - 2026-07-05

### Added

- **`dialog.exportFile` — a content-first "save this" that works on every platform, iOS included.** `dialog.saveFile` returns a *destination path the caller then writes to*, a shape iOS has no panel for — so `saveFile` has always been a no-op there (returns `null`). `exportFile` closes that gap: the web app hands over the content (`dataBase64` inline, or a source `path`) plus a `defaultName`/`filters`, the platform's save/export UI lets the user choose a location, and the **backend does the write** — returning the destination (a filesystem path on desktop, the picked file's path on iOS, a `content://` URI on Android) or `null` if cancelled. On iOS it materializes the bytes to a temp file and presents `UIDocumentPickerViewController(forExporting:)` — the platform's only real "save" affordance — giving iOS a genuine save UX for the first time; on macOS/GTK/Windows it's the native save panel followed by a write; on Android it's SAF `ACTION_CREATE_DOCUMENT` followed by a `ContentResolver` write (unlike `saveFile`, which hands back the URI for the app to write itself). The `Dialog` protocol gains a default implementation so an external conformance predating this stays source-compatible. `saveFile` is unchanged and still the right call when you specifically want a to-be-written path on desktop/Android. Verified with unit tests (content resolution + plugin dispatch) plus a compile pass on every backend — macOS, iOS (simulator), GTK3, GTK4, Windows (CI), and Android (Swift `.so` + Kotlin `assembleDebug`). See [docs/javascript-api.md](docs/javascript-api.md#dialog) and the [saving-and-loading-files tutorial](docs/tutorials/saving-and-loading-files.md).

- **`app.openFile` now fires on Android too — completing "Open With" → JS on every platform.** v0.7.8 delivered OS-opened files to JS everywhere except Android (`VIEW`/`SEND` intents were deferred); this wires them up. Declare the handled types with a new **`android.document_types`** (`"android": { "document_types": [{ "mime_types": ["image/png"] }] }`) — the Android counterpart to Apple's `CFBundleDocumentTypes` — and the bundler generates `ACTION_VIEW` ("Open with") + `ACTION_SEND`/`ACTION_SEND_MULTIPLE` (share sheet) intent-filters on the launcher activity. When a user opens a matching file, `MainActivity` (`onCreate` for cold launch, `onNewIntent` for warm) reads the intent's `content://` URI(s) and pushes them to the Swift runtime, which re-emits on the `app.openFile` channel; the web app reads the URIs via `fs.readBinary`. The cold-launch race — the launch intent is pushed from `onCreate` on the UI thread before the Swift host-event handler is installed on the runtime worker thread — is closed by a small buffer in the JNI C shim that stashes a pre-handler push and flushes it on install (the Android analogue of the `EventBus` retain that makes cold launch work on the other platforms). Device-verified on a Galaxy Tab S10+ (cold + warm `ACTION_VIEW`). See [docs/android-setup.md](docs/android-setup.md#file-associations-androiddocument_types) and [docs/javascript-api.md](docs/javascript-api.md#appopenfile--os-open-with--launch-with-file).

### Fixed

- **Linux: `window.isFullscreen()` now reports real state instead of always `false`.** On both GTK backends `setFullscreen(_:)` worked, but `isFullscreen()` was hard-wired to `false` — so a web app that called `window.setFullscreen(true)` and then read `window.isFullscreen()` back got a lie (macOS/Windows/Android all returned real state). Both `GTKWindow` classes now mirror the requested state in a tracked `Bool` (seeded from `window.fullscreen` at construction, updated in `setFullscreen`), matching the `Win32Window` / `AndroidWindow` pattern. A tracked bool — rather than GTK4's native `gtk_window_is_fullscreen()` — is deliberate: it gives a correct *immediate* read (the native surface flips async after the WM grants fullscreen), it's verifiable under bare Xvfb with no window manager, and it's consistent with the backend's existing stance of not observing WM-driven geometry changes. WM/F11-driven fullscreen toggles still aren't reflected (a future enhancement could hook GTK's window-state signal). Verified end-to-end on both backends (GTK3 and GTK4), constructing a real window under Xvfb. See [docs/linux-setup.md](docs/linux-setup.md#known-limitations).

## [0.7.8] - 2026-07-05

### Added

- **OS "Open With" / launch-with-file events now reach the web app (`app.openFile`).** An app could already *declare* a file association (via the `info_plist` passthrough), but the runtime dropped the opened file — there was no path from the OS open event to JS, so the association was cosmetic. The runtime now forwards opened documents to a new `app.openFile` event-bus channel; the web app subscribes with `__SWIFT_PWA__.on('app.openFile', ({ paths }) => …)`. Captured on **macOS** via an `NSApplicationDelegate` `application(_:open:)`, on **iOS** via `scene(_:openURLContexts:)` (plus the cold-launch `connectionOptions.urlContexts`), and on **Linux/Windows** via the launch file-argument convention (`.desktop` `Exec=… %F` / file-association argv). The event is emitted **retained**, which solves the dominant case — *the file launches the app*, so the open event fires before the WebView exists — by replaying it to the listener as soon as it subscribes (no double-click-to-launch loses the file). On the macOS App Sandbox the runtime activates and holds the security-scoped grant for the session, so the delivered path is readable via `fs.readBinary` with no extra step. Android `VIEW`/`SEND` intents are not wired to this channel yet. Verified end-to-end on macOS (cold + warm `open -a`). See [docs/javascript-api.md](docs/javascript-api.md#appopenfile--os-open-with--launch-with-file).

- **The Windows *portable* `.exe` now gets a real app icon from `pwa.json`'s `icon`** — the last platform whose icon pipeline stopped short (macOS `.icns`, iOS `actool`, Android `mipmap`, and the Windows MSIX tile all already worked; the portable `.exe` kept the generic Windows application icon in Explorer / the taskbar / Alt-Tab). The bundler now wraps the source PNG in an `RT_GROUP_ICON` / `RT_ICON` resource pair (a PNG can be the `RT_ICON` payload verbatim — the shell decodes PNG-compressed icon images on Vista+) and injects it into the linked `.exe` via the Win32 `BeginUpdateResource` / `UpdateResource` / `EndUpdateResource` API. That's the same post-link PE-resource-editing approach the bundler already uses for the Common Controls v6 manifest and the WINDOWS-subsystem flip, but the API is in `kernel32`, so unlike `mt.exe` / `editbin` it needs no tool on `PATH`. It runs before the `--single-file` web overlay so rewriting resources can't disturb the trailing overlay data. Best-effort like every other icon step (a missing / non-PNG / unreadable icon leaves the default and never fails the build) and reported through the same one-line `IconOutcome` summary. First cut embeds the single source image and lets the shell downscale it for the 16/32/48 px slots; a crisp multi-size pass (WIC resize) can follow. Verified on an arm64 Windows box: the embedded `.exe`'s shell icon reads back as the source PNG (distinct from the default application icon on an un-embedded `.exe`). See [docs/windows-setup.md](docs/windows-setup.md).

### Changed

- **`swift-pwa build` output is sharper: one consistent icon-status line, and a quiet toolchain preflight.** Icon handling was inconsistent across the five bundlers — macOS / Windows / Android said *nothing* on success, iOS / Linux emitted stray `note:` lines only on some failure paths — so you could never tell from the output whether your `pwa.json` `icon` was actually bundled, silently ignored (wrong extension, missing file), or skipped because a tool was absent. Every bundler now funnels its icon step through a shared `IconOutcome` and the build prints exactly one line: `app icon ← icon.png (7 sizes)` on success (the size count shows where a single source PNG is expanded into a multi-size container, e.g. the macOS `.icns`), or a specific reason otherwise (`no icon set in pwa.json — using the platform default`, `icon 'icon.svg' isn't a PNG — …`, `icon 'icon.png' not found — …`, or `app icon from '…' skipped (actool unavailable); the build is otherwise fine`). Separately, `build` now runs a **quiet preflight** before the (potentially long) compile: it reuses `doctor`'s *required*-tool checks for the target and, only if something's missing, prints one heads-up line pointing at `swift-pwa doctor --target <t>` for the fixes — it says nothing on a healthy machine, and never aborts (the bundler still surfaces the real error, and a probe false-negative can't block a build). Android is skipped unless `--cross-compile-android` is set, since a plain Android build only emits the Gradle scaffold and doesn't yet need the NDK / Swift Android SDK. Motivated by adopter feedback that the build was simultaneously too noisy (scattered notes) and too quiet (no confirmation the icon landed).

### Fixed

- **Android: `window.background_color` no longer forces a Light-only theme that broke `prefers-color-scheme: dark` in the WebView.** Since the field shipped on Android (v0.7.5), the generated `Theme.SwiftPWA` descended from `Theme.AppCompat.Light.NoActionBar` — and because `MainActivity` is an `AppCompatActivity`, inflating a `*.Light.*` theme pins the activity (and the `WebView` it hosts) to light `uiMode`, so `matchMedia('(prefers-color-scheme: dark)')` reported `false` regardless of the device setting. A theme-aware web app was stuck in light mode on Android, and a dark-mode user got the light `background_color` flashed before first paint. The theme now descends from **`Theme.AppCompat.DayNight.NoActionBar`**, and the bundler emits it twice — `res/values/swift_pwa_theme.xml` (light) and `res/values-night/swift_pwa_theme.xml` (dark) — so Android resolves the window colour and system-bar glyph luminance per mode, and the WebView's media queries track the system setting (live, on toggle). `window.background_color` now also accepts a light/dark **pair** (`{ "light": "#F4F4F2", "dark": "#0C0D0E" }`) in addition to a plain string; the pair drives a night-aware `setBackgroundColor` (`UI_MODE_NIGHT_MASK`) so the pre-paint colour follows the active mode. The non-Android backends aren't system-theme-aware at runtime yet, so they paint a single launch colour and resolve a pair to its **dark** value (a dark pre-paint flash beats blinding a dark-mode user). Plain-string `background_color` is unchanged. Device-verified on a Galaxy Tab S10+: `prefers-color-scheme` reports `dark` in night mode and `light` otherwise. See [docs/android-setup.md](docs/android-setup.md#windowbackground_color).

- **CI: the Linux gtk3/gtk4 test jobs no longer flake on the swift-corelibs exit-hang (issue #39).** The hang (swift-testing's async `@main` parks in `dispatch_main` after every test passes, and the final `exit()` wakeup is intermittently lost) had begun to red *otherwise-green* jobs: it now runs hot on the hosted gtk runners (a majority of runs park), and the previous timeout-and-retry wrapper couldn't ride it out because the hang eats `swift test`'s stdout summary — so a wrapper can't distinguish "passed then hung" from "hung mid-run" (confirmed dead ends: `stdbuf` can't reach SwiftPM's buffered output, `--xunit-output` is XCTest-only, `| tee` deadlocks under `timeout`, and SIGCONT-nudging sometimes crashes the process). [`Scripts/ci-test-linux.sh`](Scripts/ci-test-linux.sh) now launches the **built test bundle directly** and has swift-testing write its **structured event stream to a file** (`--event-stream-output-path`). Failures are read from that file — a `"symbol":"fail"` issue event is flushed *mid-run*, so a failing test always fails the job (never masked). Passing is inferred from the hang being *post-run*: once the bundle has run tests and gone quiescent (no new events for several seconds while still alive) with no failure recorded, the run passed and the parked process is killed. (swift-testing block-buffers the stream, so the trailing `runEnded` chunk is usually lost to the hang — which is why the verdict comes from mid-run failure events plus quiescence, not the trailing event.) A crash-at-exit without a verdict — the other face of the same race — is retried; a deterministic crash recrashes and fails. Validated on the Linux box: 30/30 passing across runs that hit the hang, and an injected failing test exits non-zero at once. See [docs/linux-setup.md](docs/linux-setup.md#swift-test-occasionally-hangs-at-exit-on-linux).

## [0.7.7] - 2026-07-01

### Added

- **`dialog.openDirectory` multi-select.** `DialogOpenDirectoryArgs` gains a `multiple` flag (mirroring `dialog.openFile`), so a single invocation can register several directories at once — the motivating case is an app's "add library folders" flow where users want to pick a shelf of series folders in one go. `dialog.openDirectory` now returns `{ paths, path }`: `paths` is every selected directory, and `path` (the first selection, or `null`) is kept so callers written before this change keep working unchanged. Wired natively on every desktop backend — macOS/iOS via `NSOpenPanel`/`UIDocumentPickerViewController.allowsMultipleSelection`, GTK3 via `gtk_file_chooser_set_select_multiple`, GTK4 via the new `gtk_file_dialog_select_multiple_folders` (GTK 4.10+), Windows via `FOS_ALLOWMULTISELECT | FOS_PICKFOLDERS` (the shim's `swiftpwa_dialog_open_directory` now returns a path *array*). **Desktop-only:** Android's SAF `ACTION_OPEN_DOCUMENT_TREE` grants one tree per launch, so `multiple` is ignored there and at most one path comes back (documented in [docs/android-setup.md](docs/android-setup.md) §8). Why: `NSOpenPanel` and the other native folder pickers support it for free, and `dialog.openFile` already exposed it — directories were the one picker that couldn't. See [docs/javascript-api.md](docs/javascript-api.md).
- **Per-request reference-audio voice cloning in the `ai.*` audio contract.** `AIGenerateAudioRequest` gains `referenceAudio` (an `AIAudio` — inline `dataBase64` or on-disk `path`) and `referenceText` (its transcript), and `AICapabilities` gains a `voiceCloning` flag. Together they let a TTS backend clone a voice from a reference clip **per call** — the reference rides on the request rather than the backend's `init`, so a user-switchable "voice" preference changes without a heavyweight backend re-initialization, and a page can route on `info.voiceCloning` to show a cloning affordance only where it's supported. Both request fields are optional (default `nil`) and ignored by backends that don't advertise `voiceCloning`, so existing backends stay source-compatible and older client JSON still decodes. This lands the "still open" item from the 0.7.6 TTS guide, which had documented the workaround (thread the clip through the backend's own init or a side-channel command) as a stopgap; the worked example in [docs/ai-plugin.md](docs/ai-plugin.md#worked-example-a-custom-on-device-audio-tts-backend) now shows the first-class path. No shipped backend implements cloning yet — this is the frozen contract adopters build against.

### Fixed

- **Android builds without `window.background_color` no longer fail resource linking.** The v0.7.5 theme refactor emitted the app's `android:theme` as a bare `Theme.AppCompat.Light.NoActionBar` (missing the `@style/` prefix) whenever no `window.background_color` was set — a bare string isn't a valid theme *reference*, so `aapt2`/`gradle assembleDebug` aborted with `'Theme.AppCompat.Light.NoActionBar' is incompatible with attribute theme (attr) reference`. It slipped through because the manual v0.7.5 device check set a background colour (exercising only the `@style/Theme.SwiftPWA` branch) and the bundler unit test asserted the *buggy* bare string. Fixed to `@style/Theme.AppCompat.Light.NoActionBar` (restoring the pre-0.7.5 value); the unit test now asserts a valid `@style/` reference and guards against the prefix-less form regressing. Device-verified on a Galaxy Tab S10+.
- **`--cross-compile-android` now builds a runnable APK (real native `.so`) instead of silently shipping a hollow one, and fails loudly when it can't.** Two long-standing defects combined to ship APKs with **no Swift `.so`** (they'd crash at launch with `UnsatisfiedLinkError`) while CI stayed green: (1) the inner `swift build --swift-sdk` ran as a plain `swift`, so a repo `.swift-version` pinned a toolchain that *doesn't match* the installed Swift Android SDK — `module compiled with Swift 6.2 cannot be imported by the Swift 6.0.3 compiler` — and the ABI was skipped; (2) that skip was swallowed with a `note:` and a **zero exit**, so `gradle assembleDebug` happily packaged a scaffold with empty `jniLibs/`. Now the bundler (a) runs the cross-compile under a toolchain matching the SDK — when swiftly is present it wraps the build in `swiftly run +<major.minor>` (parsed from the SDK bundle id, e.g. `swift-6.2-RELEASE-android` → `+6.2`), locating swiftly by `SWIFTLY_BIN_DIR`/`SWIFTLY_HOME_DIR`/default rather than `PATH` (swiftly's `swift` shim narrows `PATH` for child processes); and (b) treats a skipped ABI as a hard error (non-zero exit) with a diagnostic, so a hollow APK can never ship unnoticed. Device-verified end-to-end on a Galaxy Tab S10+ (arm64-v8a): `libHelloPWA.so` + the Swift runtime are packaged, the app launches with no `UnsatisfiedLinkError`, and the Swift bridge attaches (`swift-pwa: bridge attached`). Separately, note the Swift Android SDK's own `setup-android-sdk.sh` (run by the CI job / after `swift sdk install`) must have wired the NDK clang resources — a dangling `swift-resources/.../swift/clang` symlink (e.g. after moving the NDK) surfaces as `'stddef.h' file not found` and must be repaired by re-running that script.

## [0.7.6] - 2026-07-01

### Added

- **Subprocess plugin (`process.*`) — host a "thick" local backend, not just a thin PWA.** A new opt-in `ProcessPlugin(SystemProcess())` launches and manages an external child process: `process.stream` spawns it and streams stdout/stderr as bridge events (base64 frames: `spawned` → `stdout`/`stderr` → terminal `exit`), `process.write` feeds stdin (with optional `closeStdin` EOF), and `process.kill` terminates it. The motivating case comes from adopters wrapping an existing CLI/daemon — a converter, an indexer, a local model server, or an out-of-process TTS synthesizer that has to keep running until a native audio backend exists. The design's headline property is **guaranteed teardown**: a child's lifetime is bound to its `process.stream` subscription, so when JS unsubscribes *or the owning window closes*, `BridgeRuntime` cancels the subscription, whose `onTermination` terminates the child — orphaned children (the classic hand-rolled-`Process` failure mode) can't happen. Backed by Foundation's `Process` on macOS/Linux/Windows; **desktop only** — iOS/Android sandboxes forbid spawning, so `SystemProcess.spawn` throws `E_UNIMPLEMENTED` there (the plugin still compiles everywhere). Injectable via the `ProcessRunner`/`ProcessChild` protocols for testing. See [docs/process-plugin.md](docs/process-plugin.md), [docs/javascript-api.md](docs/javascript-api.md), and [docs/swift-api.md](docs/swift-api.md).
- **Server-push events — a first-class Swift→JS event bus (`events.*`, `ctx.emit`, JS `on`/`emit`).** Until now the only Swift→JS channel was `subscribe`, which JS has to *pull*; any app wanting Swift to notify JS of something the client didn't request (a file appeared, an import finished, a job progressed) had to hand-roll a catch-all "bus" stream and fan unrelated events into it — boilerplate every app reinvented, with no clean broadcast to multiple windows and no story for a client that subscribed too late. `EventBus` makes it first-class: it's owned by the `AppContext` (`ctx.events`), auto-installed as the built-in `EventsPlugin` on every backend, and a single `ctx.emit(channel, payload)` fans out to subscribers in **every** window. Retained channels (`emit(..., retain: true)`) replay their latest value to windows that connect later, closing the missed-event gap. JS gets `__SWIFT_PWA__.on(channel, cb)` and `__SWIFT_PWA__.emit(channel, payload)` sugar over the raw `events.subscribe`/`events.emit` commands; payloads cross the bridge as raw JSON with no re-encoding. `ctx.events` is `Sendable`, so a background file watcher or import `Task` can `bus.emit(...)` without hopping to the main actor. See [docs/swift-api.md](docs/swift-api.md#server-push-events) and [docs/javascript-api.md](docs/javascript-api.md).

### Documentation

- **Guide: implementing a native on-device audio (TTS) `AIBackend`.** The `ai.*` audio contract (`generateAudio` / `generateAudioStream`, `AIGenerateAudioRequest` with `voice`/`language`/`speed`/`format`, `AIAudioChunk` framing, the `audioGeneration` capability, JS `ai.generateAudioStream`) has shipped and been tested since 0.7.0, but no backend implements it. For adopters who want to run TTS natively/in-process (e.g. to ship a self-contained, notarizable `.app` instead of shelling out to a Python synthesizer), [docs/ai-plugin.md](docs/ai-plugin.md#worked-example-a-custom-on-device-audio-tts-backend) now has a full worked example: advertising `audioGeneration`, wiring a CoreML/MLX engine's PCM output into `generateAudioStream`, the expected `AIAudioChunk` framing (why sample-rate/format live in the bytes + `mimeType`, raw-PCM vs. self-describing chunks), voice selection, where reference-audio voice cloning would slot in (a contract addition), model download via `ModelDownloader`, and the [subprocess plugin](docs/process-plugin.md) as the ship-now interim path that swaps to the native backend later without touching the page.

## [0.7.5] - 2026-06-29

### Fixed

- **`window.background_color` is now honoured on Android — it was the one backend that parsed the field and never applied it.** When the feature shipped (v0.7.0) it landed on Apple / GTK / WebView2, but the Android bundler decoded `window.background_color` into `WindowConfig.backgroundColor` and then dropped it, so an Android build flashed the stock white launch window and kept a default-light status bar regardless of the configured colour — the exact "this is just a webview" tell the option exists to remove. The Android `--target android` bundler now threads the colour through three surfaces, matching the analogous iOS launch-screen treatment: it emits a `Theme.SwiftPWA` (in `res/values/swift_pwa_theme.xml`, descending from the same `Theme.AppCompat.Light.NoActionBar` base) whose `android:windowBackground` paints the launch window in the colour (killing the white flash before first paint), sets `android:statusBarColor` + `android:navigationBarColor` to match, and picks `android:windowLightStatusBar` / `windowLightNavigationBar` from the colour's relative luminance so the system-bar glyphs stay legible (dark icons on a light fill, light on a dark one); the generated `MainActivity` also calls `webView.setBackgroundColor(...)` to cover inflation→first-paint. All gated on the colour being set — apps that omit it keep the stock theme untouched. Closes the gap behind the v0.7.0 "applied on **every backend**" claim. See [docs/android-setup.md](docs/android-setup.md).

## [0.7.4] - 2026-06-28

### Added

- **Portable on-device llama.cpp backend now runs on Windows arm64 (Snapdragon X Copilot+) — CPU.** `SwiftPWALlama` / `LlamaBackend` extends from Windows x64 (Vulkan) to **Windows arm64**, the second arch on Windows. It's the same backend and the same **`ai.local_llama: true`** flag; only the compute path differs — arm64 is **CPU-only** for now (a deliberate MVP, *not* a ggml/Vulkan limitation: Adreno on Snapdragon X has a conformant Vulkan ICD and ggml-vulkan's shaders are arch-neutral SPIR-V — CPU-only just has no SDK/driver link or runtime dependency, so it's the de-risked first slice). The prebuilt arm64 `llama.lib` is built without the Vulkan backend, so `Package.swift`'s arm64 branch links `llama.lib` *alone* (no `vulkan-1`) and `swift-pwa build` skips the Vulkan SDK entirely on arm64. Why this matters: Windows **Phi Silica** can only generate from an **MSIX-packaged app + a Microsoft LAF token**, so on arm64 Copilot+ devices llama is the *unpackaged, any-GGUF, no-token* on-device fallback — the only on-device AI path that works from swift-pwa's default portable exe there. The arch is plumbed end to end: `LlamaWindowsArtifact` gains a per-arch checksum pin (`sha256_arm64`) + per-arch release URL, `build-llama-windows.ps1` takes `-Arch arm64` (CPU-only build, no glslc/SDK), and the `llama-windows` workflow publishes the arm64 lib from a native `windows-11-arm` runner (clang-cl from the runner's preinstalled LLVM) and auto-pins its checksum. CI's `windows-llama` link-check stays **x64-only** — GitHub's arm64-Windows Swift toolchain isn't CI-viable yet (`gha-setup-swift` installs an x64 toolchain at 6.1.2, mismatching the arm64 MSVC env; the native arm64 toolchain at 6.3.1 crashes on launch), so the arm64 build + link is **device-verified** instead. One arm64-specific wrinkle: ggml's CPU backend **refuses MSVC on ARM** (`"MSVC is not supported for ARM, use clang"`), so the arm64 build drives the compile with **`clang-cl`** (the MSVC-ABI clang driver, so it still links cleanly with the MSVC-built Swift runtime + `lib.exe`-combined archive) — the script auto-finds one from PATH / the Swift toolchain / LLVM. **Verified end to end on a Snapdragon X (arm64) box**: the arm64 `llama.lib` builds (clang-cl, ~13 MB), links into a Swift executable through the arm64 `Package.swift` branch, and runs — `LlamaBackend.info()` reports `backend: gemma-llamacpp`, `streaming: true`. Small models (0.5–3B) run comfortably on Snapdragon X CPU. **An arm64 Adreno GPU (Vulkan) build path also landed, but gated behind an experimental opt-in (`LLAMA_WIN_ARM64_VULKAN`) and NOT shipped** — the whole pipeline works (the LunarG **warm** Windows-ARM SDK provides `glslc` + an arm64 `vulkan-1.lib`; ggml-vulkan compiles with `clang-cl`; the loader finds the Adreno ICD and ggml offloads to it), **but the Adreno X1's Vulkan *compute* currently returns incorrect output**. This was isolated rigorously on-device: the same Vulkan-built binary + same checksummed model is coherent with the GPU hidden (pure CPU) and garbage the moment the Adreno is used, and it's immune to every ggml-vulkan correctness flag (fp16 / coopmat / integer-dot / fusion / …) across quants — i.e. upstream Qualcomm-driver / ggml-shader immaturity, not the build. So arm64 ships **CPU-only** (correct beats fast-but-wrong); `Package.swift` links `vulkan-1` for arm64 only under the same opt-in, and the build path stays in-tree to re-test as the stack matures. See [docs/windows-setup.md](docs/windows-setup.md#4-optional--on-device-ai-llamacpp) and [docs/ai-plugin.md](docs/ai-plugin.md#available-backend-llamacpp).
- **On-device AI reaches Windows — the Phi Silica platform built-in.** A new `PhiSilicaBackend` (`SwiftPWAPhiSilica`) brings the `ai.*` plugin to Windows via the Windows AI APIs' `LanguageModel` in the **Windows App SDK** (Phi Silica) — the Windows counterpart to Apple Foundation Models / Android Gemini Nano, completing the tier-1 *platform-built-in* row on every OS that ships one. A `CPhiSilica` C++/WinRT shim wraps `GetReadyState`/`EnsureReadyAsync`/`CreateAsync`/`GenerateResponseAsync` behind a flat C ABI (async-callback→continuation, mirroring `SystemBiometricAuth`); the Swift side gives `info`/`generate`/`generateStream`/`ensureModel`. Opt in with **`ai.phi_silica: true`** in pwa.json: the CLI sets `SWIFT_PWA_PHI_SILICA=1` (pulling in the env-gated target — **not** in the umbrella, since unlike the built-in-WinRT toast/biometric shims it links the Windows App SDK + its bootstrapper) and the MSIX manifest generator declares the **`systemAIModels`** restricted capability, the **`Microsoft.WindowsAppRuntime`** framework-package dependency (so the AI WinRT classes activate), and bumps min-OS to build 26100. Reports `available: false` (graceful fallback) on any unsupported config instead of crashing. **Verified on a Snapdragon X Copilot+ (arm64 NPU)**: the full integration — cppwinrt projection, build, link, WinAppSDK bootstrap, runtime activation — works, and from a packaged build (identity + `systemAIModels` + the WinAppSDK framework dependency) `ai.info` reports **`available: true` / Ready** on the NPU. **Two hard requirements for generation** (both Windows-platform policy, not swift-pwa): the app must have **MSIX package identity** (the Windows AI APIs return `CapabilityMissing`/`E_ACCESSDENIED` from an unpackaged exe — so swift-pwa's portable-exe default can't reach Phi Silica; `--package-format msix` can), and a Microsoft-issued **Limited Access Feature unlock token** for `com.microsoft.windows.ai.languagemodel` (tied to the app's package family name, from the LAF Access Token Request Form) — pass it via `PhiSilicaBackend(unlockToken:)`, which calls `LimitedAccessFeatures.TryUnlockFeature` (attestation auto-built from the running package's identity). End-to-end generation with a real token is the one step not yet exercised (no token on hand). AMD GPUs are still "coming soon" upstream, so today this is NPU (Copilot+) / NVIDIA-RTX only. See [docs/windows-setup.md](docs/windows-setup.md) and [docs/ai-plugin.md](docs/ai-plugin.md).
- **On-device AI reaches Android — the Gemini Nano platform built-in.** A new `GeminiNanoBackend` brings the `ai.*` plugin to Android via [ML Kit GenAI's Prompt API](https://developers.google.com/ml-kit/genai/prompt/android) (backed by AICore) — the Android counterpart to Apple Foundation Models, filling the tier-1 *platform-built-in* slot on Android. No app-shipped weights: AICore manages the model and downloads it on demand. Provides text (`ai.generate`), **true token streaming** (`ai.generateStream`, via ML Kit's `generateContentStream`, flowing back as host events on a per-call channel — the same `nativeHostEvent` mechanism the updater uses), and on-demand model fetch (`ai.ensureModel`). `ai.info` reports `available: true` even before the one-time download (so a page routes on it and triggers the fetch), matching the downloadable-llama stance. Opt in with **`ai.gemini_nano: true`** in `pwa.json`: on a `--target android` build the CLI adds the `com.google.mlkit:genai-prompt` (+ `kotlinx-coroutines-android`) Gradle dependency and splices the `ai.gemini.*` Kotlin dispatch into the generated scaffold; the Swift backend ships inside `SwiftPWAAndroid` (a thin RPC client, no binary artifact), so it's reachable via `import SwiftPWA` and needs no separate product or env gate. Structured output uses the shared prompt-and-validate fallback for now (`structuredOutput: false`); the base model is text-only. `genai-prompt` is a beta dependency — the generated Kotlin uses fully-qualified ML Kit symbol names (only `kotlinx.coroutines` is imported) so a future beta rename is a localized edit. **Verified end-to-end on a Galaxy Z Fold7**: `ai.info` reports `available: true` / `backend: gemini-nano` / `streaming: true`; `ai.ensureModel` completes via AICore; `ai.generateStream` streams real incremental token deltas; `ai.generate` returns unary text. See [docs/ai-plugin.md](docs/ai-plugin.md#available-backend-android-gemini-nano) and [docs/android-setup.md](docs/android-setup.md#9-on-device-ai-gemini-nano).
- **`Examples/CritterFacts` is now the cross-platform AI showcase.** The fun-fact demo gained Android support — same backend-agnostic page, but on Android it wires `GeminiNanoBackend` (Gemini Nano) instead of llama.cpp, picked by target in the configure closure. So one example now exercises both on-device tiers: the portable llama.cpp backend on Apple (Metal) / Linux + Windows (Vulkan), and the platform built-ins (Apple Foundation Models — swappable in; Android Gemini Nano). Adds an Android JNI entry, the `-no-pie -shared` linker flags, and an `android` section + `ai.gemini_nano: true` to its `pwa.json`.

## [0.7.3] - 2026-06-27

### Added

- **`swift-pwa build --target windows --single-file` — ship a Windows portable app as one `.exe`.** The portable format was a *folder* (`<App>.exe` + `web/` + `pwa.json`) — awkward to distribute. `--single-file` now **embeds `web/` as an overlay appended to the exe** and emits a single self-contained `build\<App>.exe`; at runtime the app reads its own executable's overlay and **serves the bundle from memory** through the existing WebView2 `WebResourceRequested` path (no extraction to disk). Detected transparently — a `.bundled(directory:)` app needs no code change; the runtime serves embedded assets when present and falls back to the disk `web/` otherwise. Appending after the PE image is the standard "overlay" technique (the loader ignores trailing bytes), so the exe still runs; the append happens after the manifest-embed + subsystem-flip steps. Windows-only (the one platform whose artifact was a loose folder — `.app`/AppImage/`.ipa`/`.apk` already bundle `web/` inside); not combinable with `--package-format msix` (MSIX already packages everything). Current limits: full-body responses only (no range serving — ship large media via `serveDirectory`, which stays disk/range-aware), uncompressed overlay, no SPA deep-link fallback. See [docs/windows-setup.md](docs/windows-setup.md).
- **Portable on-device llama.cpp backend now runs on Linux (Vulkan GPU).** `SwiftPWALlama` / `LlamaBackend` extends from Apple-only to **Linux x86_64**, GPU-accelerated via **Vulkan** — one artifact covers NVIDIA + AMD + Intel through the driver's ICD, with CPU fallback. No Swift logic changed: `CLlama` is platform-branched in `Package.swift` (Apple `.binaryTarget` xcframework / Linux `.systemLibrary` over committed, version-pinned headers in `Vendor/llama-headers/`), and the prebuilt static `libllama.a` is found at link time via the `LIBRARY_PATH` the CLI sets — **no `unsafeFlags`**, which would poison every adopter's dependency resolution. Why this shape: SwiftPM has no clean binary-library target off-Apple, and `-L`-via-`unsafeFlags` is fatal even when env-gated; `.linkedLibrary` + an env-provided search path is the safe equivalent (the same trick `CWebView2Shim` uses with `LIB` on Windows). Enable per app with the same **`ai.local_llama: true`** flag; on a `--target linux` build the CLI fetches the checksummed `libllama.a` (built from the same pinned llama.cpp commit as the xcframework by `Scripts/build-llama-linux.sh`, published by the `llama-linux` workflow) and points the build at it. Requires `libvulkan-dev` at link time and a Vulkan 1.2+ driver/ICD at runtime; x86_64-only for now (Windows ships in this same release, below). Verified end-to-end on real hardware — token generation offloaded to an RTX 5080. See [docs/linux-setup.md](docs/linux-setup.md#7-optional--on-device-ai-llamacpp-vulkan) and [docs/ai-plugin.md](docs/ai-plugin.md#available-backend-llamacpp).
- **…and on Windows (Vulkan GPU), the same way.** `SwiftPWALlama` / `LlamaBackend` now also covers **Windows x64**, GPU-accelerated via **Vulkan** (NVIDIA + AMD + Intel via the driver ICD, CPU fallback). Mechanically identical to the Linux slice — `CLlama`'s `#if os(Linux)` `.systemLibrary` branch in `Package.swift` is extended to `#if os(Windows)` over the same committed `Vendor/llama-headers/`, and the prebuilt static `llama.lib` is found at link time via the **`LIB`** env var the CLI sets (the MSVC-linker counterpart to Linux's `LIBRARY_PATH`, and the exact trick `CWebView2Shim` already uses) — still **no `unsafeFlags`**. On a `--target windows` build the CLI fetches the checksummed `llama.lib` (built from the same pinned llama.cpp commit by `Scripts/build-llama-windows.ps1` — MSVC + `lib.exe` to combine the static slices — published by the `llama-windows` workflow) and prepends its dir to `LIB`. Requires the Vulkan SDK's `vulkan-1.lib` at link time and a Vulkan 1.2+ driver/ICD at runtime; x64-only for now (arm64-Windows isn't built). CI's `windows-llama` job is a build/link check (no GPU on runners, and `swift test` can't run on Windows); device-level GPU verification is manual. See [docs/windows-setup.md](docs/windows-setup.md#4-optional--on-device-ai-llamacpp) and [docs/ai-plugin.md](docs/ai-plugin.md#available-backend-llamacpp).
- **`ai.ensureModel`'s downloader is now cross-platform.** `ModelDownloader`'s resumable, checksum-pinned network download was macOS/iOS-only — it used `URLSession.bytes(for:)`, which swift-corelibs-foundation doesn't ship. Linux/Windows now get the identical streamed, resumable (`Range`/206, with 200-restart), progress-reporting download through a `URLSessionDataDelegate` that writes each delivered chunk to the `.part` file. This is the prerequisite for fetching a GGUF on those hosts, and the full download test suite (fresh download, resume, ignored-range restart, checksum mismatch, progress) now runs on **every** platform rather than Apple-only.
- **New example — `Examples/CritterFacts`.** A minimal showcase of the on-device llama.cpp backend: tap a button and a local LLM streams back a one-sentence fun fact about a random critter. Exercises the whole path — `ai.local_llama: true`, `ai.ensureModel` (downloads a tiny ~400 MB Apache-2.0 GGUF on first run, with a progress bar), and `ai.generateStream` (tokens stream into the UI) — on Apple (Metal), Linux (Vulkan), and Windows (Vulkan) from one codebase. Also ships a headless self-test (`CRITTERFACTS_SMOKE=1`, optional `SMOKE_MODEL=<path>`) that runs one generation and exits — handy for verifying the on-device path (including a packaged AppImage's bundled Vulkan loader) without driving the UI.

### Fixed

- **Diagnostic stderr writes no longer crash a GUI app with no console.** A `FileHandle.standardError.write(_:)` (the legacy non-throwing API) **`fatalError`s when the write fails** on swift-corelibs-foundation — and on a **Windows GUI-subsystem app the standard handles are invalid** (no console attached). So llama.cpp's error-log callback (`llama_log_set` → `FileHandle.standardError.write`), firing on an ERROR-level line mid-generation, turned into an illegal-instruction trap in `swiftCore.dll` — an intermittent crash that only reproduced on a **direct** launch (Explorer), not when run from a shell where stderr is redirected to a file. (This is the crash that `editbin /SUBSYSTEM:WINDOWS` *exposed* — it removed the console that had been masking the unsafe write; not a regression in the console fix itself.) All runtime-side stderr diagnostics now go through a new `FileHandle.writeQuietly(_:)` (throwing `write(contentsOf:)` + `try?`), so a log line that can't be written is dropped, never fatal — across the llama, WebView2/Windows, WKWebView/Apple, and GTK backends. Resolves the intermittent CritterFacts crash.
- **Windows WebView2 keeps its profile in `%LOCALAPPDATA%`, not inside the app bundle.** The backend created the WebView2 environment with a null user-data folder, so WebView2 fell back to its default — `<exe>.WebView2\` *next to the executable*. That dropped a browser profile (cache, cookies, IndexedDB/localStorage) into the produced bundle the moment the app ran: it polluted the bundle, locked it against in-place updates (a running `msedgewebview2.exe` holds those files open), and would fail outright if the app were installed somewhere read-only (`C:\Program Files\…`). The environment now uses `%LOCALAPPDATA%\<appID>\WebData` (created on demand) — where Chromium-based browsers keep their profiles — matching the per-user state locations the macOS/Linux backends already use. (The leaf is the generic `WebData`, not the backend name, so the path doesn't telegraph the webview implementation.) Falls back to the default only if `%LOCALAPPDATA%` can't be resolved.
- **Windows per-app data/cache dirs (and `app.name`) no longer include the `.exe` suffix.** With no `Info.plist`, `AppPlugin.appName()` falls back to `ProcessInfo.processName`, which on Windows carries the executable extension — so `ctx.dataDirectory()` resolved to `%APPDATA%\MyApp.exe\…` (and `app.name` reported `"MyApp.exe"`) instead of `%APPDATA%\MyApp\…`. The fallback now strips a trailing `.exe` (case-insensitive; only `.exe`, so a Unix binary named `my.tool` is untouched; a no-op on macOS/Linux/Android). Surfaced in the CritterFacts Windows GUI.
- **Windows portable apps no longer open a stray console window.** A `swift-pwa build --target windows` EXE is linked by SwiftPM as the **CONSOLE** subsystem (a Swift `@main` program enters through the C runtime's `main`), so double-clicking it in Explorer made Windows allocate a console window *alongside* the app's actual WebView2 window — the "this isn't a real app" tell. The bundler now runs `editbin /SUBSYSTEM:WINDOWS` on the bundled EXE after linking (same post-build step family as the `mt.exe` manifest embed): it flips only the PE subsystem field, leaving the `mainCRTStartup` entry intact so Swift's `main` still runs — no `WinMain` shim, no `unsafeFlags` in the user's package. GUI window only now. If `editbin` isn't on PATH (run outside a VS Developer shell) it warns and leaves the console as-is rather than failing the build. (Trade-off: `print`/stderr go nowhere when launched from Explorer — correct for a shipped GUI app; `swift run` still shows logs in development.)
- **A downloadable `LlamaBackend` now reports `ai.info` `available: true` before its model is fetched.** It previously reported `available` = "model file exists", so a backend wired with `LlamaBackend(model:cacheDirectory:)` looked unavailable until the GGUF was downloaded — but the contract tells pages to *route on `available`*, and the model only downloads via `ai.ensureModel` on first use. A page that disables itself on `!available` (like the CritterFacts demo) could therefore never trigger the download: a deadlock, and on-device AI looked broken even though the backend was present and working (the headless smoke path, which calls `ensureModel`/`generate` directly, was unaffected — which is why it passed while the GUI showed "No on-device AI backend"). A downloadable backend now reports `available: true` (it can fetch + run); the fixed-`modelPath:` initializer still gates on the file existing (it has no way to obtain a missing model). Surfaced running the CritterFacts GUI on Windows.
- **`swift-pwa build --target linux` no longer fails at icon deploy for apps without an icon.** The AppImage bundler's built-in placeholder PNG (written when `pwa.json` has no `icon`) was a hand-trimmed 1×1 literal with a **corrupt `IDAT` CRC**; linuxdeploy's libpng validates chunk CRCs and aborted with `IDAT: CRC error → Failed to deploy icon`, killing the build right after everything else (swift build, llama link, lib bundling) had succeeded. Replaced it with a valid 256×256 transparent PNG (correct CRCs, standard icon size). Surfaced while building the first llama-enabled Linux AppImage end-to-end (`Examples/CritterFacts`), now verified producing a runnable `.AppImage` whose bundled Vulkan loader drives GPU inference.

## [0.7.2] - 2026-06-27

### Added

- **`fs.extractZip` / `fs.listZip` accept a `content://` source on Android.** An Android SAF pick (`dialog.openFile`) hands back a `content://` URI, but the zip ops required a real filesystem path — so importing a user-picked archive forced a `readBinary → base64 → writeBinary` materialize first, the exact JS↔Swift bridge cost the native extractor exists to avoid (and worst on the multi-GB packs that motivated it). The source archive may now be a `content://` URI: the Kotlin handlers open it via `ContentResolver.openInputStream` → `ZipInputStream` (vs random-access `ZipFile` for a real path), so a SAF-picked pack extracts off-bridge in one call. The destination must still be a real path (SAF exposes no writable tree). Guards are preserved — path-traversal + entry-count throughout, and the streaming path enforces the uncompressed-byte cap *during* the copy (stronger than a header-size precheck), applying the ratio guard when entry sizes are known. Desktop is unaffected (`content://` is Android-only). (Android adopter feedback.)

### Fixed

- **The prebuilt single-file `swift-pwa` binary can build Android again.** `build --target android` from a prebuilt CLI trapped with `Fatal error: could not load resource bundle … swift-pwa_SwiftPWACore.bundle`: the Android bundler staged `bridge.js` via `SwiftPWACore.BridgeScript.source()`, which reads `Bundle.module` — and a single-file binary has no co-located `SwiftPWACore.bundle`. (Only the Android path hit it; the CLI stages `bridge.js` into the APK, whereas desktop apps get it from their own linked Core at runtime.) Since the Quickstart points users at the prebuilt binary, this blocked Android for the common case. `bridge.js` is now base64-embedded into the CLI (`BridgeJSData`, mirroring the Gradle-wrapper embed) and staged from there; a test guards it against drifting from the canonical Core resource. (Android adopter feedback.)
- **Android manual cross-compile docs now stage the Swift runtime libraries.** [docs/android-setup.md](docs/android-setup.md)'s §4 Option A (scaffold-only, then copy the built `.so` into `jniLibs/`) only mentioned the app `.so`, so a hand-staged APK launched to `UnsatisfiedLinkError: library "libswiftCore.so" not found` — it omitted the Swift stdlib `.so`s and the NDK's `libc++_shared.so` that `--cross-compile-android`'s `stageSwiftRuntime` copies automatically. The docs now list those copies (and recommend Option B, which does it for you).

## [0.7.1] - 2026-06-27

### Added

- **Portable on-device backend: llama.cpp (`SwiftPWALlama` / `LlamaBackend`), Apple first.** The cross-platform counterpart to Foundation Models — runs a GGUF model on-device (Metal-accelerated) wherever the prebuilt llama xcframework ships, independent of OS-level model availability. Text (`generate`), token streaming (`generateStream`), and **native schema-constrained** `generateJSON` via a GBNF grammar compiled from the request's JSON Schema (`structuredOutput: true`; schemas outside the supported subset fall back to the shared prompt-and-validate path). `ai.ensureModel` is wired to `ModelDownloader` for the downloadable-model tier. Construct with a fixed `modelPath:` or a downloadable `model:cacheDirectory:` spec, then `ctx.use(AIPlugin(LlamaBackend(...)))`. Why a **prebuilt xcframework** rather than vendored source: ggml is 135+ per-arch model files, a C++/ObjC Metal backend with a shader-embed step, and per-file SIMD flags SwiftPM can't express (`unsafeFlags` would poison every adopter's dependency resolution); llama.cpp's own CMake builds it correctly, so we package its output. Built from a pinned commit by `Scripts/build-llama-xcframework.sh`. Off by default — enabled per app via **`ai.local_llama: true`** in `pwa.json`, which makes `swift-pwa build` set `SWIFT_PWA_LLAMA=1` so SwiftPM pulls in the `.binaryTarget` (downloaded + checksum-verified once, cached); when unset the binary is never resolved, so non-AI adopters and Linux/Windows CI are unaffected. Linux/Windows packaging is deferred (verified on those hosts when it lands). See [docs/ai-plugin.md](docs/ai-plugin.md#available-backend-llamacpp).
- **`build --target ios --team <TEAMID>` — convenience signing.** Pass a 10-character Apple Developer Team ID and swift-pwa fills in the device-signing inputs you didn't pass explicitly: it selects that team's "Apple Development" identity (so `--sign` is optional) and finds an installed provisioning profile matching the app's bundle id, deriving entitlements from it (so `--provisioning-profile` / `--entitlements` are optional). Explicit flags still win. It's a convenience over the manual path for a developer who already has Xcode-managed signing — it does **not** create a profile from nothing (a SwiftPM package has no app-target Xcode project for `xcodebuild` to auto-provision; that's noted, with a fall-back to the explicit flags). See [docs/ios-setup.md](docs/ios-setup.md#--team-fewer-flags-when-you-already-have-signing-set-up).

### Changed

- **`AIStructuredFallback` is now public** so an out-of-module backend that overrides `generateJSON` (e.g. `LlamaBackend`, for schemas its native grammar can't express) can still reach the shared prompt-and-validate fallback.

### Fixed

- **`build --target ios --sign` no longer fails on a package without a development team.** 0.7.0 passed `CODE_SIGN_IDENTITY` to the `xcodebuild` build phase *and* re-signed the assembled `.app` afterward (embed profile + entitlements + nested bundles). But xcodebuild can't auto-provision a SwiftPM-target product, so with a real `Apple Development` identity and no `DEVELOPMENT_TEAM`, the build phase failed with *"requires a development team"* before the post-assembly signing ever ran — blocking device builds for anyone without a team configured in an `.xcodeproj` (which swift-pwa apps don't have, including free-personal-team developers). The build phase now runs **unsigned** (`CODE_SIGNING_ALLOWED=NO`) for device builds too, and all signing happens post-assembly as before. No `DEVELOPMENT_TEAM` / `.xcodeproj` needed. See [docs/ios-setup.md](docs/ios-setup.md#4-build-for-a-real-device).

## [0.7.0] - 2026-06-26

### Added

- **iOS device builds are installable end-to-end: `--provisioning-profile` + `--entitlements`, and a fail-fast guard.** `build --target ios --sign <id>` codesigned the `.app` but never embedded a provisioning profile or signed with entitlements, so the `.ipa` installed on a device but was denied launch (*"invalid code signature, inadequate entitlements…"*). New `--provisioning-profile <p.mobileprovision>` embeds it as `embedded.mobileprovision`, and `--entitlements <e.plist>` signs with them (`--generate-entitlement-der`), after signing nested resource bundles inside-out — the device path that previously had to be done by hand. A device build with **no** signing now **fails fast** with the fix (rather than emitting an un-launchable `.ipa`); `--simulator` is unaffected. `doctor --target ios` gained a code-signing check that flags a missing identity or the classic untrusted **Apple WWDR intermediate** (with the `security import` hint). See [docs/ios-setup.md](docs/ios-setup.md). (Automatic `--team` signing — generating a thin app-target project so `xcodebuild` provisions for you — is queued for 0.7.1.)
- **`window.background_color` — set the native surface colour before first paint.** The Apple / GTK / WebView2 webviews defaulted to opaque white, so a dark-themed app flashed white (or black, in dark mode) before the page's first paint, and the scroll overscroll / rubber-band area stayed the wrong colour — the most common "this is just a webview" tell. A new `window.background_color` (hex, e.g. `"#F4F7F5"`) in `pwa.json` is applied to the native surface on **every backend** before first paint: Apple sets `isOpaque=false` + `backgroundColor` + `underPageBackgroundColor` (plus the macOS window background), GTK uses `webkit_web_view_set_background_color` (both GTK3 and GTK4 shims), WebView2 sets `DefaultBackgroundColor`, and the **iOS launch storyboard** (previously hard-coded black) takes the same colour so the splash→app transition is seamless. Threaded as `WindowConfig.backgroundColor` into the generated `App.swift`. A single solid colour can only approximate a gradient page background (close, not pixel-exact); omit it to keep the platform default.
- **iOS builds now default to universal (iPhone + iPad).** The generated iOS `Info.plist` emits `UIDeviceFamily = [1, 2]`. Previously the key was absent, so iOS treated the app as iPhone-only and ran it letterboxed in the scaled "iPhone app on iPad" compatibility window — a thin-client WebView app is inherently device-agnostic, so universal is the right default. Override with a new `ios.device_family` field in `pwa.json` (e.g. `[1]` phone-only, `[2]` iPad-only); the `ios.info_plist` passthrough still wins over both.
- **`ai.ensureModel` download manager: `ModelDownloader` (`SwiftPWAModelStore`).** The reusable half of the downloadable-model tier, so `ai.ensureModel` can be real rather than reserved: resumable (HTTP `Range`, restarting only if the server ignores it), SHA-256-pinned, cached on disk with atomic `.part`→final rename, reused across launches, with a progress stream (`AIDownloadEvent`). A backend that ships a downloadable model (llama.cpp / the Gemma fallback) keeps a registry of model specs and drives it from `AIBackend.ensureModel`; the JS command lights up once such a backend is installed (a platform-built-in backend like Foundation Models still reports `E_UNIMPLEMENTED`). Isolated in its own target so apps that use only a built-in never link it; SHA-256 via CryptoKit on Apple / swift-crypto elsewhere. New `AIError.modelDownloadFailed` → stable `E_AI_MODEL` for network/checksum failures. The network download path is currently macOS/iOS only (it uses `URLSession.bytes(for:)`, absent on swift-corelibs-foundation); cache reuse + checksum are cross-platform, and Linux/Windows download lands with the portable backends, verified on those hosts. See [docs/ai-plugin.md](docs/ai-plugin.md#aiensuremodel).
- **First real `ai.*` backend: Apple Foundation Models (`SwiftPWAFoundationModels`).** The on-device system model (Apple Intelligence) behind `AIBackend` — `ctx.use(AIPlugin(FoundationModelsBackend()))`. Text, token streaming, and **native schema-constrained** `generateJSON` via Foundation Models guided generation: the request's JSON Schema is mapped to a `GenerationSchema` (object / array / string+`enum` / integer / number / boolean) and the `GeneratedContent` result back to `JSONValue`, so `structuredOutput` is `true` (decode-time enforcement, not the prompt fallback). Verified end-to-end on-device. Reports `available: false` (app falls back to its own tier) when built against an older SDK, run below macOS 26 / iOS 26, or when the system model isn't ready (unsupported device, Apple Intelligence off, still downloading). Isolated in its own target + product like `SwiftPWAArchive`, gated `#if canImport(FoundationModels)` + `@available`, so apps that don't opt in never link the framework and it still builds on older toolchains. The base system model is text-only (vision / image / audio capability flags stay `false`). See [docs/ai-plugin.md](docs/ai-plugin.md#available-backend-apple-foundation-models).
- **`ai.*` — on-device LLM inference behind the bridge (contract first).** A new opt-in `AIPlugin` lets the page ask for text or schema-constrained JSON without encoding *where* it runs (a platform built-in model, a bundled small model, or the app's own cloud fallback) — the native side owns that. This release ships the **JS contract** (`ai.info`, `ai.generate`, `ai.generateJSON`, streaming `ai.generateStream`, **multimodal vision and audio input** via `images` / `audio` fields on those requests — the audio path covers ASR / phoneme evaluation, **text→image generation** via `ai.generateImage` / streaming `ai.generateImageStream`, **text→audio / TTS** via `ai.generateAudio` / streaming `ai.generateAudioStream`, plus a reserved `ai.ensureModel`), the dependency-free `AIBackend` protocol in Core, the shared **structured-output fallback** (so `ai.generateJSON` returns schema-valid JSON on *any* backend — native schema-constrained decoding where available, otherwise prompt-inject + parse + validate + one repair retry), and `NoneBackend` (reports `available:false`). **No on-device backend is wired yet** — a page integrates against the frozen contract now and lights up unchanged when a backend lands; today `ai.info` reports `available:false` and the app falls back to its own tier. Why contract-first: each real backend (Apple Foundation Models, Android Gemini Nano, Windows Phi Silica; Gemma via MLX / MediaPipe / ONNX / llama.cpp as the portable fallback) is large, platform-specific, and independent — freezing the contract unblocks adopters without coupling the release to any one backend's toolchain. Structured like the zip backends (`ArchiveExtractor` in Core, concrete extractors in an optional target): real backends will land in their own platform-conditional targets, injected via `ctx.use(AIPlugin(MyBackend()))`. Full reference + roadmap: [docs/ai-plugin.md](docs/ai-plugin.md).

### Changed

- **The Android Gradle wrapper is now embedded in the CLI binary, so a prebuilt `swift-pwa` stages `./gradlew` too.** Previously the wrapper shipped as a SwiftPM resource bundle, which a prebuilt single-file binary (the release artifact, or one moved by `self-update`) doesn't carry — so `build --target android` from a prebuilt CLI emitted a project without `./gradlew` and printed a "run `gradle wrapper`" note. The vendored wrapper now lives in `Vendor/gradle-wrapper/` and is base64-embedded into a generated `GradleWrapperData.swift` (regenerated by `Scripts/regenerate-gradle-wrapper.sh` when the pinned Gradle version is bumped). `SwiftPWACLISupport` therefore ships **no resource bundle at all** — which also retires the `ResourceLocator`/`Bundle.module` workaround from 0.6.5, since the trap class it guarded against can no longer occur.

### Fixed

- **`BSDTarListParserTests` no longer fails when the archive suite is run on Linux.** Its real-`tar` case assumed the host `tar` is bsdtar, but Linux ships GNU tar (which can't create/list a `.zip`). It now detects bsdtar specifically and skips otherwise — the hardcoded-sample parser tests still run everywhere, and the real-output check still runs on macOS (and any host with bsdtar). (CI never caught this — the Linux jobs don't run `SwiftPWAArchiveTests` — but it bit anyone running the archive suite locally on Linux.)

## [0.6.5] - 2026-06-26

### Added

- **`macos.info_plist` / `ios.info_plist` — arbitrary `Info.plist` passthrough in `pwa.json`.** The generator emitted a fixed key set; anything it didn't model (App Transport Security, camera/mic usage strings, custom URL schemes) meant patching the built plist by hand. Now a JSON object on the `macos`/`ios` section is merged into the generated plist — after swift-pwa's own keys, so it can also override one — with nested objects/arrays supported. Use exact `Info.plist` key names. Example: `"macos": { "info_plist": { "NSAppTransportSecurity": { "NSAllowsLocalNetworking": true } } }` (reach a local `http://localhost` dev service from the WebView).
- **`build.postbuild` — an after-bundling command hook.** The symmetric counterpart to `build.prebuild`: runs once the platform artifact exists, with its absolute path in `SWIFT_PWA_ARTIFACT` (and the target in `SWIFT_PWA_TARGET`), so an "after bundling" step (a `PlistBuddy` tweak, extra signing, a checksum) no longer means wrapping the whole `swift-pwa build`. Non-zero exit fails the build; `--skip-postbuild` bypasses it.
- **`swift-pwa build`/`doctor` warn on Android `package_id` ↔ `@_cdecl` drift.** Changing `pwa.json`'s `android.package_id` after `init` silently breaks the hand-written `@_cdecl("Java_<pkg>_MainActivity_swiftPwaMain")` symbol in `AndroidEntry.swift`, surfacing only at runtime as `UnsatisfiedLinkError: Native method not found`. The Android bundler and `doctor --target android` now compare the two and warn (with the exact fix) before producing a broken APK.

### Fixed

- **`swift-pwa dev` persists OPFS / localStorage / IndexedDB across launches.** The built-in live-reload server bound an OS-assigned port, so the dev origin (`http://127.0.0.1:<port>`) changed every launch and per-origin web storage appeared wiped — a footgun for any storage-backed feature (SQLite-on-OPFS, etc.) that forced a full `build` to test persistence. It now binds a **fixed default port (4321)** for a stable origin; `--port <n>` overrides, `--port 0` restores the old ephemeral behavior.
- **Prebuilt `swift-pwa` no longer crashes in the Android bundler looking for its resource bundle.** A single-file release binary (or one moved by `self-update`) has no co-located `.bundle`, and the synthesized `Bundle.module` *traps* in that case — before the graceful fallback could run — so `build --target android` died with `could not load resource bundle …`. Resource lookup now goes through a locator that searches relative to the **resolved** executable path (symlinks followed, plus `../share/swift-pwa`) and returns nil instead of trapping, degrading to the existing "run `gradle wrapper`" note.
- **A manifest `web.entry` is now honored by the generated native window.** The scaffolded `App.swift` loaded `.bundled(directory:)` with no entry, so a native build always opened `index.html` regardless of `web.entry` (it only affected `dev`). `init` now threads `web.entry` into `.bundled(directory:, entry:)`.
- **`swift-pwa build` no longer prints a `safe.bareRepository` git warning.** On machines that harden git with `safe.bareRepository = explicit`, SwiftPM's internal git calls printed `warning: skipping cache … couldn't fetch updates` on every build. The CLI now sets the `GIT_CONFIG_*` environment (equivalent to `git -c safe.bareRepository=all`) for the tools it spawns — its child processes only, never the user's git config — unless the user already drives `GIT_CONFIG_*` themselves.
- **`swift-pwa init --in-place` now scaffolds into the current directory instead of nesting a `<name>/` subdir.** The flag flipped the adopt-in-place behavior (merge an existing `pwa.json`, leave `web/` alone) but the target-directory choice ignored it — it only auto-detected an existing `pwa.json`/`web/` and otherwise fell through to the `cwd/<name>` default. So `--in-place` in a repo without a frontend yet (the exact "force it for a non-standard layout" case the flag documents) still nested under `<name>/`. The directory resolution now honors `--in-place` (and `--path` still wins over both).

## [0.6.4] - 2026-06-25

### Added

- **`fs.createZip` — native, path-to-path zip *creation*, the symmetric counterpart to `fs.extractZip`.** For in-app pack authoring / re-export. The common authoring case (a small pack) should still build the `.zip` in the browser as an in-memory `Blob` — no platform support needed, and it runs in a plain tab. `fs.createZip({ from, to, compression? }) → { entries, uncompressedBytes }` is the escape hatch for the giant-file case (a multi-GB folder of video that can't become an in-memory blob) and for re-exporting an *already-installed* pack — whose source is a folder under `app.dataDir()` the browser can't re-`fetch()`. Bytes are read from disk and written into the archive entry-by-entry; they never cross the JS↔Swift bridge (the same constraint that motivated `fs.extractZip`, mirrored for creation). `compression` is `"stored"` (default) or `"deflate"` — pack media (png / webm / jpg / mp4) is already compressed, so storing is faster for the same size; deflate only earns its CPU on text-like payloads. A streaming `subscribe('fs.createZipProgress', …)` variant mirrors `fs.extractZipProgress` for a progress bar. Symlinks in the source are skipped (not followed, not stored), and a failed create leaves no partial `.zip`. Reuses the same opt-in archiver as extraction — `ctx.use(FsPlugin(SystemFs(extractor: ZIPExtractor())))` — so an app that doesn't import packs links nothing extra, and the commands register only when an extractor is injected. All five platforms with the backend that builds there: ZIPFoundation on macOS / iOS / Linux; `tar.exe` (`--format zip --options zip:compression=store|deflate`) on Windows; Kotlin's `java.util.zip` over JNI on Android (where `"stored"` maps to a single-pass deflate-level-0 entry — true STORED would need a CRC pre-pass, a second read of every file, which a multi-GB export can't afford). Part of the [runtime content-packs design](docs/design/runtime-content-packs.md) (Round 4 follow-on).

### Fixed

- **CI: the Linux `Test Core + CLI` step no longer flakes on a swift-corelibs process-exit hang.** On Linux, a swift-testing bundle's async `@main` parks the main thread in `dispatch_main()` after every test passes, waiting for the wakeup that fires the final `exit()` — and ~15–25 % of runs that wakeup is lost (a libdispatch main-queue race, reproduced on Swift 6.0.3 *and* 6.2.0, independent of test selection and `--no-parallel`), so the process hangs until CI's 12-minute timeout kills it. The Linux jobs now run through [`Scripts/ci-test-linux.sh`](Scripts/ci-test-linux.sh), which bounds each `swift test` with a `timeout` and **retries only on a clean timeout** — a genuine failure exits non-zero on the first attempt and fails the job immediately, so nothing is masked. Three attempts drop the residual flake below 1 %. The mechanism is documented in [docs/linux-setup.md](docs/linux-setup.md#swift-test-occasionally-hangs-at-exit-on-linux).

## [0.6.3] - 2026-06-25

### Added

- **`fs.extractZip` / `fs.listZip` — native, path-to-path zip extraction for runtime content packs.** The other half of the content-packs feature: a user picks a multi-GB `.zip` (`dialog.openFile`), the app extracts it natively into its data dir, then serves the media via [`ctx.serveDirectory`](docs/swift-api.md#serving-extra-directories-content-packs). Bytes are read from the archive and written to disk **entry-by-entry** — they never cross the JS↔Swift bridge, so a GB of video doesn't become a ~1.33 GB base64 string the way an `fs.readBinary` + JS-side unzip would. `fs.listZip` peeks the central directory (validate a `pack.json` manifest entry before committing to the extract); a streaming `subscribe('fs.extractZipProgress', …)` variant emits per-entry `progress` events then a `done` event so a GB extract can drive a progress bar. The extractor enforces the guards untrusted file input demands — **path-traversal** rejection, **symlink** rejection, and **zip-bomb** limits (total uncompressed bytes / entry count / per-entry compression ratio, defaulting to a generous-but-finite 8 GiB / 50k / 200:1), extracting to a staging dir and committing only on success so a failed extract never leaves half-populated output. It's **opt-in and isolated**: the ZIPFoundation dependency lives in a separate `SwiftPWAArchive` product, and the commands register only when an extractor is injected — `ctx.use(FsPlugin(SystemFs(extractor: ZIPExtractor())))` — so an app that doesn't import packs links neither ZIPFoundation nor the commands. **All five platforms**, each with the backend that builds there: macOS / iOS / Linux use ZIPFoundation; **Windows** (where ZIPFoundation can't compile under clang-cl) uses the same `ZIPExtractor` backed by `tar.exe` (libarchive's bsdtar, on Windows 10 1803+), guards enforced via a pre-extract `tar -tvf` pass; **Android** (where ZIPFoundation can't build against Bionic libc) uses `AndroidArchiveExtractor`, routing to Kotlin's `java.util.zip` over the JNI bridge with the guards enforced Kotlin-side. Verified end-to-end on a real Android device (extract → serve `/packs` media → `200 image/png`). Part of the [runtime content-packs design](docs/design/runtime-content-packs.md) (Phase C).
- **`ctx.serveDirectory(_:at:)` — serve a writable directory on the bundle origin, with HTTP range support.** The runtime content-packs feature's linchpin: an app mounts a directory (e.g. its per-user data dir) under an app-chosen path prefix so page JS references it with an origin-relative URL — `videoEl.src = "/packs/<id>/clip.webm"` — that works unchanged on every backend regardless of the underlying scheme/host. Read-only (GET); writes still go through `fs.*`. Mounts can be added/removed at runtime (`unserveDirectory(at:)`) and take effect for in-flight requests, so a pack extracted *after* the window exists is immediately fetchable without re-registering anything — and without exposing a "serve any path" capability to page JS (mounting stays the app author's decision). Backed by a single context-level `AssetProvider` (the bundle is just its `/` mount) shared into every window's scheme handler. Range / `206 Partial Content` is honored on all backends so large `<video>` seeks/streams off disk instead of buffering: Apple `WKURLSchemeHandler`, GTK3/GTK4, Windows via `WebResourceRequested` interception (the bundle keeps its native virtual-host mapping; only served mounts are intercepted), and Android via `WebViewAssetLoader.InternalStoragePathHandler`. On **Android** the asset loader is built at Activity-init before any Swift runs, so startup mounts are declared in `pwa.json` (`"build": { "serve": [ { "mount": "/packs", "from": "data/packs" } ] }`) and the bundler wires each into the generated Kotlin; a runtime `serveDirectory` for an undeclared prefix is a desktop capability. Part of the [runtime content-packs design](docs/design/runtime-content-packs.md) (Phase B).

### Fixed

- **Android bundler now finds the Swift Android runtime on a Linux build host.** `swift-pwa build --target android`'s runtime-`.so`-bundling step hard-coded the macOS swift-sdks path (`~/Library/org.swift.swiftpm/swift-sdks`), so on a **Linux** host (CI, and most cross-compile setups) it silently found nothing and skipped bundling the Swift stdlib — producing an APK that *assembles* fine but **crashes at `System.loadLibrary` on-device** (CI's assemble-only check never caught it; surfaced building HelloPWA on a real Linux box). The path now resolves against the host OS — `${XDG_DATA_HOME:-~/.local/share}/swiftpm/swift-sdks` on Linux — matching `swift sdk install`'s layout. Verified on a real device: the runtime libs now bundle (APK 12 MB → 84 MB) and the app launches instead of crashing at load.
- **Android `build.serve` mounts now actually resolve.** `WebViewAssetLoader` matches path handlers in registration order, and the catch-all `"/"` bundle handler was registered before `/packs/`, so it shadowed every served mount — `/packs/…` media 404'd out of the bundle assets and rendered broken. Served mounts are now registered first. (Found by the on-device run, not CI.)
- **`swift-pwa dev` no longer leaks its accept thread on `stop()` (Linux).** The dev server's `accept()` loop blocked indefinitely, and on Linux closing the listen socket from `stop()` doesn't wake a thread already blocked in `accept()` (Darwin does) — leaving the thread, and the process, alive. It now polls the socket with a short timeout so `stop()` ends the thread promptly.

## [0.6.2] - 2026-06-24

### Added

- **`pwa.json` `build.prebuild` — a declared pre-bundle command.** `swift-pwa build` copies `web/` into the bundle wholesale, but there was no declared place to run a step that *produces* part of `web/` first (a codegen index, an esbuild / Tailwind pass, a sprite-atlas packer). Projects bolted it on outside the tool and the generated CI workflow didn't know about it — so cloud releases silently shipped whatever generated artifact was committed, a footgun teams had to document by hand. Now `"build": { "prebuild": "node scripts/build-index.mjs" }` runs from the project root before `web/` is staged, on *every* `swift-pwa build` — and because the generated `release.yml` just calls `swift-pwa build`, cloud releases stay correct with no hand-maintained "regenerate before tagging" ritual. A non-zero exit aborts the build (a half-generated `web/` never ships). It runs through the platform shell (`/bin/sh -c`, `cmd /c` on Windows). `build --skip-prebuild` bypasses it for fast local iteration; the generated workflow's header notes that a prebuild needing a toolchain (Node, etc.) wants a matching setup step. Documented in [README.md](README.md).
- **`swift-pwa self-update` — update the CLI binary in place.** Previously the only way to update was to hand-download a release asset and drop it on your `PATH` — and on macOS, `cp`-ing the new binary over the old one gets the process `Killed: 9` on first run: `cp` reuses the inode, and the kernel had a code-signing validation cached against that path/inode, so the new bytes' adhoc signature no longer matches. It reads exactly like a corrupt download when it isn't. `self-update` resolves the latest release (or a pinned `--version`), downloads the asset for the host OS/arch, **runs its `--version` from a fresh temp path to verify it's neither corrupt nor wrong** (a new path, so it doesn't hit the stale cache either), then installs it with an atomic `rename(2)` onto this binary's own resolved path — a fresh inode, which sidesteps the SIGKILL trap entirely. Permission errors (e.g. a binary under `/usr/local`) print a clear "re-run with sudo" hint. macOS / Linux; Windows can't replace a running `.exe`, so it prints manual steps. (Homebrew installs should use `brew upgrade`; a first-party tap is a planned follow-up.) Documented in [README.md](README.md).

## [0.6.1] - 2026-06-24

### Added

- **`AppPlugin` — built-in `app.quit` / `app.name` / `app.version`, auto-installed on every backend.** `window.close` closes a *window*; on macOS that leaves the app alive in the menu bar, so a "Quit" button previously meant dropping into Swift to register a custom command that hopped to the UI thread and called `AppContext.quit`. `app.quit` (optional `{ exitCode }`) makes it a one-liner from JS. `app.name` / `app.version` read the bundle's `Info.plist` (`CFBundleDisplayName` / `CFBundleShortVersionString`), with a process-name fallback for `name` and an empty string for `version` on hosts without an `Info.plist` (Linux / Android) — so an About box doesn't need a bundled config. Documented in [docs/javascript-api.md](docs/javascript-api.md) and [docs/swift-api.md](docs/swift-api.md).
- **`swift-pwa doctor` now flags a generated native shell that lags the CLI.** The generated `Sources/<name>/App.swift` and `AndroidEntry.swift` carry a `// swift-pwa-generated: vX` stamp, and `doctor` reads it: a project scaffolded on an older CLI (whose `App.swift` predates a template change — e.g. the `PWA_DEV_SERVER` branch `swift-pwa dev` relies on) gets a clear "generated by vY, CLI is vX — regenerate" warning with the one-line fix, instead of a silent mismatch that surfaces as a mid-run crash. Best-effort and never fails the check (a stale shell still builds); no-op outside a project. Extends doctor's upfront-check philosophy from toolchains to the generated Swift.

### Changed

- **The generated release workflow pins the CLI version in one place.** `.github/workflows/release.yml` now reads the `swift-pwa` CLI version from a single workflow-level `SWIFT_PWA_CLI_VERSION` env var instead of hardcoding it into three download URLs — so upgrading the CLI is a one-line edit, not a find-and-replace across the macOS / Linux / Windows jobs.

### Fixed

- **Corrected stale argument names in [docs/javascript-api.md](docs/javascript-api.md).** The JS API reference had drifted from the code — `window.setFullscreen` takes `{ on }` not `{ fullscreen }`, `fs.writeBinary`/`readBinary` use `dataBase64` not `base64`, `fs.copy`/`rename` take `{ from, to }` not `{ src, dst }`, `tray.setTooltip` takes `{ text }` not `{ tooltip }`, `notifications.send`'s `sound` is a `Bool`, and `window.size`/`position` return bare `{ width, height }` / `{ x, y }`. Wrong examples are worse than none (they're why adopters end up grepping the checkout); the reference now matches the registered command signatures, and a note points at `__platform.info` for discovering the live command set at runtime.

## [0.6.0] - 2026-06-24

### Added

- **`swift-pwa dev` now runs a built-in live-reload server — no JS framework or external dev server required.** With no `--server`, it serves the project's `web/` directory over `http://127.0.0.1:<port>` (hand-rolled POSIX socket HTTP server, no dependency), injects a one-line SSE live-reload client into HTML responses, watches the directory tree, and refreshes the app on any file change. `--server <url>` keeps the previous behavior (point at your own Vite/etc. with its own HMR). Both set `PWA_DEV_SERVER`, and the generated `App.swift` now honors it — loading the dev URL when set, falling back to the bundled assets otherwise (previously `PWA_DEV_SERVER` was documented but unread, so `dev` was a no-op). The built-in server is macOS/Linux only for now; Windows still needs `--server`. Replaces the v0.5 "`dev` just sets an env var" behavior.
- **`swift-pwa build --target macos --notarize <keychain-profile>` automates notarization.** Previously the bundler stopped at codesign and only *printed* the `notarytool` command. Now passing `--notarize` (with `--sign`) signs the `.app` with a hardened runtime (`--options runtime --timestamp`), zips it, submits it to Apple's notary service with `--wait`, and staples the ticket onto the `.app` — the full submit → wait → staple loop in one step. A rejected submission fails the build; `--notarize` without `--sign` errors up front (Apple only accepts Developer ID-signed apps). The keychain profile is created once with `xcrun notarytool store-credentials`. Documented in [docs/macos-setup.md](docs/macos-setup.md) §6.
- **`swift-pwa doctor` — a per-target prerequisite checker.** `swift-pwa doctor [--target <platform>]` reports which toolchains a target's build needs are installed, with a copy-paste fix for each gap (Xcode + a Simulator runtime for iOS, `linuxdeploy` for AppImages, `ANDROID_NDK_HOME` + JDK + the Swift Android SDK for Android, MSVC on Windows, codesign/iconutil/actool where relevant). Defaults to the host platform; exits non-zero when a *required* tool is missing so it's usable in scripts. Each probe is bounded by a timeout and discards subprocess stderr, so a wedged toolchain (e.g. an `xcrun` stuck on Xcode first-launch) produces a clean report instead of hanging the checker. Turns a cryptic mid-build toolchain failure into a friendly upfront message.
- **One `pwa.json` `icon` PNG now becomes the app icon on iOS and Android too, not just macOS.** Previously a single 1024² PNG only produced the macOS `.icns`; iOS used it only for a launch screen (default home-screen icon) and Android showed the default launcher icon. Now the iOS bundler compiles it into a real `AppIcon` via `actool` (a single "universal" 1024 asset — Xcode generates the full size set — merging the resulting `CFBundleIcons*` keys into `Info.plist`), and the Android bundler drops it into `res/mipmap/ic_launcher.png` and wires `android:icon` in the manifest (aapt/Gradle scale per density at build time — no pre-resizing, so it works on the Linux CI runner). Both are best-effort: a missing / non-PNG icon (or an `actool` that can't run) leaves the platform default and never fails the build. Windows `.exe` icon embedding is still TODO. The iOS path is exercised in CI (it needs a Mac + Xcode); the Android path is verified from the generated Gradle project.
- **`swift-pwa init` scaffolds a GitHub Actions release workflow (`.github/workflows/release.yml`), and a new `swift-pwa generate-ci` adds it to an existing project.** This is the "ship cross-platform from one machine" path: pushing a `v*` tag builds macOS / Linux / Windows in the cloud — each job downloads the prebuilt `swift-pwa` CLI (pinned to the scaffolding version) and runs the platform bundler, with toolchain-setup steps mirrored from swift-pwa's own validated CI — and attaches the artifacts to a GitHub Release. No local Swift / MSVC / GTK toolchains required. iOS and Android ship as commented, opt-in stub jobs (they need signing material / a cross-compile SDK that can't be wired up generically). `init` writes it by default (skipped if one already exists; opt out with `--no-ci-workflow`); `generate-ci` covers already-scaffolded projects and refuses to clobber an existing workflow without `--force`.

## [0.5.2] - 2026-06-24

### Changed

- **The bundlers now discover the executable name from the package itself, so `executable_name` is rarely needed.** Previously the binary the bundler looked for at `.build/release/<X>` was derived from `pwa.json` (`executable_name ?? name`), which meant a `name` with spaces *required* an `executable_name` override or the build failed late. Now a new `ExecutableNameResolver` runs `swift package describe --type json` and uses the package's sole executable product as `<X>` — so `"name": "My App"` builds correctly with no `executable_name` at all (verified end-to-end: a spaced-name project with no override produces `My App.app` containing `Contents/MacOS/MyApp`, `CFBundleExecutable = MyApp`). `executable_name` is now an *override*, needed only when discovery is ambiguous (a package declaring more than one executable product); it still wins when set, and `linux.executable_name` still overrides for Linux. Applied across all five bundlers (macOS `.app`/`CFBundleExecutable`, iOS xcodebuild `-scheme`/`CFBundleExecutable`, Linux AppImage, Windows `.exe`, Android `lib<name>.so`). Falls back to the old `executable_name ?? name` if the probe can't run.
- **`swift-pwa init` no longer writes `executable_name`** into generated / merged manifests — the SwiftPM target name is discovered from the package, so the field would only be noise. Existing manifests that set it keep working (it's still an honored override).
- **`build` preflight no longer rejects a `name` with whitespace** — that's valid now (the target name comes from `Package.swift`, not `name`). It still rejects whitespace in an explicit `executable_name`, which must name a SwiftPM target.

### Added

- **`docs/tutorials/` — a new copy-paste-friendly, Swift-optional tutorial series.** First entry: [docs/tutorials/saving-and-loading-files.md](docs/tutorials/saving-and-loading-files.md), a walkthrough of native Save / Open (Export / Import) over the `dialog.*` + `fs.*` plugins with an automatic browser fallback, written for web devs (e.g. indie game devs) wrapping an existing app who don't want to learn Swift first. Adapted from adopter-contributed material; every `invoke` command / payload shape was verified against `DialogPlugin` / `FsPlugin`. Indexed in [docs/tutorials/README.md](docs/tutorials/README.md) and linked from the README.

## [0.5.1] - 2026-06-24

### Added

- **`pwa.json` `executable_name`: decouples the human-facing display name from the SwiftPM target / binary name.** `name` was silently overloaded as *three* things — the SwiftPM product binary the bundler looks for at `.build/release/<name>`, the `.app` / binary basename, and the display string (`CFBundleName` / `CFBundleDisplayName` / `.desktop` `Name=`). Because it's the SwiftPM **target** name it can't contain a space, so a `"name": "Field Notes"` compiled fine (the target in `Package.swift` is still `FieldNotes`) and then failed *late* at the bundling step with a cryptic `expected built binary at .../release/Field Notes`. New optional top-level `executable_name` carries the SwiftPM target name; `name` is now purely the human-facing label and may contain spaces. The bundlers resolve the binary via `executable_name ?? name` (new `PWAManifest.binaryName`) across **every** platform — macOS `.app` + `CFBundleExecutable`, iOS xcodebuild `-scheme` + `CFBundleExecutable`, Linux AppImage binary (`linux.executable_name` still overrides there), Windows `.exe`, Android `lib<target>.so` — while the `.app` filename and `CFBundleName` / `CFBundleDisplayName` use `name`. So "Field Notes.app" can show "Field Notes" in Finder while the binary / target stays `FieldNotes`. Mirrors the pre-existing `linux.executable_name` precedent, now generalized. Documented in [README.md](README.md)'s `pwa.json` section.
- **`swift-pwa init` adopts an existing web app in place (auto-detected; `--in-place` forces it).** `init` previously only laid down a brand-new directory (its own `pwa.json` + starter `web/index.html`), so wrapping an existing frontend meant scaffolding in a temp dir and hand-merging `Package.swift` / `Sources/` / the per-platform `pwa.json` blocks. Now, run from a directory that already has a `pwa.json` or a `web/` (or point `--path` at one) and `init` adopts it: it resolves the project root to that directory instead of nesting a `<name>/` subdir, adds *only* the native shell (`Package.swift` + `Sources/<name>/`), leaves an existing `web/` exactly as-is, and **shallow-merges** the defaults a fresh project would get into an existing `pwa.json` — adding only top-level keys that are absent, preserving everything the user set (including non-schema fields, via a raw-JSON merge rather than a lossy Codable round-trip). It pins `executable_name` to the generated SwiftPM target so the bundler's binary lookup can't drift from the `Package.swift` it just wrote. A directory with neither marker still gets the fresh-project `<name>/` subdir. The `--in-place` flag forces adoption for a frontend in a non-standard layout (a custom `dist/` with no `pwa.json` yet). Documented in [README.md](README.md)'s Quickstart.
- **`swift-pwa build --target` defaults to the host platform when omitted.** `--target` was required; now `swift-pwa build` with no target bundles for the desktop OS running the CLI (`macos` / `linux` / `windows`). Cross-targets (`ios`, `android`) and bundling for another desktop OS stay explicit. Documented in [README.md](README.md)'s Build section.

### Changed

- **`swift-pwa init` now writes the human-facing name to `name` and the sanitized identifier to `executable_name`.** Previously the display string lived only in `window.title` and `name` was forced to the sanitized identifier (so `init "My App"` produced `"name": "MyApp"`). Now `init "Field Notes"` writes `"name": "Field Notes"`, `"executable_name": "FieldNotes"`; an already-identifier-safe name like `MyApp` omits `executable_name` entirely (it falls back to `name`), keeping the manifest clean.
- **Generated `App.swift` is seeded from the full `pwa.json` `window` block** — `width` / `height` / `resizable` / `fullscreen`, not just `title` + a hardcoded `1024×768`. A prominent comment now states that the `WindowConfig` literal is the *runtime* source of truth and that `pwa.json`'s `window` block is build-time metadata seeded at `init` time only — editing it afterwards has no runtime effect. This closes the silent-divergence trap where changing `pwa.json` `window.*` appeared to do nothing. Documented in [README.md](README.md).
- **`swift-pwa --version` reports the actual release (was a stale hardcoded `0.1.0`).** Stamped from a single `SwiftPWAVersion.current` constant so the CLI version matches the `SwiftPWA` library a generated project resolves; the `init`-generated `Package.swift` dependency floor tracks the same constant.

### Fixed

- **`swift-pwa build` gives swift-pwa-level guidance instead of a raw toolchain error in two common newcomer cases.** (1) Running `build` in a directory with `pwa.json` + `web/` but no `Package.swift` previously dropped the underlying `swift build` error (`Could not find Package.swift…`), with no hint that swift-pwa projects need the `init` scaffold; a new preflight detects the missing `Package.swift` and points at `swift-pwa init` / `init --in-place`. (2) A `name` (or `executable_name`) containing whitespace now fails *up front* with the fix (set `executable_name`) rather than late, after a full successful compile, with a confusing "binary missing". The `binaryMissing` error itself now names the likely cause (`name` ↔ SwiftPM target mismatch) and the remedy.

- **`swift test` no longer fails to compile under a Command Line Tools-only toolchain selection.** `Tests/SwiftPWAGTKTests/Placeholder.swift` carried a bare, unguarded `import Testing` despite its own comment declaring the file "intentionally empty on macOS" — every sibling backend-test file (`LinuxAppImageUpdaterTests.swift`, `SwiftPWAAndroidTests.swift`) wraps its imports in `#if os(...)`, but this one didn't. The stray import made the whole `swift test` invocation depend on the swift-testing `Testing` module resolving for that target on macOS, which it doesn't when the active developer dir is `/Library/Developer/CommandLineTools` rather than a full Xcode (CLT's SwiftPM doesn't wire up swift-testing). Guarded the import behind `#if os(Linux)` so the file is genuinely empty off-Linux, matching the sibling files. (The CLT-vs-Xcode toolchain selection is the environment fix — `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` — but the unguarded import was a latent source bug regardless.)
- **CI: `android` job's swiftly toolchain install no longer fails on ubuntu-24.04.** `swiftly install 6.2.0` exits non-zero when `libcurl4-openssl-dev` isn't present, and the runner image dropped it from the default set — the toolchain extracted fine but the step failed before the NDK install / cross-compile / `assembleDebug` could run. New "Install Swift toolchain runtime deps" step in `.github/workflows/ci.yml` apt-installs the package before swiftly runs.
- **CI: `android` job locates `setup-android-sdk.sh` via `find` instead of two hard-coded paths.** Previous fallback chain checked `~/Library/org.swift.swiftpm/swift-sdks/...` (macOS) and `~/.swiftpm/swift-sdks/...` (incorrect Linux guess). On Linux runners, SwiftPM installs SDKs under `$XDG_DATA_HOME/swiftpm/swift-sdks` (`~/.local/share/swiftpm/swift-sdks/` by default), so both fallbacks missed and the step exited 127. The `find` lookup is host-agnostic and prints a diagnostic listing if the script genuinely isn't there.

## [0.5.0] - 2026-05-12

### Added

- **`Fs` plugin transparently handles SAF `content://` URIs on Android.** SAF dialogs (`dialog.openFile` / `saveFile` / `openDirectory`) have always returned `content://authority/...` URI strings in the same `[String]` slot the desktop backends fill with filesystem paths — scoped storage means apps don't get raw paths to user-selected files. Apps that passed a SAF URI to `fs.readBinary` got a confusing "no such file" because `FileManager` interprets `content://` as a literal path. The v0.5.x take: add a new `FsContentResolver` protocol to `SwiftPWACore` and a process-wide hook on `SystemFs.setContentResolver(_:)`. `SystemFs.readBinary` / `writeBinary` / `metadata` / `exists` check for the `content://` prefix and delegate to the registered resolver; `mkdir` / `remove` / `readDir` / `copy` / `rename` reject URI arguments with a clear "SAF doesn't expose this operation" error rather than silently misbehaving — SAF has no POSIX-shaped directory semantics for arbitrary content providers (tree-walk apps should drive `DocumentsContract` directly, out of scope for the cross-platform `Fs` surface). New `SwiftPWAAndroid.AndroidContentResolver` is the resolver: it RPCs into three new Kotlin entry points (`fs.readContentUri`, `fs.writeContentUri`, `fs.contentUriMetadata`) that use `activity.contentResolver.openInputStream` / `openOutputStream("rwt")` / `query(projection)` against `OpenableColumns.SIZE` + `DocumentsContract.Document.COLUMN_LAST_MODIFIED`. `AndroidAppContext.init` registers the resolver automatically, so `FsPlugin(SystemFs())` "just works" with SAF dialog results on Android — apps don't need to branch on prefix or special-case the URI shape in JS. Replaces the v0.5 "SAF dialog results are content:// URIs, not filesystem paths" caveat as a friction point (the underlying contract that SAF returns URIs is still true and documented). Tested cross-platform via a RecordingResolver fixture (`SystemFsContentURITests`); the Kotlin side is exercised by CI's `assembleDebug` run.
- **Multi-window on Android via Activity-per-window.** The first `context.createWindow(...)` call binds to the foreground Activity the JNI runtime entry-point already owns (existing behavior). Subsequent calls JNI-launch a fresh `MainActivity` instance carrying the configured content URL in a `swift-pwa.config-json` intent extra; the spawned Activity loads that URL into its own WebView and pushes onto the current task's back stack, so the system back gesture returns to the originating Activity (the Android-native "open detail / settings view" UX, not desktop side-by-side multi-window — that's a user-driven split-screen action on Android, not an API). The generated `MainActivity.onCreate` reads the extra and skips the Swift runtime thread spawn for secondaries (only the primary owns the runtime); a new `onResume` override re-attaches the bridge so the primary reclaims the C shim's single-slot bridge ref when the user backs out of a secondary. New JNI entry `swiftpwa_android_spawn_window(config_json)` brokers the `startActivity`. The `AndroidWindow` returned for a secondary has `role == .secondary`: `setTitle` / `setFullscreen` / `close()` stay local-only on it because the single-slot bridge ref always points at whichever Activity is foreground, so cross-Activity Swift→OS calls would silently target the wrong one; apps that need to mutate a secondary should do it from JS inside that Activity. Replaces the v0.5 "calling createWindow more than once replaces content" stub. Documented in [docs/android-setup.md](docs/android-setup.md) §6 and the README's Android footnote.
- **`swift-pwa updater` CLI / `UpdaterTarget.current` now first-class on Android.** The publishing CLI (`updater keygen` / `sign` / `manifest`) was already platform-agnostic — it only deals with Ed25519 + JSON — and worked fine for an Android pipeline as long as the publisher and runtime agreed on the manifest target key. The runtime side was the gap: `UpdaterTarget.current(packageFormat:)`'s `#if` ladder had no `os(Android)` branch, so an Android `AndroidUpdater` computed `"unknown-aarch64-apk"` and would never match a publisher's `"android-aarch64-apk"` manifest entry. Added the Android `os` branch (positioned after the existing `os(Linux)` since the Swift compiler treats `os(Linux)` and `os(Android)` as mutually exclusive predicates) and factored the post-detection formatting into a new `UpdaterTarget.make(os:arch:packageFormat:)` helper so a host-side test suite can pin every supported `<os>-<arch>-<pkg>` combination (`darwin-aarch64`, `darwin-x86_64`, `ios-aarch64-enterprise`, `linux-x86_64-appimage`, `linux-aarch64-appimage`, `windows-x86_64-msix`, `windows-x86_64-portable`, `android-aarch64-apk`, `android-x86_64-apk`) and catch a rename before it ships — drift between the publisher's target name and the runtime's is silent ("no update available" forever) since the manifest lookup just returns nil. Documented in [docs/auto-updates.md](docs/auto-updates.md) `{{target}}` listing + manifest worked-example.
- **`AndroidWindow.setFullscreen` wired to `WindowInsetsControllerCompat`.** Was a documented stub in v0.5 (cached locally, never reached the OS); now toggles immersive / edge-to-edge layout for real. The Kotlin scaffold gained a `SwiftPWABridge.setFullscreen(Boolean)` entry point that uses `WindowCompat.setDecorFitsSystemWindows` + `WindowInsetsControllerCompat.hide(WindowInsetsCompat.Type.systemBars())` (with `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE` so the user can still reach the status / nav bars by swiping from the edge); the C shim got a `swiftpwa_android_set_fullscreen(int)` outbound entry plus a matching cached method ID. AndroidX's `WindowInsetsControllerCompat` is the forward-compatible replacement for the deprecated `View.setSystemUiVisibility` flag set — works on every supported API (28+) without per-version branching and respects the API 30+ semantics where the system owns the bar-visibility decision. `isFullscreen()` continues to mirror the most-recent caller intent (so JS round-trips of `window.isFullscreen` are honest even before the JNI hop lands).
- **`updater.install` streams the platform's post-commit install lifecycle.** New optional `Updater.install()` protocol method, with a default impl that delegates to `installAndRelaunch` and finishes — desktop backends inherit it transparently since the running process is replaced before any post-commit event could be observed anyway. On Android, `AndroidUpdater` overrides it: the Kotlin `PackageInstaller.Session` `BroadcastReceiver` (previously a logcat-only sink) now pushes each `STATUS_*` intent through a new generic Swift→Kotlin host-event channel (`swiftpwa_android_dispatch_host_event` + `SwiftPWABridge.nativeHostEvent`) which the new `AndroidHostEventRouter` dispatches by channel name. The router is single-slot per channel name, matching the rest of the Android backend's single-Activity assumptions; future asynchronous Activity hooks (lifecycle, intent extras, deep links) can reuse the same plumbing without growing the JNI surface. JS gets three new `UpdaterEvent` cases — `installCommitted` (after `Session.commit`), `installSucceeded` (`STATUS_SUCCESS`, fires briefly before the system replaces the running app), and `installFailed(code, message)` (any `STATUS_FAILURE_*`, with `code` carrying the platform constant name like `"STATUS_FAILURE_ABORTED"` for user rejection and `message` carrying `EXTRA_STATUS_MESSAGE` when present) — and a new streaming `updater.install` subscription that yields them. The cross-platform `updater.installAndRelaunch` invoke stays as it was; existing call sites keep working. Documented in [docs/android-setup.md](docs/android-setup.md) §6.1.2 and [docs/javascript-api.md](docs/javascript-api.md). Replaces the v0.5 "Updater install result isn't observable" known limitation.

- **Android release signing wired into the bundler.** New `pwa.json` `android.signing` section (`keystore`, `key_alias`, optional `store_type` / `v1_signing_enabled` / `v2_signing_enabled`) drives a generated `signingConfigs.release { ... }` block in the emitted `app/build.gradle.kts`, and the release build type now applies `signingConfig = signingConfigs.getByName("release")` automatically when configured. Passwords are deliberately *not* in `pwa.json` — `pwa.json` is checked in, so secrets there would leak. The generated Gradle script reads `SWIFT_PWA_ANDROID_STORE_PASSWORD` and `SWIFT_PWA_ANDROID_KEY_PASSWORD` from the environment and fails Gradle's configure step with a clear `error("…not set; release signing requires it")` message if either is missing — silent fallback to a debug-key or unsigned APK is exactly the kind of pit-of-failure that breaks a Play Store upload mid-pipeline. CLI overrides cover the CI matrix case where the keystore varies per run: `--sign <keystore-path>` (existing flag, now meaningful for `--target android` — interpretation joins the macOS / iOS / Windows family) overrides `android.signing.keystore`, and a new `--android-key-alias <alias>` overrides `android.signing.key_alias`. Either flag without a `pwa.json` signing section works as long as both keystore + alias resolve from somewhere; the bundler errors out (`AndroidBundlerError.signingMissingAlias`) on a partial config rather than dropping the option silently. Keystore paths in `pwa.json` resolve relative to the project root and the absolute path is baked into the generated Gradle script so `./gradlew assembleRelease` works regardless of where it's invoked from. Backslashes and double-quotes in either path or alias are escaped at template-emit time so a Windows path like `C:\Users\me\release.jks` round-trips cleanly. Documented in [docs/android-setup.md](docs/android-setup.md) §7 (keystore generation, `pwa.json` vs CLI surface, `assembleRelease` invocation, GitHub Actions base64-encoded-keystore CI pattern).
- **`swift-pwa init` now lays down the Android boilerplate.** Three changes to the scaffold so a new project's `swift-pwa build --target android` works without hand-editing: (1) generated `Package.swift` includes the Android-only `linkerSettings: [.unsafeFlags(["-Xlinker", "-no-pie", "-Xlinker", "-shared"], .when(platforms: [.android]))]` block — the SwiftPM convention for "build this executable target as a shared library" — so the Swift binary is a real `.so` the Activity's `System.loadLibrary` can load. (2) New `Sources/<name>/AndroidEntry.swift` template with a JNI entry point pre-populated with the right `@_cdecl("Java_<package_with_underscores>_MainActivity_swiftPwaMain")` mangled symbol for the chosen `--bundle-id`, plus the comment block explaining why we construct `AndroidAppRuntime()` directly rather than routing through `SwiftPWA.runtime()` (the protocol witness is `@MainActor`, the concrete type's `run` is `nonisolated`, and Android's MainActor backed by libdispatch can't satisfy `assumeIsolated` on a fresh worker thread). The generated `App.swift` is restructured to factor a top-level `configure(_ ctx: any AppContext)` function that both desktop `@main` and the Android JNI entry call into, so the user has a single place to register plugins / windows. (3) `pwa.json` gains a default `android` section (`package_id` mirroring `--bundle-id`, `min_sdk: 28`, `target_sdk: 34`, `abis: ["arm64-v8a", "x86_64"]`, `version_code: 1`). The `.gitignore` template gains `*.jks`, `*.keystore`, `*.p12`, `keystore.properties` so signing material stays out of git by default. Apps that change `pwa.json`'s `android.package_id` after `init` must update the `@_cdecl` string in lockstep — the Activity surfaces `UnsatisfiedLinkError: Native method not found` at startup if the two drift, and that's documented in [docs/android-setup.md](docs/android-setup.md) §3.

- **`docs/android-on-device-testing.md`** — reproducible playbook for verifying the Android backend on a USB-connected device. Covers prerequisites (Swiftly + Swift 6.2.0, swift-android-sdk 6.2, NDK r27d, JDK 17, `adb`, Python `websockets`); the build → install → launch loop; setting up Chrome DevTools Protocol via `adb forward tcp:9222 localabstract:webview_devtools_remote_<pid>`; a tiny Python helper that does a one-shot `Runtime.evaluate` over WebSocket so each `__SWIFT_PWA__.invoke(...)` round-trip can be driven from a host shell; the fire-and-forget pattern (stash the Promise on `window`, drive the native UI separately, read the slot back) for interactive plugins (dialog confirm, SAF file pickers, BiometricPrompt); native UI tap via `adb shell input tap <x> <y>` against a `screencap`-located target; out-of-process side-effect probes (`adb shell dumpsys notification --noredact` for the notification record, `dumpsys activity activities` for lifecycle); and the gotchas that bit me during v0.5.x bring-up (the abstract-socket name uses the PID so re-forward after every launch; `KEYCODE_BACK` exits the app if no modal is open; biometric prompts blank `screencap`; `Theme.AppCompat` is required when MainActivity extends AppCompatActivity; `POST_NOTIFICATIONS` is API 33+ runtime; SAF returns `content://` URIs not paths; `/usr/bin/strip` on macOS is Mach-O only and chokes on ELF). Linked from `docs/android-setup.md` §Status and the README's roadmap + Platform setup sections.
- **Android System\* plugin set verified end-to-end on-device.** Galaxy Tab S10+ (Android 16, arm64) running the cross-compiled `Examples/HelloPWA` APK: every new plugin's RPC round-trip exercised through the Chrome DevTools Protocol against a debug-mode WebView. `clipboard.writeText("hello from android")` → `clipboard.readText()` returns `{"text":"hello from android"}`. `dialog.confirm` with custom `okLabel: "Yes"` / `cancelLabel: "No"` rendered the native `AlertDialog` with those labels and round-tripped `{"ok":true}` / `{"ok":false}` based on which button was tapped. `dialog.openFile` with `extensions: ["png","jpg"]` opened the SAF Documents UI filtered to image MIME types and returned a real `content://com.android.providers.media.documents/document/image%3A...` URI on selection. `notifications.send` posted into the system shade as "swift-pwa / hello from the bridge" under the `swift-pwa.default` channel with `flags=SILENT` (because `sound: false`); `dumpsys notification --noredact` confirms the record id matches what the plugin returned. `biometric.canAuthenticate` reported `{"available":true,"kind":"unknown"}` (kind is `.unknown` by design — Android's `BiometricManager` doesn't distinguish fingerprint / face / iris at the API level). `biometric.authenticate` rendered the system prompt (Android's secure-overlay protection blanks the screencap during the prompt — that's the right behaviour) and round-tripped `{"authenticated":true}` after face unlock. Two scaffold-template fixes surfaced during bring-up:
  - **Theme.AppCompat required.** `MainActivity` now extends `AppCompatActivity` (needed by `BiometricPrompt` and SAF `ActivityResultLauncher`s); AppCompat refuses to inflate against a non-AppCompat theme and crashes the launch with `IllegalStateException: You need to use a Theme.AppCompat theme (or descendant) with this activity.` Manifest template now sets `android:theme="@style/Theme.AppCompat.Light.NoActionBar"` on `<application>`. `NoActionBar` because the WebView fills the screen and the system action bar would just steal vertical space.
  - **`ClipboardPlugin` wasn't auto-registered.** Every other backend's `AppContext.init` does `use(ClipboardPlugin(SystemClipboard()))` so apps don't have to opt in to the most-common plugin; `AndroidAppContext` was missing that line. The demo's capability gating greyed the clipboard buttons out because `clipboard.*` didn't appear in `__platform.info.commands`. Matched the desktop pattern.
- **`Examples/HelloPWA` lost its `#if !os(Android)` gates around `NotificationsPlugin` / `DialogPlugin` / `BiometricAuthPlugin`** — they're first-class on Android now, registered unconditionally. The remaining gate is around `TrayPlugin(SystemTray())`, which stays Android-skipped since Android has no system-tray analogue (foreground-service notifications would be a heavy and Android-specific UX, not a drop-in for the desktop tray API). The demo's capability gating already greys the tray buttons out automatically.
- **Android System\* plugin set: Clipboard, Notifications, Dialog, BiometricAuth, plus an `AndroidUpdater`.** Brings the Android backend up to desktop parity on the plugin set — apps no longer need `#if !os(Android)` gates around their `ClipboardPlugin(SystemClipboard())` / `NotificationsPlugin(SystemNotifications())` / `DialogPlugin(SystemDialog())` / `BiometricAuthPlugin(SystemBiometricAuth())` / `UpdaterPlugin(AndroidUpdater(...))` registrations. All five plugins are driven through a generic Swift→Kotlin RPC channel rather than per-method JNI bindings: a single new `swiftpwa_android_rpc(method, args_json, done, user)` C function on the shim posts to `SwiftPWABridge.rpcCall`, which dispatches to a new `SwiftPWASystemPlugins.kt` `when (method)` block — same shape as the existing inbound JS-frame channel. Adding a new plugin method is a one-case addition to the Kotlin dispatch + a Swift wrapper, not a new C symbol pair. The Kotlin scaffold's `MainActivity` now extends `androidx.appcompat.app.AppCompatActivity` (a `FragmentActivity` subclass) so `BiometricPrompt` can attach and SAF `ActivityResultLauncher`s register cleanly; users subclassing the generated activity must preserve that base or the prompt will fail with `IllegalStateException: FragmentActivity required`. Per-plugin specifics:
  - **`SystemClipboard`** — `ClipboardManager.setPrimaryClip` / `primaryClip.coerceToText`. `clear()` falls back to `setPrimaryClip(empty)` on API 26 / 27 (the explicit `clearPrimaryClip` only landed in P / API 28).
  - **`SystemNotifications`** — `NotificationManagerCompat` against a single `swift-pwa.default` channel (created lazily on first `send` for API 26+). `requestAuthorization` triggers the API 33+ `POST_NOTIFICATIONS` runtime permission prompt the first time and reports `areNotificationsEnabled()` thereafter; older API levels short-circuit to the latter check (no prompt, no gate).
  - **`SystemDialog`** — `AlertDialog.Builder` for message / confirm; SAF (`Intent.ACTION_OPEN_DOCUMENT` / `CREATE_DOCUMENT` / `OPEN_DOCUMENT_TREE`) for openFile / saveFile / openDirectory. **SAF returns `content://` URIs, not filesystem paths** — that's the platform contract, scoped storage means apps don't get raw paths to user-selected files. The picked URIs come back as strings in the same `[String]` slot as the desktop file paths; documented in `docs/android-setup.md` §6.1 so apps don't try to `fs.readText` the result and get a "no such file" surprise. `DialogFileFilter.extensions` map to MIME types via a small built-in table (png → `image/png`, pdf → `application/pdf`, etc.); unknown extensions fall back to `*/*` so the picker still opens.
  - **`SystemBiometricAuth`** — `androidx.biometric:biometric:1.1.0`'s `BiometricPrompt` with `BIOMETRIC_STRONG | BIOMETRIC_WEAK` authenticator strength. `BiometricKind` is always `.unknown` when available and `.none` when not — Android's `BiometricManager` doesn't distinguish fingerprint / face / iris at the API level, both `BIOMETRIC_STRONG` and `BIOMETRIC_WEAK` are abstract authenticator strengths. Cancel surfaces as `authenticated: false` with `error: "cancelled"` per the protocol contract (mapped from `ERROR_USER_CANCELED` / `ERROR_NEGATIVE_BUTTON` / `ERROR_CANCELED`).
  - **`AndroidUpdater`** — APK install via `PackageInstaller.Session.MODE_FULL_INSTALL`. Streams the staged APK bytes into the session on a background thread (so a 30 MB APK doesn't stall the UI thread for the duration of the copy), commits with a `PendingIntent` to a per-process `BroadcastReceiver` that handles `STATUS_PENDING_USER_ACTION` by launching the system installer's confirmation Activity. Self-installing requires the `REQUEST_INSTALL_PACKAGES` manifest permission **plus** the per-app "Install unknown apps" toggle (a one-time user action on API 26+; the system installer surfaces a dialog routing the user there if it's off, we don't pre-empt that flow). Ed25519 verification over the artifact bytes is mandatory regardless of `PackageInstaller`'s same-key check — `PackageInstaller` only validates that the new APK's signing certificate matches the installed app's certificate, which is a same-key check, not a same-publisher check; a compromised CDN could swap in a different APK signed with the same dev key.
- **`SwiftPWASystemPlugins.kt` template + manifest permissions in the Gradle scaffold.** The bundler now emits a second Kotlin file alongside `SwiftPWABridge.kt` (the new dispatch table) and the `AndroidManifest.xml` declares `POST_NOTIFICATIONS`, `USE_BIOMETRIC`, `USE_FINGERPRINT`, and `REQUEST_INSTALL_PACKAGES` so all five plugins work out of the box. Apps that don't ship a particular plugin can drop the corresponding line in a manual post-bundler edit. New gradle deps: `androidx.biometric:biometric:1.1.0` (BiometricPrompt) and an explicit `androidx.activity:activity-ktx:1.9.0` pin (also pulled in transitively by appcompat 1.7+; the explicit dep here protects against a future appcompat change accidentally removing it). `JSONObject` / `JSONArray` for argument parsing rather than a Kotlin JSON library — already present in the Android runtime, no extra dep, and the surface we need (string / bool / nested array) is exactly what `org.json` exposes ergonomically.
- **APK size on `Examples/HelloPWA`: 131 MB → 76 MB (42% smaller) with two new bundler size passes.** Both land in this delta on top of the earlier v0.5.x kickoff:
  - **Always-on `llvm-strip --strip-unneeded` over every staged `.so`.** Gradle's AGP would ordinarily run `stripDebugDebugSymbols` for us, but it resolves the strip tool from the SDK manager's NDK install (`$ANDROID_HOME/ndk/<version>/`) and gives up with `Unable to strip the following libraries, packaging them as they are: …` when only a standalone NDK at `$ANDROID_NDK_HOME` is present (the typical Swift-on-Android dev setup). Doing the strip ourselves bypasses that resolution dance — the bundler walks `$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/<host>/bin/llvm-strip` and runs it inline before gradle ever sees the libs. On `Examples/HelloPWA`'s arm64-v8a build: 124 MB → 73 MB jniLibs (51 MB saved, 41%), final APK 131 MB → 80 MB. Big winners are `libHelloPWA.so` itself (20 MB → 4 MB) and the `libFoundation*.so` set (each 4-13 MB stripped off). The unstripped binary stays in `.build/<triple>/release/<Name>` for `swift symbolicate` to consume during crash triage. **Removed the gradle template's `keepDebugSymbols += setOf("**/lib<name>.so")` line** — it was an overly cautious stance that made the APK 4× the size of its app `.so` for a "swift symbolicate works against the APK" use case nobody actually had. Apps that need symbols *in* the APK can override in a sibling `app/build.gradle.kts.local` post-bundler.
  - **`swift-pwa build --target android --prune-android-runtime` flag.** Walks the app `.so`'s `DT_NEEDED` chain transitively via `llvm-readelf -d` and copies only the runtime libs the binary actually loads into `jniLibs/<abi>/`. On `Examples/HelloPWA` this drops 10 of the 26 wholesale stdlib `.so` files: `libFoundationXML`, `libTesting`, `libXCTest`, `lib_Testing_Foundation`, `libswiftDistributed`, `libswiftObservation`, `libswiftRegexBuilder`, `libswiftSwiftOnoneSupport`, `libswift_Differentiation`, `libswift_Volatile`. After the always-on strip pass already runs, the additional APK saving is ~5 MB (80 MB → 76 MB) — much smaller than the ~100 MB ballpark I'd written into the v0.5.x kickoff entry, since the dropped modules are individually small and the dominating size is the Foundation+ICU stack the binary actually pulls in. Specifically: `lib_FoundationICU.so` is 37 MB stripped (ICU's i18n data tables, load-bearing for any `URL` / `String` / `Locale` use), `libFoundationEssentials.so` is 6 MB stripped, `libFoundation.so` is 6 MB, `libswiftCore.so` is 7 MB. None of those go away under prune because the binary genuinely DT_NEEDEDs them. System libs the platform loader resolves itself (`libc.so`, `libdl.so`, `libm.so`, `liblog.so`, `libandroid.so`, …) are filtered out — Bionic refuses to load a duplicate of `libc.so` from `jniLibs/`, so shipping one would break the launch. When `readelf` is missing or any walk step fails the bundler falls back to the wholesale set with a printed note. Off by default since the marginal saving on top of stripping is small; opt in for distribution builds.
  - **NDK-toolchain awareness in the bundler's lookup of `readelf` / `strip`.** Earlier iterations called `/usr/bin/env readelf`, which doesn't exist on macOS hosts (binutils isn't shipped), and `/usr/bin/strip`, which on macOS is Mach-O-only and chokes on ELF input with a non-zero exit. The new `ndkBinutilsTool(name:llvmName:)` helper prefers `$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/<host>/bin/llvm-<tool>` first (handles ELF on every host, including darwin-x86_64 / darwin-arm64 / linux-x86_64 / windows-x86_64), then `llvm-<tool>` on PATH, then bare `<tool>` (binutils on Linux, fine for ELF). When the strip pass first ran on macOS it reported "saved 0 MB" because every shell-out to `/usr/bin/strip` came back non-zero on ELF input — the lookup-order fix unblocked the win.
- **CI: Android cross-compile + `assembleDebug` job.** New `android` step in `.github/workflows/ci.yml` runs the full v0.5 pipeline against `Examples/HelloPWA` on every push: install Swiftly + pinned Swift 6.2.0, install NDK r27d, install the Swift Android SDK 6.2 from its release URL (with a runtime-computed sha256 so the workflow keeps working when upstream rebuilds the artifact under the same version label), run the SDK's `setup-android-sdk.sh`, set up JDK 17, run the host CLI, run `swift-pwa build --target android --cross-compile-android --android-abis arm64-v8a` from the example directory, then run the vendored Gradle wrapper's `assembleDebug` and verify the resulting `app-debug.apk` exists. The APK is uploaded as a workflow artifact so reviewers can pull it for sideload testing without re-running the whole build locally. Catches toolchain drift (a Swift 6.2 patch release breaking the SDK), Gradle / AGP plugin drift, and bundler-template syntax errors before they reach a developer's machine. The job runs after `macos` (the canonical correctness suite) so a host-test failure short-circuits the more expensive cross-compile.
- **`Examples/HelloPWA/pwa.json` gained an `android` block.** `package_id: com.swiftpwa.hello`, `min_sdk: 28`, `target_sdk: 34`, `abis: ["arm64-v8a"]`, `version_code: 1` — wired up so the CI job has something concrete to bundle without having to inject the section dynamically. Matches the values the on-device verification used in v0.5.
- **v0.5 kickoff: Android backend (preview).** New `SwiftPWAAndroid` Swift target wraps `android.webkit.WebView` (Chromium-backed since Android 7.0) through a JNI C shim (`Sources/CSwiftPWAAndroidJNI`) plus a Kotlin Activity scaffold the CLI emits. The flow mirrors Windows' shape (one C shim brokering the webview, a `MainThread.run` hook for the platform UI thread, host-conditional `swift-crypto` for a future updater backend) but adapts to Android's "the JVM owns the UI thread" model: the Swift binary compiles to a `.so` that the generated Kotlin `MainActivity` loads via `System.loadLibrary`, then JNI-calls a user-provided `@_cdecl` entry point on a worker thread; `AndroidAppRuntime.run(_:)` registers handlers, runs `configure` synchronously, and blocks on a `DispatchSemaphore` that `quit(exitCode:)` releases (we can't drive a UI loop from Swift on Android — `Handler(Looper.getMainLooper()).post(...)` is what `MainThread.run` hops through). The JS↔Swift channel is `addJavascriptInterface` inbound + `WebView.evaluateJavascript("__SWIFT_PWA__.__deliver(...)")` outbound; the asset host `https://swift-pwa.local/` is provided by AndroidX's `WebViewAssetLoader` (the closest analogue to WebView2's `SetVirtualHostNameToFolderMapping`). `bridge.js` gained a fourth native-channel branch (`window.__SwiftPWA__post.postMessage(...)`) so the same JS surface works on the new backend.
- **`swift-pwa build --target android` (preview, cross-compile verified).** New `AndroidBundler` emits a Gradle project (`<output>/<Name>-android/`) with AGP 8.5 + Kotlin 2.0 pinned, generated `MainActivity.kt` + `AndroidManifest.xml` + `app/build.gradle.kts` from the new `pwa.json` `android` section (`package_id`, `min_sdk` defaulting to 28 to match the Swift Android SDK 6.2 floor, `target_sdk` defaulting to 34, `abis` defaulting to `["arm64-v8a", "x86_64"]`, `version_code`). Web bundle is copied into `app/src/main/assets/web/` and `bridge.js` into `app/src/main/assets/swift_pwa/bridge.js` for the Kotlin host's `onPageStarted` injection. Two operating modes: **scaffold-only** (default — generates the project, leaves `jniLibs/` empty, prints a manual-staging hint; works on any host, no Swift Android SDK required) and **`--cross-compile-android`** (runs `swift build --swift-sdk <android-triple>` for each requested ABI, where the triple is the lookup key in the SDK's `swift-sdk.json` `targetTriples` map; the bundler then stages the Swift binary at `jniLibs/<abi>/lib<Name>.so`, renaming from SwiftPM's default executable-named output `.build/<triple>/release/<Name>` since the toolchain doesn't apply the `lib*.so` convention even with `-shared` flags). The cross-compile path preflights `swift sdk list` for an installed Swift Android SDK and emits a clean install-hint diagnostic when none is present, instead of letting `swift build` fall back to host clang headers and explode with a wall of "architecture not supported" errors out of swift-corelibs / swift-crypto's C sources. **Verified end-to-end against `Examples/HelloPWA`**: cross-compile against the swift-android-sdk 6.2 bundle + NDK r27d + Swift 6.2.0 produces a 19 MB `aarch64-unknown-linux-android28` shared object (`file` confirms `ELF 64-bit LSB shared object, ARM aarch64`). What's *not* yet verified: `./gradlew assembleDebug` and on-device run; queued for v0.5.1. `--android-abis arm64-v8a,x86_64` overrides `pwa.json`. The previous v0.1 stub on `--target android` (which printed "Planned for v0.3" and exited 2) is replaced.
- **API 28 floor on the cross-compile triple.** The Swift Android SDK 6.2 distribution's `swift-sdk.json` only declares target triples for API 28–36 (the older API 24 floor was dropped in that release). The bundler's `tripleFor(abi:)` clamps the manifest's `min_sdk` to 28 when constructing the cross-compile triple, with a printed warning, since SwiftPM otherwise silently resolves to a wrong-arch resource path (`swift-resources/usr/lib/swift-x86_64/...` on an `aarch64` build). Default `pwa.json` `android.min_sdk` bumped from 26 to 28 to match.
- **Triple-as-`--swift-sdk` argument form.** The CLI passes the API-suffixed Android triple (e.g. `aarch64-unknown-linux-android28`) directly to `swift build --swift-sdk`, *not* the bundle ID + a separate `--triple`. The `--swift-sdk <bundle-id> --triple <triple>` combo bypasses SwiftPM's `targetTriples` map and falls back to the bundle's first arch-suffixed resource directory, which can't satisfy `import Foundation` for a different-arch build. The triple form is what swift-android-sdk's own README example uses.
- **Example app `Package.swift` Android linker flags.** `Examples/HelloPWA` gained `-Xlinker -no-pie -Xlinker -shared` linker settings gated on `.when(platforms: [.android])`. `-shared` makes the executable target produce a `.so` that `System.loadLibrary` can load; `-no-pie` cancels the toolchain's default `-pie`, which `lld-link` otherwise rejects with `error: -shared and -pie may not be used together`. Documented in `docs/android-setup.md` §3.
- **On-device Android verification: APK installs, launches, and round-trips the JS↔Swift bridge end-to-end.** `Examples/HelloPWA` was deployed to a Samsung Galaxy Tab S10+ (Android 16, arm64) via `adb install`; the app loads, the WebView renders the demo UI from `assets/web/`, and JS-side `__SWIFT_PWA__.invoke(...)` calls round-trip through the runtime — verified via the "Server time" button (bridge round-trip) and "Rename window" (`window.setTitle` → updates the Activity's action-bar title). What this exposed and fixed during bring-up:
  - **Swift stdlib not on Android's loader path.** `libHelloPWA.so` was dynamically linked against `libswiftCore.so` / `libFoundation.so` / `libdispatch.so` / `libc++_shared.so` and crashed at `System.loadLibrary` with `UnsatisfiedLinkError`. The Swift Android SDK 6.2 bundle ships those `.so` files separately; the bundler now copies the entire stdlib (~27 `.so` files, plus the NDK's `libc++_shared.so`) into `app/src/main/jniLibs/<abi>/` alongside the user's binary. Compressed APK overhead is ~30 MB; pruning to the binary's actual `DT_NEEDED` set is queued for v0.5.x.
  - **`MainActor.assumeIsolated` traps on the JNI worker thread.** Tombstone showed `_dispatch_assert_queue_fail` → `_swift_task_checkIsolatedSwift` — Swift Android's MainActor is backed by libdispatch's main queue, which isn't drained by anyone (Android's UI thread is the JVM's Looper, separate from libdispatch). `dispatchMain()` plus `MainActor.assumeIsolated` doesn't produce a working hop either: dispatchMain doesn't drain the queue from the calling thread the way I'd assumed. Dropped MainActor isolation from `AndroidAppRuntime`/`AndroidAppContext`/`AndroidWindow` (`nonisolated` + `@unchecked Sendable`), use `unsafeBitCast` to call the still-`@MainActor`-declared protocol methods (`Plugin.register`, the user's `configure` closure) without an actor hop. Synchronisation comes from the single-threaded access pattern: configure runs once on the JNI worker thread, then that thread blocks on a semaphore until `quit(exitCode:)` releases it; binder-thread inbound paths only touch `nonisolated(unsafe)` storage that's already-stable by then.
  - **`SwiftPWA.runtime()` wasn't wired to Android.** The umbrella module's `#elseif os(Android)` branch didn't exist; calls fell through to the "no runtime for this platform" throw, with the diagnostic disappearing into `/dev/null` because Foundation's `FileHandle.standardError` isn't routed to logcat on Android. Added the Android branch + a `swiftPWALog`-shaped logging helper (wraps `__android_log_print` from the JNI shim) so future bring-up errors land in `adb logcat`.
  - **`bridge.js` was injected too late.** The Kotlin scaffold's `WebViewClient.onPageStarted` + `evaluateJavascript` racing against the page's own scripts surfaced as `Uncaught ReferenceError: __SWIFT_PWA__ is not defined` for any inline JS that ran on parse. Switched to `WebViewCompat.addDocumentStartJavaScript` (AndroidX webkit's "document-start" injection, equivalent to WKWebView's `addUserScript(.atDocumentStart)`); `onPageStarted` is kept as a fallback for OEM WebViews that don't advertise the `DOCUMENT_START_SCRIPT` feature.
  - **`bridge.js` itself was the 302-byte fallback stub, not the real 5.8 KB runtime.** The bundler's `locateBundledBridgeJS()` walked the user's project tree and only found the source when the CLI ran from a swift-pwa checkout sibling. Replaced with a call to `SwiftPWACore.BridgeScript.source()` — the same helper the runtime backends already use — which reads from `SwiftPWACore`'s own `Bundle.module` regardless of CWD. Removed the path-heuristic fallback entirely.
  - **`BridgeRuntime` was never constructed on Android.** Every other backend's `Window` subclass creates a `BridgeRuntime` and calls `.start()`; `AndroidWindow` did not, so JS → Swift inbound frames flowed into the adapter's continuation but nothing pumped them. Symptom: every JS-side `invoke` / `subscribe` hung silently. Wiring matches the Mac/iOS/Win32 pattern.
  - **`WebViewAssetLoader.AssetsPathHandler(this, "web")` was a typo.** The 2-arg form doesn't exist on the AndroidX API. Dropped to `(this)`, changed the Swift adapter's URL from `https://swift-pwa.local/<entry>` to `https://swift-pwa.local/web/<entry>` so the asset loader routes into the bundler's `assets/web/` subdirectory naturally.
- **`AndroidWindow.setTitle` now updates the Activity's action-bar title** via a new `setTitle(String)` method on `SwiftPWABridge.kt` and a matching `swiftpwa_android_set_title(const char *)` JNI shim function. Was a documented no-op in the v0.5 kickoff (cached locally, never reached the OS); now wired to `Activity.setTitle`. `setSize` / `setPosition` / `minimize` / `maximize` / `focus` stay as documented no-ops — Android's window manager owns those decisions; on a tablet you can't tell the OS to resize your own Activity.
- **Vendored Gradle 8.10.2 wrapper** in the Android scaffold (re-applied here for clarity since the verification touched it). The previous v0.5 kickoff emitted Kotlin / Gradle build scripts but no wrapper, so the docs' "next: `./gradlew assembleDebug`" had nothing to invoke. Four wrapper files (`gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.jar`, `gradle/wrapper/gradle-wrapper.properties`) — generated by `gradle wrapper --gradle-version 8.10.2 --distribution-type bin`, ~60 KB total — are checked in under [Sources/SwiftPWACLISupport/Bundlers/AndroidWrapperResources/](Sources/SwiftPWACLISupport/Bundlers/AndroidWrapperResources/) and emitted into the generated project as a SwiftPM `.copy("Bundlers/AndroidWrapperResources")` resource on `SwiftPWACLISupport`. The bundler `chmod +x`s `gradlew` after copying because cross-platform host filesystems don't reliably preserve POSIX permissions through SwiftPM's `.copy` rule.
- **`PlatformInfoPlugin` (cross-platform) — JS-discoverable plugin set.** New built-in plugin in `SwiftPWACore` that registers `__platform.info`, returning `{ os: string, commands: [string], tempDir: string }` so JS can detect which plugins are installed at runtime and (when the registered set is short of what the demo expects, e.g. `dialog.saveFile` missing on Android v0.5) fall back gracefully — `Examples/HelloPWA`'s "Save scratchpad" button now uses `tempDir + "/swift-pwa-scratch.txt"` when no save dialog is available, instead of silently no-op'ing on the missing `dialog.saveFile` invoke. `tempDir` resolves via `NSTemporaryDirectory()` (Foundation maps it to the right path per platform: `/var/folders/...` on macOS, `<bundle>/tmp` on iOS, `/tmp` on Linux, `%TEMP%` on Windows, `/data/data/<pkg>/cache` on Android). Registered eagerly by every backend's `AppContext.init` (alongside `WindowPlugin` and `ClipboardPlugin`). The `os` field is the lowercased platform identifier (`"macos"`, `"ios"`, `"linux"`, `"windows"`, `"android"`) and the `commands` field is `registry.names()` sorted, captured at invoke time (so the result reflects all subsequently-`use`d plugins). Used by `Examples/HelloPWA`'s new capability gating: each demo button declares `data-requires="<command>"` (and optionally `data-disable-on="android,ios"` for commands that *are* registered but are documented no-ops on a particular OS, e.g. `window.setSize` on Android). A startup IIFE reads `__platform.info` and disables / fades any button whose requirement isn't met. Result: on Android, the Clipboard / Tray / Dialog / Notifications / Biometrics buttons render disabled (with a tooltip explaining why) while Window / Bridge / Filesystem / Updater stay live; on macOS / Linux / Windows the buttons all stay enabled. Demo's webview-detection IIFE also gained an `android.webkit.WebView` branch so the subtitle reflects the Android backend correctly.
- **APK build verified end-to-end against `Examples/HelloPWA`.** The full pipeline — `swift-pwa build --target android --cross-compile-android --android-abis arm64-v8a` → `cd build/HelloPWA-android` → `./gradlew assembleDebug` — produces a working 26 MB `app-debug.apk` with the right contents: `lib/arm64-v8a/libHelloPWA.so` (20.2 MB Swift binary), `assets/web/index.html` (the demo's web UI), `assets/swift_pwa/bridge.js` (the full 5,841-byte runtime), and a generated `AndroidManifest.xml` claiming `com.swiftpwa.hello` with the `INTERNET` permission. `aapt dump badging` confirms `compileSdkVersion=34`, `targetSdkVersion=34`, `sdkVersion=28`. Toolchain state for the verification run: Swift 6.2.0 + swift-android-sdk 6.2 + NDK r27d + JDK 17 + Android cmdline-tools + platform-34 + build-tools 34.0.0. The remaining v0.5.1 mile is `adb install` + on-device JS↔Swift bridge round-trip.
- **Two scaffold-level bugs surfaced + fixed by the APK build.** Both were in code I'd written for the v0.5 kickoff but never exercised end-to-end:
  - `WebViewAssetLoader.AssetsPathHandler(this, "web")` in `MainActivity.kt` — the 2-arg form doesn't exist on the AndroidX API; only `(Context)` is public. Kotlin compile failure: `None of the following candidates is applicable`. Fixed by dropping the bogus 2nd arg and changing the Swift adapter's bundled-content URL from `https://swift-pwa.local/<entry>` to `https://swift-pwa.local/web/<entry>` so the path naturally resolves into `assets/web/`. The asset loader serves the URL path *after* the registered prefix; there's no built-in way to bind a constructor argument to a sub-directory.
  - `bridge.js` was emitting a 302-byte fallback stub instead of the real ~5.8 KB runtime, because `locateBundledBridgeJS()` walked the user's project tree (`projectRoot/Sources/SwiftPWACore/Resources/bridge.js`, etc.) which only resolves when the CLI runs from a swift-pwa checkout sibling. Replaced with a call to `SwiftPWACore.BridgeScript.source()` — the same helper the runtime backends already use, reading from `SwiftPWACore`'s own `Bundle.module`. The CLI already depended on `SwiftPWACore`, so adding `import SwiftPWACore` to `AndroidBundler` was the only wiring change. Removes the path-heuristic fallback entirely.
- **Vendored Gradle 8.10.2 wrapper in the Android scaffold.** The previous v0.5 kickoff emitted Kotlin / Gradle build scripts but no wrapper, so the docs' "next: `./gradlew assembleDebug`" had nothing to invoke and users hit "where is gradle?". Four wrapper files (`gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.jar`, `gradle/wrapper/gradle-wrapper.properties`) — generated by `gradle wrapper --gradle-version 8.10.2 --distribution-type bin`, ~60 KB total — are checked in under [Sources/SwiftPWACLISupport/Bundlers/AndroidWrapperResources/](Sources/SwiftPWACLISupport/Bundlers/AndroidWrapperResources/) and emitted into the generated project as a SwiftPM `.copy("Bundlers/AndroidWrapperResources")` resource on `SwiftPWACLISupport`. Gradle 8.10.2 is pinned via the wrapper's `distributionUrl` (matches the AGP 8.5 + Kotlin 2.0 the scaffold's `build.gradle.kts` declares; AGP 8.5 requires Gradle 8.7+, so 8.10.2 is well within the supported window). The bundler's `stageGradleWrapper` step `chmod +x`s `gradlew` after copying because cross-platform host filesystems don't reliably preserve POSIX permissions through SwiftPM's `.copy` rule. End-to-end verified: `swift-pwa build --target android` → `cd <out>` → `./gradlew --version` → reports Gradle 8.10.2 / Kotlin 1.9.24 running on the user's JDK 17, with no system Gradle install required.
- **Example app gated System*-plugin registrations on `#if !os(Android)`.** `Examples/HelloPWA`'s `configure` closure used to always register `TrayPlugin(SystemTray())`, `NotificationsPlugin(SystemNotifications())`, `DialogPlugin(SystemDialog())`, and `BiometricAuthPlugin(SystemBiometricAuth())` — all four `System*` types live in the per-platform backend modules and don't yet exist on Android (queued for v0.5.x). The Android cross-compile failed with four `cannot find 'System*' in scope` errors until those registrations were gated. `FsPlugin(SystemFs())` and `UpdaterPlugin(DemoUpdater())` stay un-gated since `SystemFs` lives in `SwiftPWACore` and the demo updater is host-side.
- **`docs/android-setup.md`.** Toolchain (Swift 6.1+ with Android target, swift-android-sdk, NDK r26+, JDK 17, AGP 8.5), project layout, the `@_cdecl("Java_<package>_MainActivity_swiftPwaMain")` boilerplate the user provides until codegen lands in v0.5.x, scaffold-only vs cross-compile flow, and a "Known limitations" section enumerating what's deferred (multi-window, biometric / notifications / clipboard / dialog / tray / updater backends, code-signing wiring, `swift-pwa init` Android boilerplate). README's status line, comparison table, feature matrix, and roadmap section all gained Android coverage; the matrix uses a new `Preview` cell to distinguish "code-complete and host-buildable" from `Yes` (verified) and `v0.5.x` (not yet started).

### Changed

- **`swift-pwa init` accepts an existing target directory.** Previously the command bailed with `Directory already exists` if `<cwd>/<name>` (or whatever `--path` resolved to) was anything other than missing — `swift-pwa init MyApp --path .` couldn't be used to scaffold into the cwd, even an empty one. The check is now per-file: init refuses to overwrite any of the files it would write (`pwa.json`, `Package.swift`, `Sources/<name>/App.swift`, `Sources/<name>/AndroidEntry.swift`, `web/index.html`, `.gitignore`) but is happy to scaffold alongside unrelated pre-existing files (a `README.md`, a `.git/` dir, etc.). On conflict the error names the offending file(s) so the user knows what's in the way rather than just "directory already exists." The `Next:` hint at the end now skips the `cd <name>` prefix when scaffolding into the cwd.

### Status / known limitations

- **Android backend is preview, not verified end-to-end.** The Swift target compiles cleanly on macOS / Linux / Windows hosts (where the `#if os(Android)`-guarded sources collapse to empty objects), the C shim's JNI symbol names are pinned to the Kotlin scaffold's `external fun` declarations, and the Gradle project layout has been desk-checked, but the round-trip (`./gradlew assembleDebug`, install on a device or emulator, exercise the JS↔Swift bridge via `Examples/HelloPWA`) is queued for v0.5.1 once the swift-android-sdk distribution shape stabilizes in the Swift Android Workgroup's roadmap. Treat as a preview that lets downstream code start writing against the umbrella `SwiftPWA` module on Android; expect to file follow-ups against the v0.5.x milestone for toolchain edge cases.
- **Most `Window` shape APIs are no-ops on Android** — `setSize`, `setPosition`, `minimize`, `maximize`, `focus`. The platform's window manager owns those decisions; `setFullscreen` is a stub awaiting a `WindowInsetsControllerCompat` wire-up. Multi-window maps to `Activity.startActivity`, queued for v0.5.x; calling `context.createWindow` more than once replaces the active Activity's content rather than spawning a second Activity.
- **No Android `Clipboard` / `Dialog` / `Notifications` / `Tray` / `BiometricAuth` / `Updater` backends yet.** The `Plugin` protocol is intact and the umbrella links cleanly; apps that pre-register `DialogPlugin(SystemDialog())` etc. should gate the registration on `#if !os(Android)` until the Android `System*` implementations land.
- **Android signing isn't wired into the bundler.** Production builds require editing `app/build.gradle.kts` to add a `signingConfigs.release` block manually until v0.5.x emits one.

### Fixed

- **`SwiftPWAWindowsTestRunner` no longer crashes on startup with `STATUS_ORDINAL_NOT_FOUND` (exit `-1073741512`).** The `swiftpwa_dialog` C++ shim called `TaskDialogIndirect` directly, placing a static ordinal-345 import against `comctl32.dll` in every binary that links `CWebView2Shim`. The System32 copy of comctl32 is v5 and does not export ordinal 345 — v6 only activates when the EXE carries a `Microsoft.Windows.Common-Controls` manifest dependency. The CLI bundler (`WindowsBundler.embedComCtl6Manifest`) embeds that manifest for shipped bundles, but the test runner is never bundled, so the Windows loader rejected it at startup before any Swift code ran. Fix: `TaskDialogIndirect` is now loaded dynamically via `GetProcAddress` on a `comctl32.dll` handle obtained with `GetModuleHandleW` / `LoadLibraryW` — no static ordinal import, no loader crash. When v6 is active (bundled EXE) `GetProcAddress` succeeds and the themed TaskDialog UI works exactly as before; when v6 is absent `GetProcAddress` returns `nullptr` and the existing `MessageBoxW` fallback path handles the call, matching the original design intent.

- **Windows CI `Test` step now green via a dedicated test executable.** The v0.4-cycle Windows job had been red since the timeout fixes landed. The link itself was clean (`Build complete!`), but the test bundle then exited non-zero before producing any output — `error: abnormal(312)` on the `--filter` path (during SwiftPM's `--dump-tests-json` discovery launch) and exit 1 ~280 ms after `Build complete!` on the no-filter path. The first round-trip diagnosis (empty xctest pass exits non-zero on Windows; fix with `--disable-xctest`) turned out to be wrong: an on-device repro on Swift 6.3.1 / arm64 showed that SwiftPM's swift-testing discovery build plugin emits **0-byte stubs** for every suite on Windows (verified across Swift 6.1.2 + 6.3.1, x64 + arm64), so the test bundle finds zero tests at runtime and `swift test` exits 1 regardless of which library you pin. `--list-tests` / `--dump-tests-json` hang on the same path — that's the actual `error: abnormal(312)` surface, a hang killed by the test runner rather than a crash (no Event Viewer entry on the Windows side). Since the upstream fix isn't in our hands, Windows test coverage now lives in a new executable target `SwiftPWAWindowsTestRunner` ([Sources/SwiftPWAWindowsTestRunner/main.swift](Sources/SwiftPWAWindowsTestRunner/main.swift)) that re-expresses the `WindowsUpdater` coverage (Ed25519 happy path + wrong-key + malformed-signature + missing-key, MSIX vs portable verification, MSIX identity round-trip, minisign-format inputs — 12 cases total) against a small assertion harness, and the Windows CI job runs `swift run SwiftPWAWindowsTestRunner` instead of `swift test`. The old `SwiftPWAWindowsTests` testTarget is removed; `swift build --build-tests` still compile-checks the other test suites against the Windows toolchain so cross-platform regressions don't sneak in. Long-form rationale in [docs/windows-setup.md](docs/windows-setup.md) "Known limitations".

- **`swift-pwa init` no longer emits projects that fail to compile.** Two scaffold bugs surfaced during a live bring-up of the v0.3 scaffold:
  - **Hyphenated names broke the Swift build.** `swift-pwa init test-app` wrote `Package.swift` with `name: "test-app"`, an executable target `name: "test-app"`, an `@main struct test-appApp` (invalid identifier — Swift errored at `struct test-app|App`), and a `Sources/test-app/` directory. None of those compile. `Init` now normalises the user's argument through a new `sanitizeIdentifier(_:)` helper (`test-app` → `testApp`, `my cool app` → `myCoolApp`, `3d-viewer` → `_3dViewer`) and uses the sanitised form everywhere the value has to be a valid Swift identifier: `Package.swift`'s package + target names, `Sources/<id>/`, the `@main struct`, and `pwa.json`'s `name` field (which `MacAppBundler` uses as the binary-lookup and `.app`-output key, so it has to track the SwiftPM target name). The original string survives as `pwa.json`'s `window.title` and the `index.html` `<title>` / `<h1>` so the user's app still shows up under the typed name. A `note:` line in stdout flags the rename when it happens; pure-identifier inputs (`MyApp`, `Demo123`) are passed through unchanged.
  - **Web bundle path was wrong on macOS.** The generated `App.swift` resolved its web root via `Bundle.main.bundleURL.appendingPathComponent("web")`, which on macOS is `<App>.app/web` — but `MacAppBundler` copies the web files to `<App>.app/Contents/Resources/web`, so the `WKWebView` scheme handler couldn't find `index.html` and the user got a silent blank window (the worst possible failure mode). Fix: use `Bundle.main.resourceURL ?? Bundle.main.bundleURL`, which resolves to `Contents/Resources/` on macOS and to the bundle root on iOS (where `resourceURL == bundleURL`), matching where both bundlers place the files. Plus a runtime `FileManager.fileExists` check that fails loudly with the resolved path if the bundler somehow didn't copy `web/`, instead of leaving the user staring at a blank webview.

### Added

- **`docs/manual-test-cases.md`** — release-engineering checklist for behaviour the unit suite can't cover. Eight cases for the updater module: macOS `.app` end-to-end (Ed25519 verify + `ditto` swap + relaunch), wrong-key rejection visible in the UI, Linux AppImage atomic-rename swap (with an `EXDEV` cross-filesystem sub-case), Windows portable EXE `Move-Item` swap (with a Program Files permission-failure sub-case), Windows MSIX update *with the v0.4 post-install relaunch* (and a `msixIdentityName: nil` opt-out sub-case), iOS enterprise / ad-hoc `itms-services://` hand-off, `minisign(1)` interop including the prehashed `ED` rejection sub-case, and a cross-host CLI publishing round-trip. Each case has the same shape (What it covers / Setup / Steps / Pass criteria) so a release engineer can scan it as a checklist; per-release setup (build vN-1 + vN, generate keys + manifest) lives in one block at the top of the module so individual cases don't repeat it. README's Contributing section + `docs/auto-updates.md` both link to it so anyone touching the updater code lands on the manual cases. New modules (clipboard, dialogs, biometrics, …) get their own sections as they ship features whose pass criteria need a real OS in the loop.

## [0.4.0] - 2026-05-07

### Added

- **`DialogPlugin` — cross-platform native dialogs.** New opt-in plugin exposing `dialog.message` (info / warning / error message box), `dialog.confirm` (Cancel / OK with optional custom labels), `dialog.openFile` (single or multi-select file picker), `dialog.saveFile`, and `dialog.openDirectory`. Each backend wires the platform's HIG dialog: macOS uses `NSAlert` for message + confirm and `NSOpenPanel` / `NSSavePanel` for files (rendered as window-modal sheets when `NSApp.keyWindow` is available, app-modal otherwise); iOS uses `UIAlertController` for message + confirm and `UIDocumentPickerViewController` for openFile / openDirectory; the GTK3 backend goes through `GtkMessageDialog` / `GtkFileChooserDialog` via a new shim that wraps the variadic C constructors and runs them with `gtk_dialog_run`; the GTK4 backend uses `GtkAlertDialog` / `GtkFileDialog` (added in GTK 4.10) with `GAsyncReadyCallback` continuations bridged into Swift checked continuations the same way the GTK4 clipboard does it; Windows uses `MessageBoxW` / `TaskDialogIndirect` plus `IFileOpenDialog` / `IFileSaveDialog` from a new `swiftpwa_dialog` C++/COM shim (the COM lifetime juggling is ~80 lines of C++ that would balloon to several hundred in Swift). Dialogs are parented to the originating window automatically — `DialogPlugin` reads `CommandContext.originWindow` and threads a `WindowID` through every method, which each backend resolves to the platform-native parent (sheet on macOS, transient-for on GTK, owner HWND on Windows). `MockDialog` in `_SwiftPWATestSupport` lets apps test their UI flow without showing native panels.
- **`Window.nativeWindow` / `Win32Window.nativeHwnd` internal accessors** on the GTK3 / GTK4 / Windows backends, so sibling code (currently `SystemDialog`) can parent transient panels onto a known window without exposing the underlying widget pointer / HWND publicly.
- **`comctl32.dll` link** in `CWebView2Shim`'s linker settings — required by `TaskDialogIndirect`, used by the dialog shim's `confirm` path when the caller customises the OK / Cancel labels (which `MessageBoxW` cannot do). To get a working `TaskDialogIndirect` the EXE also needs a `Microsoft.Windows.Common-Controls` v6.0.0.0 manifest dependency in its resource section; without it, the loader resolves the import against comctl32 v5 (which stubs the symbol by ordinal but doesn't implement it) and surfaces "Ordinal 345 could not be located" at process start. We tried embedding the dependency via `#pragma comment(linker, "/manifestdependency:...")` in the C++ shim; `lld-link` (which Swift-on-Windows uses via clang-cl, not MSVC's `link.exe`) silently drops the pragma at .obj-merge time, leaving the EXE with no resource section. Instead the CLI bundler now runs `mt.exe -manifest ... -outputresource:<exe>;#1` post-build (`WindowsBundler.embedComCtl6Manifest`); when `mt.exe` isn't on PATH (a non-VS shell) it warns and continues, and `dialog.confirm` falls back to plain `MessageBoxW` at runtime.
- **Dialog verification card in `Examples/HelloPWA`.** New "Dialogs" section in the controls column with Confirm / Open file / Save file / Pick folder buttons; each invokes one of the new commands and logs the result, giving a quick sanity check on every backend.
- **`FsPlugin` — Foundation-backed filesystem access.** New opt-in plugin exposing `fs.readText` / `writeText`, `fs.readBinary` / `writeBinary` (base64 over the bridge), `fs.exists`, `fs.mkdir` (with `recursive`), `fs.remove` (refuses non-empty directories without `recursive: true`, matching `rm -d`), `fs.readDir` (sorted output for stable rendering), `fs.copy`, `fs.rename`, and `fs.metadata` (size + isDir/isFile + modified-millis). Backed by a single `SystemFs` Foundation implementation that lives in `SwiftPWACore` — `FileManager.default` and `FileManager.contents(atPath:)` work identically across Apple Foundation, swift-corelibs-foundation on Linux, and the Windows port, so no per-backend `SystemFs` is needed. `MockFs` in `_SwiftPWATestSupport` covers tests; `SystemFs` itself has integration tests that drive a real temp directory. Filesystem scope intentionally not enforced by the plugin — the host process's privilege model is what gates access; apps that want a sandbox can pair this with `DialogPlugin.openFile` so the user grants paths through the picker. New "Filesystem" verification card in `Examples/HelloPWA` walks through write → read → metadata → remove against a path you pick (or the temp dir if you cancel).
- **`swift-pwa updater` CLI subcommands.** New `keygen`, `sign`, and `manifest` subcommands cover the publishing pipeline that backs the runtime-side `Updater` protocol — without them, the auto-updater shipped in v0.3 was effectively read-only since there was no first-party way to produce the artifacts it consumes (operators were left to glue together `openssl genpkey` / a Swift one-off / a hand-edited JSON file). `keygen` generates an Ed25519 keypair, writing the private half 0600 (so a stray `cat` from another shell on the dev box doesn't leak it) and printing the matching `pwa.json` `updater` block to paste in. `sign` signs a release artifact with that private key and emits base64 of the raw 64-byte signature — byte-compatible with the format `AppleUpdater.verifyEd25519` already accepts. `manifest` assembles the per-target JSON the runtime's `updater.endpoint` URL serves; each `--platform` spec is one of `<target>=<artifact-path>=<download-url>` (sign on the fly), `<target>=<download-url>=<base64-signature>` (pre-signed), or `<target>=<download-url>` (no signature, only valid for iOS enterprise / ad-hoc where Apple's signing chain validates the .ipa). Wire format is the existing `UpdateManifest` shape from `SwiftPWACore`, matching Tauri v1's updater manifest layout — same publishing tooling can produce manifests for swift-pwa apps. The CLI library now depends on `swift-crypto`'s `Crypto` module rather than `CryptoKit`, so `keygen` and `sign` work on Linux and Windows release machines (CryptoKit is Apple-only); on Apple platforms `import Crypto` shadows CryptoKit so there's no behavioural change. Manifest spec parsing reassembles trailing `==` base64 padding even though `=` is the field separator, so real Ed25519 signatures round-trip cleanly. Tested via `UpdaterCLITests` (10 cases covering spec parsing, key load, sign-verify round-trip against the public key, and a manifest snake-case round-trip that pins the Tauri-compatible wire keys). Publishing walkthrough (`keygen` → `sign` → `manifest`) lives in [docs/auto-updates.md](docs/auto-updates.md); README points at it rather than inlining the detail.
- **`WindowsUpdater` — auto-updater runtime backend for Windows (portable + MSIX).** New `Updater` implementation that closes the last v0.4 gap behind the `swift-pwa updater` publishing CLI — Apple shipped in v0.3, Linux earlier in this cycle, and now Windows. One class with an `installMode: InstallMode { .portable, .msix }` switch picks between the two formats `swift-pwa build --target windows` produces. The `download` flow is shared: fetch the artifact, signature-verify the bytes against the configured base64 Ed25519 public key (via `swift-crypto`'s `Crypto` module — same Linux-style conditional dep added to `SwiftPWAWindows` + `SwiftPWAWindowsTests`), and stage under `%LOCALAPPDATA%\<bundle-id>\SwiftPWAUpdates\<version>\`. `installAndRelaunch` diverges by mode: portable spawns a detached PowerShell helper that `Wait-Process`es the running PID, `Move-Item -Force`s the staged EXE onto the running EXE's path (resolved with `GetModuleFileNameW`), and `Start-Process`es the result; MSIX spawns the same kind of helper but runs `Add-AppxPackage -Path … -ForceUpdateFromAnyVersion` instead, leaving the OS to validate the Authenticode chain. The helper goes through `powershell.exe -EncodedCommand <utf16-le-base64>` rather than dropping a `.ps1` on disk, both to bypass the default `Restricted` execution policy without elevation and to dodge PowerShell's command-line quoting rules (paths with spaces, brackets, single quotes, or non-ASCII characters all round-trip cleanly through the encoded-command channel). Stdio on the helper is redirected to `NUL` so the spawned process isn't tied to the terminal we're about to exit. The `publicKey` argument is required for `.portable` (a swappable EXE is full code execution; verifying signatures is non-negotiable) but optional for `.msix` (Authenticode is the real authentication; Ed25519 over the bytes pins *which* signed package this updater channel is allowed to install, so production deployments should set it for both). Tests in `SwiftPWAWindowsTests` cover the staged-state error path, the `executablePath` override, the Ed25519 verifier (round-trip / wrong-key / missing-key / malformed-signature), the MSIX-without-key escape hatch, the MSIX-with-key still-verifies path, and the portable-without-key error. Post-install relaunch on `.msix` is queued for a follow-up — `Add-AppxPackage` updates the package on disk but the running EXE keeps the old code mapped, so the runtime exits and the user relaunches from Start; wiring `Start-Process "shell:AppsFolder\<AUMID>!App"` into the helper is additive.
- **`LinuxAppImageUpdater` — auto-updater runtime backend for Linux.** New `Updater` implementation that completes the second of the three v0.4 backends queued behind the `swift-pwa updater` publishing CLI (Apple shipped in v0.3; Windows still queued). `download` fetches the new AppImage, signature-verifies the gzip-or-raw bytes against the configured base64 Ed25519 public key (via `swift-crypto`'s `Crypto` module — CryptoKit is Apple-only, but `import Crypto` presents the same API on Linux backed by BoringSSL), `chmod +x`s it, and stages it under `${XDG_CACHE_HOME:-$HOME/.cache}/<bundle-id>/SwiftPWAUpdates/<version>/`. `installAndRelaunch` resolves the running AppImage's path from the `APPIMAGE` env var the AppImage runtime sets and **atomically renames** the staged file onto it — Linux `rename(2)` is atomic within a filesystem and replaces the destination, while the kernel keeps the running process's mmap of the old inode valid until exit, so the running AppImage continues working through the swap and new launches resolve to the new bundle. Cross-filesystem rename (`EXDEV`) falls back to `copy → rename` via a temp file in the destination directory so the final swap is still atomic. After the rename, the updater spawns the (now-updated) AppImage as a detached child via `/bin/sh -c 'setsid <path> </dev/null >/dev/null 2>&1 &'` and `exit(0)`s — same hand-off pattern as the macOS Squirrel-style helper. Returns a clear error if `APPIMAGE` is unset (running from `swift run` / `.build/...` rather than a real bundle), pointing the developer at `swift-pwa build --target linux`. Tests in `SwiftPWAGTKTests` cover the staged-state error path, the `APPIMAGE` env / override resolution, the same-fs `atomicReplace` (clobber + fresh target), and the Ed25519 verifier (round-trip happy path against `Curve25519.Signing.PrivateKey`, wrong-key rejection, missing-key rejection, malformed signature rejection). The `pwa.json` `updater.linux.appimage_strategy` field (`in_place` / `side_by_side`) is reserved — v0.4 ships `in_place` only; the `side_by_side` mode that writes to `~/.local/bin/<app>-<version>.AppImage` and updates a symlink is queued for a future iteration. The file is duplicated verbatim in `Sources/SwiftPWAGTK/` and `Sources/SwiftPWAGTK4/` because the two GTK backends are separate Swift targets in `Package.swift`; the duplication is acknowledged at the top of each copy. Walkthrough lives in [docs/auto-updates.md](docs/auto-updates.md)'s "Linux (AppImage)" section.
- **`BiometricAuthPlugin` — cross-platform biometric / device-owner authentication.** New opt-in plugin exposing `biometric.canAuthenticate` (returns `BiometricAvailability { available, kind, reason? }` with `kind ∈ {none, touchID, faceID, opticID, windowsHello, unknown}`) and `biometric.authenticate({ reason })` → `BiometricAuthResult { authenticated, error? }`. Apple backend wraps `LAContext.canEvaluatePolicy` / `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason:)` (works on macOS / iOS / iPadOS / visionOS — Optic ID maps onto `.opticID`). Windows backend goes through `IUserConsentVerifierInterop::RequestVerificationForWindowAsync` (the desktop-app variant of the WinRT API) via a new `swiftpwa_biometric` C++/WinRT shim that bridges `IAsyncOperation<...>::Completed` into a flat C callback (same pattern as `swiftpwa_toast`); the Swift side wraps that into a `CheckedContinuation`, mirroring how the GTK4 dialog adapter does it. The interop variant is the one that works on unpackaged Win32 EXEs — the static `RequestVerificationAsync` entry point assumes MSIX identity and silently hangs (camera indicator on, no prompt UI) when called from a portable build; the interop call passes `GetForegroundWindow()` as the parent HWND and brings up the dialog as a modal. Linux ships a stub that always reports `available: false` (`reason: "biometric authentication is not supported on Linux"`) — there is no cross-distro biometric primitive: `libfprint` covers a subset of fingerprint readers and isn't preinstalled, polkit gives root-style authorization, PAM is system configuration. The protocol's "cancel is not an error" contract is honoured by every backend: user dismissal returns `authenticated: false` with `error: "cancelled"` (or platform-equivalent string) rather than throwing; system-level errors (no sensor, lockout, policy disabled) propagate as `BridgeError(code: .handler)`. `MockBiometricAuth` in `_SwiftPWATestSupport`. New "Biometrics" card in `Examples/HelloPWA` exercises both commands.
- **Streaming download progress on every updater backend.** `AppleUpdater`, `LinuxAppImageUpdater`, and `WindowsUpdater` previously emitted a single `(0, nil)` start frame and a single end frame — fine for a CLI status line but useless for a progress bar over a 50 MB AppImage. Replaced the three backends' ad-hoc `urlSession.download(from:)` two-shot with a shared `UpdaterDownload` helper in `SwiftPWACore` that wraps `URLSessionDownloadDelegate` and turns `didWriteData` into per-chunk `downloadProgress(bytesDownloaded, contentLength)` events (typically every ~64 KB). The helper handles the "URL session retains its delegate strongly until invalidated" lifecycle (defer `invalidateAndCancel`), moves the temp file synchronously inside `didFinishDownloadingTo` (URLSession deletes it as soon as the callback returns), and surfaces non-2xx HTTP / transport / move errors as `BridgeError(code: .handler)` to fit the existing wrap pattern. Lives in core because the same wire shape applies on every backend; backends just plug their own `yield` into the callback. `FoundationNetworking` import is conditional, mirroring the bundlers.
- **Minisign-format public keys + signatures, accepted everywhere.** `SwiftPWACore.Minisign` parses the [minisign](https://jedisct1.github.io/minisign/) two-line `untrusted comment: …\n<base64>` shape into raw 32-byte keys / 64-byte signatures, and `resolveEd25519PublicKey` / `resolveEd25519Signature` coerce either form (raw base64 or minisign) to bytes at the verify boundary. The three runtime updaters and the publishing CLI now share the same coercion — paste a `minisign(1)` key file into `pwa.json`'s `updater.public_key` and it works, no preprocessing. Legacy `Ed` algorithm only (pure Ed25519 over the artifact bytes); the prehashed `ED` mode is rejected with a message pointing at `minisign -Sl` to produce a legacy-mode signature. We don't bundle BLAKE2b — neither CryptoKit nor swift-crypto ships it, and the legacy mode matches what Tauri's publishing pipeline produces. The trusted-comment global signature is *not* verified (no BLAKE2b); the message body's signature against the artifact bytes is what authenticates a release. `swift-pwa updater keygen --minisign` and `swift-pwa updater sign --minisign` opt the CLI into the same output shape; the default stays raw-base64 for compatibility with v0.3 release pipelines. Round-trip tests pin the wire format end-to-end (`MinisignFormat` encoder in CLI → `Minisign` parser in core → Curve25519 verify against the original payload).
- **Post-install relaunch on Windows MSIX updates.** `WindowsUpdater(installMode: .msix, …)` now accepts an `msixIdentityName:` parameter — the `Identity.Name` value baked into the running MSIX's `AppxManifest.xml` — and the PowerShell helper appends a `$pkg = Get-AppxPackage -Name <identity>; if ($pkg) { Start-Process shell:AppsFolder\$($pkg.PackageFamilyName)!<app-id> }` block after `Add-AppxPackage` completes, so the updated app re-launches without the user having to find it in Start. Resolution goes through `Get-AppxPackage` rather than `GetCurrentPackageFamilyName` for two reasons: the family name is an opaque hash of the publisher CN that's awkward to derive in Swift, and looking it up after `Add-AppxPackage` reflects the new package on disk rather than the (now-stale) running process's identity — self-correcting if the publisher rotated and the family name changed. Identity defaults to `nil` (no relaunch line), and `applicationID` defaults to `"App"` to match what `AppxManifestGenerator.render` emits. The `~500 ms` `Start-Sleep` before relaunch lets the OS finish registering the updated package; without it, intermittent "package not found" races appear under load. `installMode: .portable` already had relaunch via the helper's `Start-Process` after `Move-Item`; this closes parity.
- **Updater verification card in `Examples/HelloPWA`.** New "Updater" section in the controls column with Check / Run full flow / Try install buttons plus a streaming progress bar, all wired against an in-process `DemoUpdater` (synthesises a 4.5 MB / 270 ms progress arc) so the v0.4 streaming-download feature has a visible exhibit without needing a real release server. Production apps swap the demo updater for `AppleUpdater` / `LinuxAppImageUpdater` / `WindowsUpdater` against a signed manifest. The bar listens to every `downloadProgress` event the runtime emits and resets between runs; `installAndRelaunch` deliberately throws (the running `swift run` process has nothing to swap onto) so the UI demonstrates the error path real apps would gate behind a "Restart now / later" prompt.
- **`swift-pwa build --target windows --arch <x64|x86|arm64>` MSIX architecture flag.** The previous bundler hardcoded `<Identity ProcessorArchitecture="x64">` in the generated `AppxManifest.xml`, so MSIX packages built on an arm64 host still claimed x64 identity and `Add-AppxPackage` rejected them on the same machine ("doesn't match this device"). New `Architecture` enum on `AppxManifestGenerator` plus the `--arch` flag on `Build` lets the user pick `x64` (default), `x86`, or `arm64`; the flag also accepts the Swift-style spellings `x86_64` and `aarch64` (handy when piping through `arch --print` / `uname -m`-derived values from CI scripts). Cross-compile isn't supported — the architecture must match the host's Swift toolchain because `swift build` produces a host-arch EXE — but CI fan-out is now one-flag-per-runner instead of patching XML by hand. `AppxManifestGeneratorTests` cover x64/arm64/x86 rendering and the parse aliases.

### Changed

- **README rewritten to be marketing-facing; deep references moved under `docs/`.** The README had grown to 323 lines of mixed pitch + reference + per-plugin command catalogue + a 13-bullet "Known limitations" list that duplicated what each `docs/<platform>-setup.md` already said. Trimmed to ~220 lines structured around a new per-platform feature matrix (rows = capabilities, columns = macOS / iOS / Linux GTK3 / Linux GTK4 / Windows; cells = `Yes` / `Partial` / `—` / `v0.4` with footnotes for nuance). The full JS plugin surface moved to [docs/javascript-api.md](docs/javascript-api.md); the Swift API and concurrency-model notes moved to [docs/swift-api.md](docs/swift-api.md); the Known-limitations bullets were already mirrored in each platform's setup doc, so the README copy was deleted rather than re-edited (single source of truth). New CLAUDE.md convention codifies the pattern so future feature drops land detail in `docs/` from the start instead of inflating README again.
- **Linux CI now compiles the full package graph on both GTK3 and GTK4.** The `linux-gtk3` and `linux-gtk4` jobs were limited to `swift build --target SwiftPWACore --target swift-pwa-cli`, which left every `#if os(Linux)`-gated source file out of CI. Two regressions slipped past in the v0.4 cycle as a direct result — a `strdup` type-inference error in `Sources/SwiftPWAGTK/SystemDialog.swift` and a strict-concurrency capture diagnostic in `Sources/SwiftPWAGTK4/SystemDialog.swift` — both compile-gated only on a real Linux box, both invisible to the macOS CI job. Drop the target filter; both jobs now run plain `swift build -v` against the whole graph (the matching dev packages are already installed for pkg-config resolution). Tests stay filtered to `SwiftPWACoreTests` + `SwiftPWACLITests` since the GTK targets need a display to run.

### Fixed

- **GTK4 dialog deadlock that stalled the bridge.** The GTK4 `SystemDialog`'s `runAlert` / `runFileDialog` were `@MainActor`-isolated, so calling them from the bridge's pump task tried to hop via Swift's MainActor executor — libdispatch's main queue, which `gtk_main()` doesn't drain. The C shim never got called, the suspending continuation never resumed, and because the bridge pump processes invokes sequentially (`for await frame in stream { await handle(frame) }`), every subsequent `dialog.*` / `fs.*` / `biometric.*` invoke queued behind the hung one and silently failed to dispatch. Symptom: clicking Confirm / Save / etc. did nothing, then biometric buttons also did nothing — not even the "unsupported on Linux" log line appeared. Fixed by routing the C-shim call through `MainThread.run` (the registered `g_idle_add` hook) instead. This is the same pattern the GTK3 `SystemDialog` uses, and matches the convention CLAUDE.md already documents.
- **GTK4 dialog use-after-scope in `buildFilterStore`.** The per-filter pattern arrays were stored as typed pointers obtained inside `Array.withUnsafeMutableBufferPointer { ... withMemoryRebound { … } }` closures and then handed to the C shim outside those scopes. Heap-allocated via `UnsafeMutablePointer.allocate` instead, with a `defer` block freeing them after the call. Wouldn't have surfaced before the deadlock fix above (filtered file dialogs hung before reaching the bug); will now.
- **DevTools (Ctrl+Alt+J) does nothing on the GTK backends.** Pre-existing v0.2 bug: neither the GTK3 nor GTK4 adapter set `enable-developer-extras` on `WebKitSettings`, so `webkit_web_inspector_show` was a no-op even though the keypress accelerator and inspector lookup all worked. Set it in both backends' adapter `init`. Inspector now opens as a separate window, same as the macOS / Windows DevTools shortcut.

### Notes

- **iOS `dialog.saveFile` is a stub** that returns `nil` and logs a one-shot stderr warning. iOS has no system save panel — apps export through `UIDocumentPickerViewController(forExporting:)` (which takes a *written* file URL) or `UIActivityViewController`, neither of which fits the cross-platform shape. See [docs/ios-setup.md](docs/ios-setup.md).
- **GTK4 dialogs require GTK 4.10+** for `GtkAlertDialog` and `GtkFileDialog`. Older 4.x distros need to either upgrade or stick with the GTK3 backend.
- **Custom button labels on Windows route through `TaskDialogIndirect`** rather than `MessageBoxW` (which has system-localised buttons baked in). When the caller doesn't customise either label, we stay on `MessageBoxW` so binaries built outside a Visual Studio Developer Shell — where the bundler can't run `mt.exe` to embed the comctl32 v6 manifest — still work without the themed-controls activation context.
- **`BiometricAuthPlugin` is unsupported on Linux.** The Linux `SystemBiometricAuth` always reports `available: false`; `authenticate` returns `authenticated: false` with a clear reason rather than throwing. Apps targeting Linux should fall back to a passphrase flow.
- **`FsPlugin` does not enforce a path scope.** It hands JS the host process's full filesystem privileges — apps that need a "JS can only touch this folder" restriction should layer that themselves (typically by intercepting commands in a wrapping plugin or by gating writes behind `dialog.openFile` so the user grants the path).

## [0.3.0] - 2026-05-06

### Added

- **Windows toast notifications via `Windows.UI.Notifications.ToastNotificationManager`.** New `swiftpwa_toast` C++/WinRT shim (`Sources/CWebView2Shim/swiftpwa_toast.{h,cpp}`) exposes `swiftpwa_toast_init` / `swiftpwa_toast_send` / `swiftpwa_toast_remove` over a flat C ABI; `SystemNotifications` calls through it and falls back to the prior `Shell_NotifyIconW` balloon path when the WinRT side reports unavailable (Server Core without Desktop Experience, missing AUMID, etc.). `WindowsAppRuntime` derives a stable AppUserModelID from the executable basename (`SwiftPWA.<exe-stem>`) at process start and pushes it through both `SetCurrentProcessExplicitAppUserModelID` and `swiftpwa_toast_init`, so toasts surface with the right attribution out of the box. We did not take a `swift-winrt` dependency — the WinRT surface (one notifier, one XML payload) is small enough that wrapping it in C++/WinRT is simpler than wiring up the projection toolchain. `WindowsApp.lib` is now linked from `CWebView2Shim` for the same reason.
- **Per-Monitor V2 DPI awareness.** `WindowsAppRuntime` calls `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` before any window is created. `Win32Window` converts at every API boundary: `setSize` / `setPosition` multiply by `GetDpiForWindow / 96.0`, `size()` / `position()` divide back, `WM_SIZE` and `WM_MOVE` events emit DIPs, and `WM_DPICHANGED` accepts the OS-suggested rect verbatim. Non-client (titlebar, scrollbars) scales correctly under V2. The initial `CreateWindowExW` uses `GetDpiForSystem` since there's no HWND yet to query.
- **MSIX packaging in the bundler.** `swift run swift-pwa build --target windows --package-format msix` drives `makeappx.exe pack` against a staging tree containing the EXE, web bundle, generated `AppxManifest.xml`, and a `Square150x150Logo.png` (taken from `pwa.json`'s `icon` if provided, otherwise a 1×1 placeholder). `--sign <thumbprint-or-pfx>` chains `signtool.exe sign` afterwards (40-hex-char strings → `/sha1`, otherwise treated as a PFX path). The new `AppxManifestGenerator` renders the manifest against the v10 schema, derives `Identity.Name` from `pwa.json`'s `id`, pads three-component versions to four for MSIX schema compliance, and XML-escapes user-supplied display name / description; covered by `AppxManifestGeneratorTests`.
- **Opt-in WebView2 Evergreen Bootstrapper.** `--bootstrap-webview2` makes the bundler download Microsoft's `MicrosoftEdgeWebview2Setup.exe` (~1.7 MB) and place it next to the EXE. `WindowsAppRuntime` detects a missing runtime via `GetAvailableCoreWebView2BrowserVersionString`, finds the bootstrapper alongside the executable, and offers a `MessageBoxW` Yes/No prompt before `ShellExecuteEx`-ing it with elevation and waiting on the install to complete. When the bootstrapper isn't present we fall back to the existing stderr install hint so `swift run` from a dev box still gives a useful diagnostic. End-to-end-tested on Win11; the one documented edge case is a partially-broken WebView2 install (binaries missing, registry intact) where the bootstrapper trusts the registry and exits without writing — Edge repair recovers, called out in [docs/windows-setup.md](docs/windows-setup.md)'s Known limitations.
- **Windows binary in the release matrix.** New `cli-binary-windows` job in `.github/workflows/release.yml` (windows-2022 + MSVC + Swift-for-Windows + WebView2/WIL NuGet) produces `swift-pwa-windows-x86_64.exe` and uploads it as a release artifact alongside the macOS / Linux binaries. The `release` job's `needs:` was extended to wait on the new job before publishing.
- **Auto-updater (Apple platforms).** Why ship one: a Tauri-analogue thin client without an in-app updater story leaves users stuck on the version they first installed, and "build your own" against three different platform-native updaters (Sparkle / WinSparkle / AppImageUpdate) defeats the "one Swift package, one JS API" pitch. New `Updater` protocol + `UpdaterPlugin` in `SwiftPWACore` expose `updater.check` (unary, returns `UpdateInfo?`), `updater.run` (streaming `checking` → `available` → `downloadProgress*` → `readyToInstall` events), and `updater.installAndRelaunch` over the existing bridge — JS surface is one subscription per update flow, not three coordinated calls. `AppleUpdater` in `SwiftPWAWebKit` covers macOS (download a signed `.app.tar.gz`, verify Ed25519, untar to `~/Library/Caches/<bundle-id>/SwiftPWAUpdates/<version>/`, spawn a detached `/bin/sh` helper that waits for the parent PID to exit, `ditto`s the staged bundle in place, and re-`open`s — the standard Squirrel-style trick) and iOS enterprise / ad-hoc (the manifest entry's `url` points at the install-manifest plist; `installAndRelaunch` opens `itms-services://?action=download-manifest&url=…` and the system installer takes over — no Ed25519 key needed because Apple's signing chain validates the .ipa). Wire format is byte-compatible with Tauri v1's updater manifest (`{ version, pub_date, notes, platforms: { "<target>": { url, signature } } }`) so the same publishing tooling can produce it. New `pwa.json` `updater` section captures the wiring (`endpoint`, `public_key`, `pubkey_algorithm`, optional `auto_check`, `windows.install_mode`, `linux.appimage_strategy`) — the runtime side is opt-in on the Swift side regardless. `MockUpdater` in `_SwiftPWATestSupport` lets apps test their UI flow without a network. Linux AppImage + Windows MSIX/portable backends and the `swift-pwa updater keygen / sign / manifest` CLI subcommands are queued for v0.4. Documented limitations: full-bundle replacement only (delta updates queued); raw base64 Ed25519 only (minisign-format key + signature parsing queued); macOS download progress fires at start + end only (`URLSessionDownloadDelegate`-driven streaming queued); macOS install fires no UI before the swap (apps that want a "Restart now / later" prompt should gate `updater.installAndRelaunch` behind their own dialog); no `min_supported_version` kill-switch yet (queued).
- **Auto-detect of the swift-pwa NuGet packages directory.** When the bundler launches `swift build` for a `--target windows` build, it walks `<projectRoot>/packages/`, `<projectRoot>/../packages/`, `<projectRoot>/../../packages/`, and `<projectRoot>/.build/checkouts/swift-pwa/packages/` looking for the `Microsoft.Web.WebView2` + `Microsoft.Windows.ImplementationLibrary` headers. If found, prepends them to `INCLUDE` / `LIB` (case-insensitively, so PowerShell's `Path` and cmd.exe's `PATH` are both handled) before launching the child process. Eliminates the per-session export ritual that v0.2 required for every fresh PowerShell window — `Launch-VsDevShell.ps1` is now the only per-session prereq.
- **Windows toast verification card and per-platform webview detection in `Examples/HelloPWA`.** Demo restructured into a two-column layout (sectioned controls on the left, log panes on the right) with a dedicated Notifications card whose second button is labelled "Send Windows toast" — same `notifications.send` call, but the help text names what it's exercising and tells the tester what to look for in Action Center. Subtitle now detects the active webview at runtime (`window.chrome.webview` for WebView2, `window.webkit.messageHandlers` for WKWebView / WebKitGTK split on `navigator.platform`) and renders one of `WKWebView (macOS)` / `WKWebView (iOS)` / `WebKitGTK` / `WebView2`.

### Changed

- Package-level `cxxLanguageStandard: .cxx20` (required by C++/WinRT under the Swift-for-Windows toolchain — cppwinrt's `<winrt/base.h>` includes `<experimental/coroutine>` under C++17, which the MSVC STL rejects when the front-end is clang. C++20 routes through the standard `<coroutine>` header and compiles clean. WIL and WebView2.h both build fine under C++20.)
- "Docs travel with code changes" convention added to [CLAUDE.md](CLAUDE.md): each behavioural change ships with a doc update in the same commit (or commit pair), specifying which surface (README / `docs/<platform>-setup.md` / Known limitations / CHANGELOG) for which kind of change. Same shape as the existing cross-platform-parity rule.

### Fixed

- **`swift-pwa build` on Windows is now end-to-end functional** after a real-host smoke test exposed five Foundation-on-Windows / SwiftArgumentParser / SwiftPM warts we'd compiled-cleanly through. Each fix is a small, isolated patch:
  - `@available`-annotated `SwiftPWACLIEntry.run()` wrapper so the call site has SAP's async `main()` overload visible — without it, overload resolution on Windows / Linux falls back to the sync version and SAP exits with "Asynchronous root command needs availability annotation" before reaching the build subcommand.
  - `Data(contentsOf: fileURL)` is unreliable on swift-corelibs-foundation under Windows (returns NSCocoaError 260 on real files); read via `FileManager.default.contents(atPath:)` instead.
  - `Process.executableURL` is resolved literally on Windows; bare `swift` becomes `./swift` and fails to launch. New `Shell.resolveExecutable` does an explicit PATH walk with PATHEXT-style suffixes (`.exe`, `.cmd`, `.bat`), case-insensitive PATH lookup, and `fileExists` rather than `isExecutableFile` (which checks the POSIX execute bit that doesn't exist on NTFS).
  - `FoundationNetworking` import on Linux / Windows for the WebView2 bootstrapper download (`URLSession.shared` lives there, not in `Foundation` proper, on swift-corelibs-foundation).
  - `.build/release/<Name>.exe` lookup falls back to scanning `.build` for a `*-windows-msvc/release/<Name>.exe` directory when SwiftPM can't create the symlink (Windows symlink creation requires Administrator or Developer Mode).

## [0.2.0] - 2026-05-05

### Added

- **Windows backend.** New `SwiftPWAWindows` Swift target plus `CWebView2Shim` C++ COM shim wraps Microsoft Edge WebView2 behind the same `AppRuntime` / `Window` / `PWAWebView` protocols as the Apple and Linux backends. JS↔Swift bridge round-trips verified end-to-end on Windows 11 ARM64 (Swift 6.3.1, Visual Studio 2026, WebView2 SDK 1.0.3912.50, WIL 1.0.260126.7) against `Examples/HelloPWA`. Window lifecycle, clipboard (Win32 Clipboard API), tray (`Shell_NotifyIconW` + `TrackPopupMenu` via a thin C shim because the Swift WinSDK overlay imports `TrackPopupMenu` as `Bool` and drops the chosen-command id), and balloon-style notifications (`NIF_INFO`) all work; richer toast XML waits on the swift-winrt rollout in v0.3. The CLI's `swift-pwa build --target windows` ships a portable folder bundle (`MyApp\MyApp.exe` + `web/` + `pwa.json`) that runs on any Windows 10 21H2+ / Windows 11 box with the WebView2 Runtime installed; the static loader (`WebView2LoaderStatic.lib`) is linked in so apps don't need a sidecar `WebView2Loader.dll`. Bundled content uses `SetVirtualHostNameToFolderMapping` (`https://swift-pwa.local/...`) rather than a custom scheme to keep ESM and `fetch` happy without fighting WebView2's same-origin checks. Architecture-clean for both x64 and ARM64; builds natively on either host (cross-compile on Swift-for-Windows is still rough).
- **Cross-platform DevTools shortcut.** `Cmd+Opt+J` on macOS (best-effort `_showInspector:` SPI, gated on `responds(to:)` so a future runtime change just logs a hint), `Ctrl+Alt+J` on Linux GTK3 / GTK4 (via `webkit_web_view_get_inspector` + `webkit_web_inspector_show` on a per-window `GtkAccelGroup` / `GtkShortcutController`), and `Ctrl+Alt+J` on Windows (already shipped — pulls WebView2's built-in DevTools window via `ICoreWebView2::OpenDevToolsWindow`). New `openDevTools()` method on the `PWAWebView` protocol with a default no-op so backends that don't support it (currently iOS — debug from Safari on a paired Mac) opt out cleanly.
- **`bridge.js` learned the WebView2 message channel**: outbound via `window.chrome.webview.postMessage(json)` as a fallback after the existing `webkit.messageHandlers.__SwiftPWA__post.postMessage` lookup; inbound via a `message`-event listener on `chrome.webview` so `ICoreWebView2::PostWebMessageAsString` frames flow through `deliver()` the same way `evaluateJavaScript("…__deliver(…)")` does on the WK / WebKitGTK paths.
- [docs/windows-setup.md](docs/windows-setup.md) walkthrough: toolchain (Swift 6 / VS Build Tools / WebView2 SDK / WIL NuGet), per-session `Launch-VsDevShell.ps1 -Arch` invocation, INCLUDE / LIB exports, a "Windows on ARM" section, and a per-symptom failure-mode table for the most common setup misses.
- **`windows-latest` CI job** in [.github/workflows/ci.yml](.github/workflows/ci.yml). Installs Swift via `compnerd/gha-setup-swift`, fetches the WebView2 SDK and WIL via `nuget install`, sources `Launch-VsDevShell.ps1`, then runs `swift build -c release` + the cross-platform test suites. Catches Windows-specific regressions on x64 even though the smoke-test happened on ARM64.
- **Notifications plugin.** New opt-in `NotificationsPlugin` exposes `notifications.requestAuthorization` and `notifications.send({title, body?, sound?})`. Apple uses `UNUserNotificationCenter` (works in a bundled, signed `.app`; `swift run` returns "not allowed" since the process has no bundle identity, surfaced as a thrown `BridgeError(code: .handler)`). Linux hits `org.freedesktop.Notifications` directly through GIO's `g_dbus_connection_call_sync` — no libnotify / libayatana-appindicator dep, just a new `gio-2.0` link in the C shim modulemaps (already supplied by `libglib2.0-dev`). Click events / actions / replace-by-id are intentionally deferred — they need delegate / signal plumbing that's better landed alongside a `notifications.subscribe` stream.
- `_SwiftPWATestSupport.MockNotifications` for plugin-level unit tests.
- **Tray plugin.** New opt-in `TrayPlugin` exposes `tray.setIcon`, `tray.setTooltip`, `tray.setMenu`, `tray.setVisible`, and `tray.subscribe` (streaming `.click` / `.menuItemClicked` events). Full implementation on macOS via `NSStatusItem` + `NSMenu`, and on the GTK3 Linux backend via `libayatana-appindicator3` (StatusNotifierItem over D-Bus) — works on GNOME with the AppIndicator extension, Plasma, Sway / Hyprland, Wayland, and falls back to `GtkStatusIcon` internally on legacy Xembed-only desktops. The C state machine (AppIndicator instance, current menu, signal trampolines) lives in the new `CAyatanaAppIndicator3Shim` system library; `libayatana-appindicator3-dev` is now a hard build dep of the GTK3 backend. On iOS and the GTK4 backend `SystemTray()` returns a no-op stub that logs a one-shot warning — iOS has no system tray, and `libayatana-appindicator3` can't be reused from a GTK4 process (GTK3/4 are mutually exclusive in a single process; the GTK4-native fork isn't yet broadly packaged). `TrayEvent.click` is macOS-only since the SNI spec gives the desktop panel ownership of click semantics; `TrayEvent` uses the same `{type: "...", ...}` JSON discriminator as `WindowEvent`.
- `_SwiftPWATestSupport.MockTray` for plugin-level unit tests.
- **Clipboard plugin.** `ClipboardPlugin` is now auto-installed on every backend's `AppContext` alongside `WindowPlugin`, exposing `clipboard.readText`, `clipboard.writeText`, and `clipboard.clear` to JS. Backends provide a `SystemClipboard`: `NSPasteboard.general` on macOS, `UIPasteboard.general` on iOS, `GtkClipboard` on the GTK3 backend, and `GdkClipboard` on the GTK4 backend — the GTK4 implementation bridges `gdk_clipboard_read_text_async` into a Swift `CheckedContinuation` through a new `swiftpwa_clipboard_*` shim so the `Clipboard` protocol stays uniform across backends. `clear()` semantics differ by platform (Apple wipes the system clipboard; X11 / Wayland only relinquish local ownership) — documented on the protocol.
- `_SwiftPWATestSupport.MockClipboard` for plugin-level unit tests.

### Notes

- Two non-obvious gotchas surfaced during Windows bring-up, worth pinning for anyone hosting a webview in a Win32 HWND: (1) **don't set `hbrBackground` on a parent that hosts a DComp-rendered child** like WebView2. The system brush will paint over the visual surface every `WM_ERASEBKGND` even when `WS_CLIPCHILDREN` is set, since the flag only matters for GDI children. Symptom: `NavigationCompleted success=1` but the window stays blank, and right-click does nothing because input goes to the parent's GDI surface instead of the controller. (2) **Swift's `MainActor` executor on Windows isn't drained by your `GetMessageW` pump** — same root cause as the GTK backend's `gtk_main()` not pumping libdispatch's main queue. `Task { @MainActor in … }` queues onto an executor nothing is draining, so the body never fires (symptom: webview attaches but the page never navigates). Keep the `MainThread.run` dispatcher hook (a hidden `HWND_MESSAGE` window posting `WM_APP+1` with a heap-boxed closure) alive for any UI-thread hop, even when the compiler suggests rewriting to `Task { @MainActor }` to satisfy a sending-risk diagnostic — instead, use `nonisolated(unsafe)` on the captured pointer locals.

## [0.1.0] - 2026-05-04

### Added

- Platform-agnostic `SwiftPWACore`: `CommandRegistry`, `Invocation` envelope, `Window` / `PWAWebView` / `AppRuntime` protocols, `Plugin` model, built-in `WindowPlugin` exposing the `window.*` JS command set.
- Apple `SwiftPWAWebKit` backend (macOS 15+, iOS 18+) with `WKWebView`, `pwa://` scheme handler, UIScene multi-window scaffolding. JS↔Swift bridge round-trip verified end-to-end on the iOS 26 Simulator.
- Linux `SwiftPWAGTK` backend, two parallel implementations selected at build time via the `SWIFT_PWA_GTK4` environment variable: GTK3 + WebKitGTK 4.1 (default, `CGtk3Shim` + `CWebKitGTK4Shim`) for older distros, and GTK4 + WebKitGTK 6.0 (`CGtk4Shim` + `CWebKitGTK6Shim`) for modern ones. Both export the same `SwiftPWAGTK` Swift module name and class API; the GTK4 backend uses `GtkShortcutController` for Ctrl+Q and `notify::default-width/-height` for resize tracking, since `GtkAccelGroup` and `configure-event` were removed in GTK4. Position APIs (`Window.position()` / `setPosition` / `.didMove`) are no-ops on GTK4 because Wayland and CSD removed the concept; the protocol now documents this as best-effort.
- `MainThread.run` abstraction in core: routes "run on UI thread" through a registerable platform hook (`DispatchQueue.main` on Apple, `g_idle_add` on GTK) so the bridge runtime works under `gtk_main()`, where Swift's MainActor executor is otherwise un-pumped.
- `swift-pwa` CLI: `init`, `dev`, `build` for macOS `.app` (with optional `--sign`), iOS `.ipa` / simulator `.app` (via `xcodebuild`), Linux `.AppImage` (via `linuxdeploy`). Windows / Android targets are stubs.
- AppImage bundler: writes a placeholder PNG icon if `pwa.json.icon` isn't a PNG so `linuxdeploy` doesn't hang on its prompt path.
- `__SWIFT_PWA__.invoke()` / `subscribe()` JS runtime injected at document start; uniform Tauri-style envelope (`{v, kind, id, cmd, payload}`).
- Test support target (`_SwiftPWATestSupport`) with reusable `MockWindow` / `MockWebView` / `MockAppContext`.
- 34-test suite (Swift Testing): envelope codec, `JSONValue`, `CommandRegistry`, `AssetProvider`, `WindowPlugin`, `BridgeRuntime` end-to-end, real-`WKWebView` integration, `PWAManifest`, `InfoPlist`.
- GitHub Actions CI matrix: macos-15 (build + test + WKWebView integration), ios-build (xcodebuild against the iOS Simulator SDK), ubuntu-24.04 (Core + CLI), swiftformat lint. Tag-driven release workflow that ships CLI binaries.
- [docs/linux-setup.md](docs/linux-setup.md) walkthrough for Ubuntu 24.04.

### Fixed

- Linux `evaluateJavaScript` is no longer fire-and-forget. The GTK adapter now bridges `webkit_web_view_evaluate_javascript`'s `GAsyncResult` callback back into a Swift `CheckedContinuation` via the new `swiftpwa_evaluate_javascript` shim. The result is the JSON serialization of the JS value (`jsc_value_to_json`) — `undefined` resolves to `nil`, and WebKit-side errors throw `BridgeError(code: E_HANDLER)`.
- Linux backend now emits `WindowEvent.didResize` / `.didMove` for user-driven window-manager resizes and moves (hooked via GTK `configure-event`), matching the Mac `NSWindowDelegate` plumbing.
- Linux backend now wires Ctrl+Q (the GNOME HIG quit shortcut) to `GTKAppContext.quit` via a window-level `GtkAccelGroup`, hooks `delete-event` so user-clicked [X] / Alt+F4 runs the same teardown as a programmatic `close()`, and quits the GLib main loop when the last window closes — Linux convention vs Mac's "menu bar lingers". The Ctrl+Q wiring matches the existing macOS Cmd+Q path installed by the app menu.
- iOS bundler now assembles the `.app` itself from xcodebuild's loose products. SwiftPM executable targets compile to a bare Mach-O, not a bundle, so the previous code never found the `.app` it was looking for and failed every build with `expected built binary at …`.
- iOS `Info.plist` no longer ships `$(PRODUCT_MODULE_NAME).SwiftPWASceneDelegate` as a literal string (Xcode-only build-setting variable); resolved to `SwiftPWAWebKit.SwiftPWASceneDelegate`.
- iOS `Info.plist` now declares `UILaunchScreen` so the app doesn't run in legacy compatibility letterbox mode on modern devices.
- `swift-pwa init` scaffolds `Sources/<Name>/App.swift` instead of `main.swift`, so the templated `@main` struct compiles (the `main.swift` filename forces top-level-script mode).

### Notes

- `CommandRegistry` is a class with `NSLock`-guarded state, not an actor. Registration is synchronous so user `configure` closures can run on a thread that isn't pumping Swift's MainActor executor (e.g. the main thread before `gtk_main()` enters its loop).
- `BridgeRuntime` is *not* `@MainActor`. Backends are responsible for hopping to the platform UI thread internally.
