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
const { os, commands, tempDir } = await __SWIFT_PWA__.invoke('__platform.info');
if (commands.includes('biometric.authenticate')) { /* show the unlock button */ }
```

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

### `clipboard.*`

```js
await __SWIFT_PWA__.invoke('clipboard.writeText', { text: 'copied!' });
const { text } = await __SWIFT_PWA__.invoke('clipboard.readText');
await __SWIFT_PWA__.invoke('clipboard.clear');
```

`clear()` wipes on Apple; on X11 / Wayland it only relinquishes local
ownership of the selection.

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

const { path } = await __SWIFT_PWA__.invoke('dialog.saveFile',
    { defaultName: 'report.pdf' });

const { path: dir } = await __SWIFT_PWA__.invoke('dialog.openDirectory');
```

`dialog.saveFile` is a stub on iOS (the platform has no system save
panel — apps export through `UIDocumentPickerViewController(forExporting:)`
or `UIActivityViewController` instead). GTK4 dialogs require GTK 4.10+.

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

// Text-to-image (when info.imageGeneration).
const { images } = await __SWIFT_PWA__.invoke('ai.generateImage', {
    prompt: 'a watercolor fox', steps: 20, outputDirectory: dataDir + '/gen',
});
// streaming variant: subscribe('ai.generateImageStream', …) for step progress
```

`ai.generateJSON` always returns schema-valid JSON regardless of backend
(native schema-constrained decoding where available, otherwise a
prompt-and-validate fallback), and composes with vision (`images` +
`schema`). Errors carry stable codes (`E_AI_UNAVAILABLE`,
`E_AI_GENERATION`, `E_AI_STRUCTURED_OUTPUT`). In 0.7 the contract is in
place but no on-device backend is wired yet, so `ai.info` reports
`available: false` until one lands. Full reference, backend protocol, and
roadmap: [docs/ai-plugin.md](ai-plugin.md).

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
