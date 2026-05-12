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

## Built-in plugins (auto-installed on every backend)

### `window.*`

```js
const { id }     = await __SWIFT_PWA__.invoke('window.id');
const { ids }    = await __SWIFT_PWA__.invoke('window.list');
await __SWIFT_PWA__.invoke('window.setTitle',      { title: 'Hello' });
const { title }  = await __SWIFT_PWA__.invoke('window.title');
await __SWIFT_PWA__.invoke('window.setSize',       { width: 1024, height: 768 });
const { size }   = await __SWIFT_PWA__.invoke('window.size');
await __SWIFT_PWA__.invoke('window.setPosition',   { x: 100, y: 100 });
const { pos }    = await __SWIFT_PWA__.invoke('window.position');
await __SWIFT_PWA__.invoke('window.focus');
await __SWIFT_PWA__.invoke('window.minimize');
await __SWIFT_PWA__.invoke('window.maximize');
await __SWIFT_PWA__.invoke('window.setFullscreen', { fullscreen: true });
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

await __SWIFT_PWA__.invoke('fs.writeBinary', { path, base64: '...' });
const { base64 } = await __SWIFT_PWA__.invoke('fs.readBinary', { path });

const { exists } = await __SWIFT_PWA__.invoke('fs.exists',   { path });
await __SWIFT_PWA__.invoke('fs.mkdir',    { path, recursive: true });
await __SWIFT_PWA__.invoke('fs.remove',   { path, recursive: true });
const { entries } = await __SWIFT_PWA__.invoke('fs.readDir', { path });
await __SWIFT_PWA__.invoke('fs.copy',     { src, dst });
await __SWIFT_PWA__.invoke('fs.rename',   { src, dst });
const meta = await __SWIFT_PWA__.invoke('fs.metadata', { path });
// → { size, isDir, isFile, modifiedMillis }
```

`FsPlugin` does not enforce a path scope. Apps that need a sandbox
should layer it themselves — typically by gating writes behind
`dialog.openFile` so the user grants paths through the picker.

### `tray.*`

```js
await __SWIFT_PWA__.invoke('tray.setIcon',    { path: '/path/to/icon.png' });
await __SWIFT_PWA__.invoke('tray.setTooltip', { tooltip: 'My app' });
await __SWIFT_PWA__.invoke('tray.setMenu',    { items: [
    { id: 'show',  label: 'Show window'  },
    { id: 'quit',  label: 'Quit', accelerator: 'Cmd+Q' },
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
        title: 'Build complete', body: 'Done in 4.3s', sound: 'default',
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
