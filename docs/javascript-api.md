# JavaScript API

The `__SWIFT_PWA__` object is injected at document-start by `bridge.js`,
so every command call works before user JS loads. Two primitives —
unary `invoke` and streaming `subscribe` — cover every plugin.

```js
// Unary: returns a Promise.
const result = await __SWIFT_PWA__.invoke(commandName, payload);

// Streaming: returns an unsubscribe function. The callback fires on
// every yielded chunk; `end` and errors are surfaced internally.
const unsub = __SWIFT_PWA__.subscribe(commandName, payload, (chunk) => {
    /* ... */
});
unsub();
```

The wire envelope (`{v, kind, id, cmd, payload}`) is identical across
WKWebView, WebKitGTK, and WebView2 — same JS code runs unchanged on
every backend.

To discover what's actually wired up at runtime — which opt-in plugins
the Swift side installed, plus any custom commands — call `__platform.info`.
It returns the live command list so the page can feature-detect instead
of guessing:

```js
const info = await __SWIFT_PWA__.invoke('__platform.info');
// { os, commands, tempDir, physicalMemoryBytes, appMemoryLimitBytes }
if (info.commands.includes('biometric.authenticate')) { /* show the unlock button */ }
```

`physicalMemoryBytes` is the total device RAM (exact and uncapped — a strictly
better signal than `navigator.deviceMemory`, which is quantized, capped at 8 GB,
and absent in WKWebView/iOS). `appMemoryLimitBytes` is the per-app ceiling where
the OS defines one (Android's large-heap class), else `null`. Both are static
for the session; for a live "available now" read and a memory-pressure event,
see [`system.*`](#system).

## Built-in plugins (auto-installed on every backend)

### `window.*`

```js
const { id }     = await __SWIFT_PWA__.invoke('window.id');
const { ids }    = await __SWIFT_PWA__.invoke('window.list');
await __SWIFT_PWA__.invoke('window.setTitle',      { title: 'Hello' });
const { title }  = await __SWIFT_PWA__.invoke('window.title');
await __SWIFT_PWA__.invoke('window.setSize',       { width: 1024, height: 768 });
const { width, height } = await __SWIFT_PWA__.invoke('window.size');
await __SWIFT_PWA__.invoke('window.setPosition',   { x: 100, y: 100 });
const { x, y }   = await __SWIFT_PWA__.invoke('window.position');
await __SWIFT_PWA__.invoke('window.focus');
await __SWIFT_PWA__.invoke('window.minimize');
await __SWIFT_PWA__.invoke('window.maximize');
await __SWIFT_PWA__.invoke('window.setFullscreen', { on: true });
const { isFullscreen } = await __SWIFT_PWA__.invoke('window.isFullscreen');
await __SWIFT_PWA__.invoke('window.close');

// Streaming: didFocus / didBlur / didResize / didMove / didMinimize /
// didDeminiaturize / didEnterFullscreen / didExitFullscreen / willClose.
const unsub = __SWIFT_PWA__.subscribe('window.subscribe', {}, (event) => {
    console.log(event.type, event);
});
```

`Window.position()` / `setPosition` / `.didMove` are no-ops on the GTK4
backend (Wayland refuses to give apps their own position).

### `app.*`

Process-level lifecycle and identity — the things `window.*` deliberately
doesn't cover. `window.close` closes a *window*; `app.quit` exits the
whole process (on macOS, closing the last window leaves the app alive in
the menu bar, so a "Quit" button wants `app.quit`).

```js
await __SWIFT_PWA__.invoke('app.quit');              // clean exit (code 0)
await __SWIFT_PWA__.invoke('app.quit', { exitCode: 1 });
const { value: name }    = await __SWIFT_PWA__.invoke('app.name');
const { value: version } = await __SWIFT_PWA__.invoke('app.version');

const { value: dataDir }  = await __SWIFT_PWA__.invoke('app.dataDir');
const { value: cacheDir } = await __SWIFT_PWA__.invoke('app.cacheDir');
```

`app.name` / `app.version` read the bundle's `Info.plist`
(`CFBundleDisplayName` / `CFBundleShortVersionString`). `name` falls back
to the process name when no bundle is present; `version` is the empty
string on hosts without an `Info.plist` (Linux / Android).

`app.dataDir` / `app.cacheDir` return the platform's per-app **persistent**
and **disposable** writable directories (created on first call) —
`~/Library/Application Support/<bundle-id>` and `~/Library/Caches/<bundle-id>`
on macOS, the XDG data/cache dirs on Linux, `%APPDATA%` / `%LOCALAPPDATA%`
on Windows, the Activity `filesDir` / `cacheDir` on Android. `dataDir` is
where you extract a downloaded content pack (see `fs.extractZip`); the OS
may evict `cacheDir` at any time, so only put regenerable artifacts there.

#### `app.openFile` — OS "Open With" / launch-with-file

When the OS launches (or foregrounds) your app *with* a document — Finder /
Explorer "Open With", `open -a MyApp file`, a file double-clicked on a type
your app handles — the file path(s) arrive as a **server-push event** on the
`app.openFile` channel. Subscribe with `on` (see [`events.*`](#events--server-initiated-push)):

```js
__SWIFT_PWA__.on('app.openFile', ({ paths }) => {
    for (const path of paths) openDocument(path);   // e.g. read via fs.readBinary
});
```

Key points:

- **Cold-start safe.** The most common case is *the file launches the app*, so
  the open event fires before the WebView (and this listener) exists. The event
  is emitted **retained**, so it replays to your listener as soon as you
  subscribe — you never miss the launch file. (Consequence: a manual page reload
  re-subscribes and re-receives the launch file; ignore a repeat if that matters.)
- **Payload** is `{ paths: string[] }` — selecting multiple files in one "Open
  With" delivers them as one event.
- **macOS sandbox.** A file handed over by Launch Services is readable via
  `fs.readBinary` — the runtime holds the security-scoped grant for the session,
  so no extra step is needed on your side.

You still have to **declare** which file types your app handles (the event only
fires for a launch the OS routes to you, or an explicit `open -a`). On Apple that
goes through the `info_plist` passthrough (see [macos-setup.md](macos-setup.md)):

```json
"macos": { "info_plist": { "CFBundleDocumentTypes": [
    { "CFBundleTypeName": "Image", "CFBundleTypeRole": "Viewer",
      "LSItemContentTypes": ["public.png", "public.jpeg"] }
] } }
```

Platform coverage: **macOS** (`application(_:open:)`) and **iOS**
(`scene(_:openURLContexts:)`, including cold-launch) via Launch Services;
**Linux** and **Windows** via the launch file-argument convention (`.desktop`
`Exec=… %F` / file-association argv); and **Android** via `ACTION_VIEW` /
`ACTION_SEND` intents (declare the handled MIME types with
[`android.document_types`](android-setup.md#file-associations-androiddocument_types),
which generates the intent-filters). On Android `paths` are `content://` URIs —
read them with `fs.readBinary` the same way; the URI's read grant is held for
the launching activity's lifetime.

### `system.*`

Device / OS facts that aren't application identity (`app.*`) or window state
(`window.*`). Auto-installed on every backend.

```js
const m = await __SWIFT_PWA__.invoke('system.memory');
// { physicalBytes, availableBytes, appLimitBytes, lowMemory }
if (m.availableBytes != null && m.availableBytes < 256 * 1024 * 1024) {
    shrinkCaches();   // running low right now
}
```

`system.memory` is a **live, point-in-time** read (unlike the static totals on
`__platform.info`), so call it on a debounce before growing a cache — not per
frame. Fields:

- `physicalBytes` — total device RAM (same as `__platform.info`'s
  `physicalMemoryBytes`).
- `availableBytes` — allocatable right now, or `null` where the platform gives
  no portable signal. **On iOS this is the remaining per-app headroom before the
  OS jetsams you** (`os_proc_available_memory()`) — the number a memory-scaled
  cache actually wants — which is why iOS reports it here and leaves
  `appLimitBytes` `null`.
- `appLimitBytes` — the per-app OS ceiling (Android's large-heap class), else
  `null` (desktop, iOS).
- `lowMemory` — the OS's own "under pressure" flag on Android
  (`MemoryInfo.lowMemory`); a heuristic (`availableBytes` below ~⅛ of physical)
  elsewhere.

#### `system.memoryPressure` — shed caches before you're killed

The OS asking your app to free memory *before* it kills the process. A
server-push event on the [`events.*`](#events--server-initiated-push) bus:

```js
__SWIFT_PWA__.on('system.memoryPressure', ({ level }) => {
    // level ∈ 'warning' | 'critical'
    shrinkCaches(level);   // e.g. drop to LOD-only, force-drain LRUs
});
```

Platform coverage: **iOS / macOS** via `DispatchSource.makeMemoryPressureSource`,
**Android** via `onTrimMemory` (`RUNNING_LOW`/`RUNNING_MODERATE` → `warning`,
`RUNNING_CRITICAL`/`COMPLETE` → `critical`). **Linux and Windows have no portable
signal, so the event never fires there** — treat it as best-effort and always
also size caches from `system.memory` so you degrade gracefully where there's no
pressure feed.

### `clipboard.*`

```js
await __SWIFT_PWA__.invoke('clipboard.writeText', { text: 'copied!' });
const { text } = await __SWIFT_PWA__.invoke('clipboard.readText');
await __SWIFT_PWA__.invoke('clipboard.clear');
```

`clear()` wipes on Apple; on X11 / Wayland it only relinquishes local
ownership of the selection.

### `events.*` — server-initiated push

A runtime-owned event bus for events the client *didn't* explicitly request —
a file appeared, an import finished, a background job progressed. Swift pushes
on a named channel and every subscriber (in every window) receives it. Two
convenience helpers wrap the `events.*` commands:

```js
// Subscribe to a channel. `on` returns an unsubscribe function.
const off = __SWIFT_PWA__.on('library:changed', (payload) => {
    console.log('library changed', payload);
});

// Publish from JS. Fans out to every subscriber in every window, so it
// doubles as a cross-window message bus.
await __SWIFT_PWA__.emit('ui:theme', { dark: true });

// A retained channel replays its latest value to subscribers that connect
// later — no more "subscribed too late and missed the event".
await __SWIFT_PWA__.emit('job:progress', { pct: 40 }, { retain: true });

off(); // stop listening
```

The Swift side pushes with `ctx.emit('library:changed', payload)` — see
[swift-api.md](swift-api.md#server-push-events). `on` / `emit` are thin sugar
over `subscribe('events.subscribe', …)` / `invoke('events.emit', …)`; the raw
commands are available if you need them.

## Opt-in plugins (require `ctx.use(...)` on the Swift side)

### `dialog.*`

```js
await __SWIFT_PWA__.invoke('dialog.message',
    { title: 'Heads up', message: 'Saved.', kind: 'info' });

const { ok } = await __SWIFT_PWA__.invoke('dialog.confirm',
    { message: 'Discard changes?',
      okLabel: 'Discard', cancelLabel: 'Keep editing' });

const { paths } = await __SWIFT_PWA__.invoke('dialog.openFile', {
    filters: [{ name: 'Images', extensions: ['png', 'jpg'] }],
    multiple: false,
});

// saveFile returns a destination path you then write to yourself
// (desktop + Android). It's a no-op on iOS — use exportFile there.
const { path } = await __SWIFT_PWA__.invoke('dialog.saveFile',
    { defaultName: 'report.pdf' });

// exportFile is "save this content" — you hand it the bytes, it lets the
// user pick a location and writes them for you. Works on every platform,
// including iOS. Supply exactly one of `dataBase64` or `path`:
const { path: saved } = await __SWIFT_PWA__.invoke('dialog.exportFile', {
    defaultName: 'report.csv',
    dataBase64: btoa('a,b,c\n1,2,3\n'),
    filters: [{ name: 'CSV', extensions: ['csv'] }],
});
// or export a file already on disk (e.g. one you wrote via fs.*):
// await __SWIFT_PWA__.invoke('dialog.exportFile', { path: '/…/report.csv' });

// Single directory (backward-compatible `path`), or several with `multiple`:
const { path: dir } = await __SWIFT_PWA__.invoke('dialog.openDirectory');
const { paths: dirs } = await __SWIFT_PWA__.invoke('dialog.openDirectory',
    { multiple: true });
```

`dialog.openDirectory` returns both `paths` (every selected directory) and
`path` (the first, kept for callers written before multi-select landed).
`multiple` is desktop-only — macOS / Windows / GTK / iOS honor it; on Android
the SAF tree picker grants one directory per launch, so at most one path comes
back.

**`dialog.saveFile` vs `dialog.exportFile`.** `saveFile` returns a *destination
path you then write to* — natural on desktop and Android, but a no-op on iOS
(returns `null`), which has no "pick a location, get a writable path" panel.
`exportFile` is the *content-first* counterpart: you pass the bytes (`dataBase64`)
or a source file (`path`), the platform's save/export UI lets the user choose a
location, and the backend does the write — returning the destination
(a filesystem path on desktop, the picked file's path on iOS, a `content://`
URI on Android) or `null` if cancelled. `exportFile` is the portable "let the
user save this" primitive and the **recommended** way to save on iOS. Provide
exactly one of `dataBase64` / `path`. GTK4 dialogs require GTK 4.10+.

### `fs.*`

```js
await __SWIFT_PWA__.invoke('fs.writeText',   { path, contents: 'hi' });
const { contents } = await __SWIFT_PWA__.invoke('fs.readText', { path });

await __SWIFT_PWA__.invoke('fs.writeBinary', { path, dataBase64: '...' });
const { dataBase64 } = await __SWIFT_PWA__.invoke('fs.readBinary', { path });

const { exists } = await __SWIFT_PWA__.invoke('fs.exists',   { path });
await __SWIFT_PWA__.invoke('fs.mkdir',    { path, recursive: true });
await __SWIFT_PWA__.invoke('fs.remove',   { path, recursive: true });
const { entries } = await __SWIFT_PWA__.invoke('fs.readDir', { path });
await __SWIFT_PWA__.invoke('fs.copy',     { from, to });
await __SWIFT_PWA__.invoke('fs.rename',   { from, to });
const meta = await __SWIFT_PWA__.invoke('fs.metadata', { path });
// → { size, isDir, isFile, modified }   // modified: ms since epoch, may be null
```

`FsPlugin` does not enforce a path scope. Apps that need a sandbox
should layer it themselves — typically by gating writes behind
`dialog.openFile` so the user grants paths through the picker.

**Zip extraction (content packs)** — available only when an archive
extractor is injected: `ctx.use(FsPlugin(SystemFs(extractor: ZIPExtractor())))`
(import `SwiftPWAArchive`). Bytes never cross the bridge — extraction is
path-to-path:

```js
// Peek the central directory before committing to a multi-GB extract:
const { entries } = await __SWIFT_PWA__.invoke('fs.listZip', { from });
// → entries: [{ path, isDirectory, isSymlink, uncompressedSize, compressedSize }]

// Extract (optional zip-bomb guards; omitted → safe defaults):
const r = await __SWIFT_PWA__.invoke('fs.extractZip', {
    from, to,
    maxUncompressedBytes, maxEntries, maxCompressionRatio  // all optional
});
// → { entries, uncompressedBytes }

// Or stream progress for a big extract:
const unsub = __SWIFT_PWA__.subscribe('fs.extractZipProgress', { from, to }, (e) => {
    if (e.type === 'progress') updateBar(e.entriesDone, e.totalEntries);
    else if (e.type === 'done') done(e.entries);
});
```

Path-traversal and symlink entries are rejected, and the zip-bomb guards
(uncompressed-size / entry-count / compression-ratio) abort with the
output cleaned up. A typical flow: `dialog.openFile` → `fs.extractZip`
into `app.dataDir()` → reference the media via a
[`serveDirectory`](swift-api.md#serving-extra-directories-content-packs)
mount. Available on macOS / iOS / Linux / Android (Windows: pending).

On **Android**, `dialog.openFile` returns a `content://` SAF URI, and you can
pass it straight to `fs.listZip` / `fs.extractZip` as `from` — they read it
via the system `ContentResolver`, so a user-picked archive extracts off-bridge
with no `readBinary`/`writeBinary` materialize step. (The destination `to` must
still be a real path under `app.dataDir()`; SAF exposes no writable tree.)

**Zip creation (authoring / re-exporting a pack)** — the inverse of
`fs.extractZip`, gated on the same injected extractor. For the common
case (a small pack) build the `.zip` in the browser as a `Blob`; reach for
`fs.createZip` only when the pack is too big to zip in memory (a multi-GB
folder of video) — bytes stay off the bridge, path-to-path:

```js
// Zip a folder (e.g. an authored pack, or an already-installed pack whose
// source is a folder under app.dataDir() the browser can't re-fetch):
const r = await __SWIFT_PWA__.invoke('fs.createZip', {
    from, to,                 // from: source dir, to: output .zip path
    compression: 'stored'     // 'stored' (default) | 'deflate'
});
// → { entries, uncompressedBytes }

// Or stream progress for a big archive:
const unsub = __SWIFT_PWA__.subscribe('fs.createZipProgress', { from, to }, (e) => {
    if (e.type === 'progress') updateBar(e.entriesDone, e.totalEntries);
    else if (e.type === 'done') done(e.entries);
});
```

Default `compression` is `'stored'` — pack media (png / webm / jpg / mp4)
is already compressed, so deflate burns CPU for ~0% gain. Use `'deflate'`
for compressible (text-like) payloads. Symlinks in the source are skipped
(not followed, not stored), and a failed create leaves no partial `.zip`.

### `tray.*`

```js
await __SWIFT_PWA__.invoke('tray.setIcon',    { path: '/path/to/icon.png' });
await __SWIFT_PWA__.invoke('tray.setTooltip', { text: 'My app' });
await __SWIFT_PWA__.invoke('tray.setMenu',    { items: [
    { id: 'show', label: 'Show window' },
    { id: '',     label: '', separator: true },
    { id: 'quit', label: 'Quit', enabled: true },
]});
await __SWIFT_PWA__.invoke('tray.setVisible', { visible: true });

const unsub = __SWIFT_PWA__.subscribe('tray.subscribe', {}, (event) => {
    // event.type === 'click' | 'menuItemClicked'
});
```

No-op stub on iOS and the GTK4 backend (no available system tray).
`TrayEvent.click` is macOS-only — the freedesktop StatusNotifierItem
spec gives the desktop panel ownership of click semantics on Linux.

### `notifications.*`

```js
const { granted } = await __SWIFT_PWA__.invoke('notifications.requestAuthorization');
if (granted) {
    await __SWIFT_PWA__.invoke('notifications.send', {
        title: 'Build complete', body: 'Done in 4.3s', sound: true,
    });
}
```

Apple platforms require a bundled, signed app — `UNUserNotificationCenter`
raises an `NSException` from a process without a `CFBundleIdentifier`.
The plugin pre-flights and throws a clean `BridgeError` instead of
crashing, but actual banners only appear after `swift run swift-pwa
build --target macos` (or via Xcode).

### `biometric.*`

```js
const status = await __SWIFT_PWA__.invoke('biometric.canAuthenticate');
// → { available, kind, reason? }
//   kind ∈ {none, touchID, faceID, opticID, windowsHello, unknown}

if (status.available) {
    const { authenticated, error } = await __SWIFT_PWA__.invoke(
        'biometric.authenticate', { reason: 'Unlock the journal' });
}
```

User cancellation reports `authenticated: false` with `error:
"cancelled"` (or platform-equivalent string) rather than throwing.
System-level errors (no sensor, lockout, policy disabled) propagate as
`BridgeError`. Linux is a stub that always reports `available: false`.

### `updater.*`

```js
// One-shot probe.
const info = await __SWIFT_PWA__.invoke('updater.check');
if (info) console.log(`Update available: ${info.version}`);

// Streaming flow — typical "show update UI" pattern.
const unsub = __SWIFT_PWA__.subscribe('updater.run', null, (event) => {
    switch (event.type) {
        case 'checking':         /* show spinner */ break;
        case 'available':        /* event.info.version, event.info.notes */ break;
        case 'upToDate':         /* hide spinner */ break;
        case 'downloadProgress': /* event.bytesDownloaded, event.contentLength */ break;
        case 'readyToInstall':
            __SWIFT_PWA__.invoke('updater.installAndRelaunch');
            break;
        case 'error':            /* event.code, event.message */ break;
    }
});

// Streaming install — surfaces the platform's post-commit lifecycle.
// On desktop backends the stream finishes silently (the running
// process is replaced before any event could be observed); on
// Android it relays `PackageInstaller.STATUS_*` broadcasts.
const unsubInstall = __SWIFT_PWA__.subscribe('updater.install', null, (event) => {
    switch (event.type) {
        case 'installCommitted': /* OS install prompt is on screen */ break;
        case 'installSucceeded': /* very brief on Android — system replaces process */ break;
        case 'installFailed':    /* event.code (e.g. "STATUS_FAILURE_ABORTED"), event.message */ break;
        case 'error':            /* the commit itself failed */ break;
    }
});
```

See [docs/auto-updates.md](auto-updates.md) for the manifest format
and the runtime install path on each backend, and
[docs/android-setup.md §6.1.2](android-setup.md#612-observing-the-updater-install-result)
for the Android-specific `updater.install` lifecycle.

### `ai.*`

On-device (or otherwise native) LLM inference, so the page stays
provider-agnostic. Probe once at startup and route on `available`.

```js
const info = await __SWIFT_PWA__.invoke('ai.info', {});
// → { available, backend, model?, streaming, structuredOutput }
if (!info.available) { /* fall back to your own (e.g. cloud) tier */ }

// One-shot structured generation — returns a parsed, schema-valid object.
const obj = await __SWIFT_PWA__.invoke('ai.generateJSON', {
    system: '…', prompt: '…',
    schema: { type: 'object', required: ['summary'] },
});

// Streaming text — `delta` chunks, then a terminal `done`.
__SWIFT_PWA__.subscribe('ai.generateStream', { prompt }, (e) => {
    if (e.type === 'delta') appendToken(e.text);
});

// Vision (when info.vision): attach images to any text command.
await __SWIFT_PWA__.invoke('ai.generate', {
    prompt: 'Describe this.', images: [{ path: '/photo.jpg' }],
});

// Image gen/edit — one command, operation chosen by which fields you send.
// Text→image (when info.imageGeneration):
const { images } = await __SWIFT_PWA__.invoke('ai.generateImage', {
    prompt: 'a watercolor fox', steps: 20, outputDirectory: dataDir + '/gen',
});
// Inpaint (when info.imageEditing) — image + mask (white = edit), prompt optional:
await __SWIFT_PWA__.invoke('ai.generateImage', {
    image: { path: '/photo.jpg' }, mask: { path: '/mask.png' },
    outputDirectory: dataDir + '/edited',
});
// streaming variant: subscribe('ai.generateImageStream', …) for step progress

// Audio in (when info.audioInput) — e.g. phoneme evaluation from a recording.
const score = await __SWIFT_PWA__.invoke('ai.generateJSON', {
    prompt: 'Score this pronunciation.', audio: [{ path: '/utterance.wav' }],
    schema: { type: 'object', required: ['overallScore'] },
});
// Audio out (when info.audioGeneration) — TTS.
const { audio } = await __SWIFT_PWA__.invoke('ai.generateAudio', { prompt: 'kiitos' });
// streaming variant: subscribe('ai.generateAudioStream', …) for play-as-it-arrives

// Per-request voice cloning (when info.voiceCloning) — clone from a reference
// clip + its transcript. The reference rides on the request, so it can change
// per call (a user-switchable voice) with no backend re-init.
const { audio: cloned } = await __SWIFT_PWA__.invoke('ai.generateAudio', {
    prompt: 'kiitos',
    referenceAudio: { path: '/voices/narrator.wav' }, // or { dataBase64 }
    referenceText: 'the transcript of the reference clip',
});
```

`ai.generateJSON` always returns schema-valid JSON regardless of backend
(native schema-constrained decoding where available, otherwise a
prompt-and-validate fallback), and composes with multimodal `images` /
`audio` input + `schema`. Errors carry stable codes (`E_AI_UNAVAILABLE`,
`E_AI_GENERATION`, `E_AI_STRUCTURED_OUTPUT`). In 0.7 the contract is in
place but no on-device backend is wired yet, so `ai.info` reports
`available: false` until one lands. Full reference, backend protocol, and
roadmap: [docs/ai-plugin.md](ai-plugin.md).

### `ai.run` / `ai.describeInputs` — run an imported workflow at runtime

`ai.generateImage` above has a *fixed* field set. `ai.run` is the open door:
the web app hands a provider **a graph and a connection per call** and runs it —
no rebuild per workflow or per endpoint. The surface is **provider-agnostic**,
routed on a `provider` id: a *graph* provider (**ComfyUI** — any "Save (API
Format)" graph the app imported, endpoint + graph in the call) and *fixed-schema*
providers (**Imagen** cloud, **on-device** Stable Diffusion / LaMa, or a
**config-driven** `RESTImageProvider` for an arbitrary cloud API — Gemini image /
OpenAI / Qwen, chosen by a descriptor) answer the same `describeInputs` → controls
→ `run` loop. Opt-in on the Swift side with a list of providers:
`ctx.use(AIWorkflowPlugin(providers: [ComfyUIWorkflowProvider(), imagenProvider, RESTImageProvider(providerID: "gemini-image", spec: .geminiImage()), AIBackendWorkflowProvider(providerID: "on-device", backend: sd)], client: …, secrets: …))`.

```js
// 1. Ask the provider what the graph's overridable inputs are. For ComfyUI this
//    crosses the graph's literal (widget) inputs with the box's /object_info, so
//    each field gets a real type / range / combo options — no hand-written map.
const schema = await __SWIFT_PWA__.invoke('ai.describeInputs', {
    provider: 'comfyui',
    connection: { baseURL: 'http://my-nas.local:8188' },
    graph: importedGraphJSON,        // object or string; omit for fixed providers
    // titledOnly: true              // graph providers: only author-titled inputs
});
// schema.inputs: [{ key, label, type, value, min?, max?, step?, options?, group?, isImage }]
//   type: 'text' | 'int' | 'float' | 'bool' | 'enum' | 'image' | 'mask' | 'seed'
//   key:  an opaque handle you send run values under — "<nodeID>/<inputName>" for ComfyUI.
// schema.degraded === true ⇒ the box was unreachable, so it's a graph-only
//   schema (widget-derived types, no ranges/options); values still run.

// 2. Run it, streaming progress → image(s) → done. `inputs` is keyed by the
//    schema's `key`; an image/mask value is { dataBase64 } or { path }, uploaded
//    by the provider before the run. A `seed` of null randomizes per run.
const stop = __SWIFT_PWA__.subscribe('ai.run', {
    provider: 'comfyui',
    connection: {
        baseURL: 'http://my-nas.local:8188',
        headers: {},                 // open bag — reverse-proxy tokens, custom auth
        // secretRef: 'my-api-key',   // resolved server-side against secrets.* into ${secret} headers
    },
    graph: importedGraphJSON,
    inputs: {
        '6/text': 'a red panda astronaut',
        '10/image': { dataBase64: '…' },   // a reference / control image
        '3/seed': null,                     // randomized per run, echoed back
    },
    // outputDirectory: dataDir + '/runs',  // omit ⇒ images come back as dataBase64
}, (e) => {                          // onChunk
    if (e.jobId) lastJobId = e.jobId;                                // remember for recovery (below)
    if (e.type === 'progress') updateBar(e.value, e.max, e.stage);   // value/max fine when available
    if (e.type === 'image')    show(e.image, e.width, e.height);     // image: { dataBase64|path, mimeType, seed }
    if (e.type === 'done')     markDone();
}, (err) => showError(err),          // onError
   () => finish());                  // onEnd
// cancel: stop()  → the provider interrupts the running job (ComfyUI POST /interrupt).

// Recovery: every event carries a `jobId` once the job is submitted. If the
// stream is torn down (e.g. the app was backgrounded and a poll failed),
// re-issue ai.run with that id — no graph/inputs — to re-attach: the provider
// checks the box's /history + /queue and resumes streaming, or returns the
// finished outputs, or errors fast if the id is gone.
__SWIFT_PWA__.subscribe('ai.run', { provider: 'comfyui', connection, jobId: lastJobId }, onChunk, onError, onEnd);
```

Progress is coarse (`stage: 'queued' → 'running'`) plus per-step `value`/`max`
when the provider can stream it (ComfyUI over `/ws`; a fixed provider emits a
single `running` then the image). `secretRef` is resolved against
[`secrets.*`](#secrets--secure-secret-storage) **on the Swift side**, so key
material never enters the page. A unary `invoke('ai.run', …)` form also works
for callers that don't need progress.

**Fixed-schema providers (Imagen, on-device).** These have no graph and don't
reach a per-call endpoint, so `connection` is **optional** — omit it. Same
schema shape, same event stream; there's just less to send:

```js
const schema = await __SWIFT_PWA__.invoke('ai.describeInputs', { provider: 'imagen' });
//   → [{ key: 'prompt', type: 'text' }, { key: 'aspectRatio', type: 'enum', options: [...] },
//      { key: 'count', type: 'int', min: 1, max: 4 }, { key: 'seed', type: 'seed' }, …]
const stop = __SWIFT_PWA__.subscribe('ai.run', {
    provider: 'imagen',                     // or 'on-device'
    inputs: { prompt: 'a red panda astronaut', aspectRatio: '16:9', count: 1, seed: null },
}, onChunk, onError, onEnd);
// `jobId` / recovery is a graph-provider (ComfyUI) affordance only.
```

Deep dive + the Swift `runWorkflow` / `inspectWorkflow` primitives:
[docs/remote-ai.md](remote-ai.md).

### `ai.vision.*` — promptable on-device image segmentation

Unrelated to `ai.info`'s `vision` flag above (that's *generative* backends
accepting image input, e.g. "describe this photo"). `ai.vision.*` is a
**separate**, *discriminative* contract — SAM-family models turning an
image + a spatial prompt (point/box) into object masks — installed via its
own `VisionPlugin`, not `AIPlugin`. Encoding an image is the expensive
step, so it's a session: open once per image, then decode (segment) many
times cheaply against the cached embedding.

```js
const info = await __SWIFT_PWA__.invoke('ai.vision.info', {});
// → { available, backend, model?, pointPrompts, boxPrompts, multimask,
//     autoMask, maxImageSize, sessionCaching }
if (!info.available) { /* hide the ML object-select affordance */ }

// Open a session — runs the (expensive) encoder. Prefer `path` over
// `dataBase64` for doc-sized images so the bytes don't cross the bridge.
const { sessionId, width, height } = await __SWIFT_PWA__.invoke(
    'ai.vision.openSession', { image: { path: dataDir + '/layer-cache.png' } }
);

// Segment at a prompt — runs the (cheap) decoder. Coordinates are in
// source-image pixels (the dims openSession returned).
const { masks } = await __SWIFT_PWA__.invoke('ai.vision.segment', {
    sessionId, points: [{ x: 120, y: 84, label: 1 }], multimask: true,
});
// masks: [{ bounds: [x0, y0, x1, y1], rle: [...], score }], best-first

await __SWIFT_PWA__.invoke('ai.vision.closeSession', { sessionId });
```

Each mask's `rle` is a row-major run-length encoding over its `bounds` box
(first run = background pixel count) — compact for many-mask results and
trivial to decode into a bitmap. Errors carry stable codes
(`E_VISION_UNAVAILABLE`, `E_VISION_SESSION` for an unknown/evicted
`sessionId`, `E_VISION_SEGMENTATION`, `E_VISION_MODEL` for a failed
`ensureModel` download). `ai.vision.ensureModel` (subscribe) streams
`AIDownloadEvent` frames — a single aggregate `progress` bar then a terminal
`done` — the same shape as `ai.ensureModel` for the llama model; call it once
before the first `ai.vision.openSession` when using a downloadable backend
(`MobileSAMBackend(cacheDirectory:)`).

**Automatic mask generation** (`autoMask: true` backends, e.g. `MobileSAMBackend`)
segments *every* object at once — a grid-of-prompts sweep + non-max-suppression:

```js
// Streaming (recommended — a full sweep is many decoder passes):
__SWIFT_PWA__.subscribe('ai.vision.segmentAllStream',
    { sessionId, pointsPerSide: 16, iouThreshold: 0.88, minAreaPx: 16 },
    (e) => {
        if (e.type === 'progress') setBar(e.done, e.total);
        else if (e.type === 'done') useMasks(e.masks); // same [{bounds,rle,score}] shape
    });
// Unary ai.vision.segmentAll returns the final masks in one reply (small images).
```

`pointsPerSide` (default 16, capped at 32) sets grid density; `iouThreshold`
(default 0.88) is the NMS dedup threshold; `minAreaPx` drops specks. Masks come
back best-score-first.

**Device-capability timing** (`autoMask: true` backends) — `ai.vision.benchmark`
runs a synthetic encode + decode + small AMG sweep and returns
`{ encodeMs, decodeMs, segmentAllMs, deviceClass }` (`deviceClass` is a coarse
`'high'`/`'mid'`/`'low'` bucket). Use it for a one-shot capability gate — though
timing your own first real `openSession`/`segment` and caching the verdict is
cheaper and more representative of your actual images.

```js
const b = await __SWIFT_PWA__.invoke('ai.vision.benchmark', {});
if (b.deviceClass === 'high') enableSegmentEverythingUX();
```

A real backend (`MobileSAMBackend`, all platforms — Apple/Android/Linux/Windows,
verified against real weights) exists as of this writing, but isn't
auto-installed — an app must opt in via `ctx.use(VisionPlugin(...))` and either
bundle weights or use the downloadable tier (see the `mobilesam-vendor` GitHub
Release), so `ai.vision.info` reports `available: false` until then. See
[docs/proposals/segmentation-plugin.md](proposals/segmentation-plugin.md)
for the full design, current implementation status, and the ONNX Runtime
packaging work underway.

### `process.*` — subprocesses (desktop only)

Launch and manage an external child process: stream its stdout/stderr, feed
its stdin, and have it torn down automatically when the page goes away. This is
the escape hatch for wrapping an existing CLI/daemon — a converter, an indexer,
a local model server, or an out-of-process TTS synthesizer. Register it Swift-
side with `ctx.use(ProcessPlugin(SystemProcess()))`.

```js
// Spawn + stream. The first frame is `spawned` (with the pid); then `stdout`
// / `stderr` (base64 bytes), then a terminal `exit`.
let pid;
const off = __SWIFT_PWA__.subscribe('process.stream',
    { command: 'python3', args: ['tts.py'], cwd: '/app', env: { RATE: '24000' } },
    (frame) => {
        if (frame.type === 'spawned') pid = frame.pid;
        else if (frame.type === 'stdout') playPCM(atob(frame.dataBase64));
        else if (frame.type === 'exit')   console.log('exited', frame.code);
    });

// Feed stdin (base64), optionally closing it to signal EOF.
await __SWIFT_PWA__.invoke('process.write',
    { pid, dataBase64: btoa('speak this\n'), closeStdin: false });

// Terminate explicitly (SIGTERM)…
await __SWIFT_PWA__.invoke('process.kill', { pid });
// …or just `off()` — unsubscribing (or closing the window) kills the child.
```

**Guaranteed teardown.** A child's lifetime is bound to its `process.stream`
subscription: unsubscribe, or close the owning window, and the child is
terminated — orphaned children can't happen. **Desktop only** (macOS / Linux /
Windows); on iOS / Android the sandbox forbids spawning and `process.stream`
fails with `E_UNIMPLEMENTED`. Full reference and security notes:
[docs/process-plugin.md](process-plugin.md).

### `net.*` — native HTTP (all platforms)

A native, **CORS-free** HTTP client — the counterpart to `fetch`, but on the
Swift side, so it isn't bound by the WebView's same-origin/CORS policy, can set
headers a page can't (`Authorization`, custom `User-Agent`), and reaches LAN
appliances and non-CORS APIs. Register it Swift-side with the platform client:
`ctx.use(NetPlugin(URLSessionNetworkClient()))` (desktop/Apple) or
`ctx.use(NetPlugin(AndroidNetworkClient()))` (Android).

```js
// Unary request. Body rides as base64 both ways. A non-2xx is a `status`, not
// an error — only a transport failure rejects (E_NET).
const res = await __SWIFT_PWA__.invoke('net.request', {
    method: 'POST',                       // default 'GET'
    url: 'https://api.example.com/v1/thing',
    headers: { Authorization: 'Bearer …' },
    bodyBase64: btoa(JSON.stringify({ hello: 'world' })),
    timeoutMs: 30000,                     // default 60000
});
if (res.status === 200) console.log(atob(res.bodyBase64));

// Stream a download to a native path (big payloads skip the base64 bridge).
const off = __SWIFT_PWA__.subscribe('net.download',
    { url: 'https://example.com/big.bin', destPath: '/path/big.bin', sha256: 'abcd…' },
    (frame) => {
        if (frame.type === 'progress') updateBar(frame.bytesDownloaded, frame.totalBytes);
        else if (frame.type === 'done') console.log('wrote', frame.path);
    });
```

**Opt-in** (arbitrary outbound requests from native are powerful). On **Android**,
plain `http://` to a LAN host also needs the host allow-listed via
`android.network.cleartext_domains` in `pwa.json` (HTTPS needs nothing). Full
reference: [docs/net-plugin.md](net-plugin.md).

### `secrets.*` — secure secret storage

Store small secrets — an API token, a sync credential, a license key — in the
**operating system's secure store** (Keychain on Apple, Keystore-backed
`EncryptedSharedPreferences` on Android, DPAPI on Windows, the Secret Service on
Linux) instead of `localStorage` or a plaintext file. Register it Swift-side
with the platform store:
`ctx.use(SecretsPlugin(KeychainSecretStore()))` (Apple),
`ctx.use(SecretsPlugin(AndroidSecretStore()))` (Android).

```js
// Store / read / delete. Values are strings (base64 for binary).
await __SWIFT_PWA__.invoke('secrets.set',    { key: 'google-ai', value: 'sk-…' });

const { value } = await __SWIFT_PWA__.invoke('secrets.get', { key: 'google-ai' });
// value: string | null — a missing key is `null`, NOT an error.

await __SWIFT_PWA__.invoke('secrets.delete', { key: 'google-ai' }); // idempotent
```

A missing key returns `{ value: null }`; a store failure (unavailable, access
denied) rejects with `E_SECRETS`. **Opt-in** — reaching the OS keychain is a
capability an app enables explicitly. The framework never persists a secret for
you; this is a thin, audited bridge to the OS store. Common pairing: a remote
`AIBackend`'s API-key closure reads straight through it —
`ImagenProvider(apiKey: { try? await store.get("google-ai") })`. Full reference
and the per-platform store table: [docs/secrets.md](secrets.md).

## Custom commands

The Swift side can register arbitrary commands; JS calls them through
the same `invoke` / `subscribe` surface:

```swift
await ctx.registry.register("my.greet") { (args: GreetArgs, _) in
    "hello, \(args.name)"
}
```

```js
const greeting = await __SWIFT_PWA__.invoke('my.greet', { name: 'Ada' });
```

See [docs/swift-api.md](swift-api.md) for the registration side.
