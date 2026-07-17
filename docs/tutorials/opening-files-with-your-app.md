# Opening files with your app (file associations)

**Who this is for:** you want your app to be what the OS launches when someone double-clicks a `.foo` file, picks it in **Open With**, or shares a file to your app. Two halves: **declare** which types you handle (so the OS routes them to you), and **receive** the opened file in your web code.

Assumes you've met the bridge — see [Talking to the native side](talking-to-the-native-side.md).

> Uses swift-pwa **0.9+**. The association is generated on every platform — macOS/iOS via the `info_plist` passthrough, Android via `android.document_types`, Linux via `linux.document_types`, Windows via `windows.document_types`.

---

## The receiving half — one event, everywhere

Whenever the OS opens a file with your app, swift-pwa emits it on the `app.openFile` channel. Subscribe once, early:

```js
__SWIFT_PWA__.on('app.openFile', ({ paths }) => {
  for (const path of paths) openDocument(path);
});
```

The payload is `{ paths: string[] }` — usually one file, but a multi-select "Open With" or a share can send several.

**It's cold-start safe.** The event is emitted *retained*, so a file that **launched** your app (the app wasn't running yet) is replayed to your listener the moment you subscribe — you won't miss it just because your JS hadn't loaded when the OS handed over the file. (One consequence: a manual page reload re-subscribes and re-receives the launch file.)

Then read it with the file plugin — the path is a real filesystem path on desktop/iOS and a `content://` URI on Android, but `fs.*` handles both transparently:

```js
async function openDocument(path) {
  const { dataBase64 } = await __SWIFT_PWA__.invoke('fs.readBinary', { path });
  // or: const { contents } = await __SWIFT_PWA__.invoke('fs.readText', { path });
  render(dataBase64);
}
```

> On the macOS/iOS App Sandbox, swift-pwa holds the security-scoped grant for the session, so the handed-over path stays readable via `fs.*` — you don't need to do anything special.

---

## The declaring half — tell the OS what you handle

### macOS & iOS

Declare `CFBundleDocumentTypes` through the `info_plist` passthrough in `pwa.json` (there's no dedicated schema field — you inject the plist keys directly):

```json
"macos": {
  "info_plist": {
    "CFBundleDocumentTypes": [
      {
        "CFBundleTypeName": "My Project File",
        "CFBundleTypeRole": "Editor",
        "LSItemContentTypes": ["com.example.myapp.project", "public.json"]
      }
    ]
  }
}
```

Use the same block under `"ios": { "info_plist": { … } }`. (For a brand-new custom extension you'd also declare a `UTExportedTypeDeclarations` entry, but for common types like `public.json` / `public.png` the `LSItemContentTypes` above is enough.)

### Android

Use the `android.document_types` key — swift-pwa turns it into `VIEW` / `SEND` / `SEND_MULTIPLE` intent filters on your launcher activity:

```json
"android": {
  "document_types": [
    { "mime_types": ["application/json", "image/*"] }
  ]
}
```

Wildcards like `"image/*"` work. Omit the key and your app only opens from the launcher.

### Linux

Linux associates by **MIME type**. Use the `linux.document_types` key — swift-pwa adds a `MimeType=` line to the generated `.desktop` entry *and* the `%F` field code to its `Exec=` line (so the desktop environment passes the opened file's path, which reaches `app.openFile`):

```json
"linux": {
  "document_types": [
    { "mime_types": ["application/json", "image/png"] }
  ]
}
```

### Windows

Windows associates by **file extension**. Use the `windows.document_types` key:

```json
"windows": {
  "document_types": [
    { "extensions": [".myapp", ".json"], "name": "MyApp Document" }
  ]
}
```

- For an **MSIX** build (`--package-format msix`), this becomes a `<uap:FileTypeAssociation>` in the generated `AppxManifest.xml`, and the OS registers the association when the package installs.
- For a **portable** `.exe`, there's no installer, so the bundler drops `register-file-types.cmd` (and `unregister-file-types.cmd`) next to the exe. Run it once — it writes per-user (`HKCU`) associations pointing at the exe *at its current location*. (Extensions are normalized: `"MyApp"`, `".myapp"`, `"myapp"` all mean `.myapp`.)

---

## Try it

Rebuild and install a real bundle (associations don't apply to `swift-pwa dev`):

- **macOS:** `swift-pwa build --target macos`, then `open -a build/MyApp.app somefile.json` (or right-click a file → Open With). Both cold launch and warm (app already running) route to `app.openFile`.
- **Android:** build/install, then open a matching file from Files or share one to your app.
- **Linux:** build the AppImage, install its `.desktop` (or run `xdg-mime default`), then open a matching file from your file manager.
- **Windows:** install the MSIX, or run `register-file-types.cmd` from the portable folder, then double-click a matching file.

---

## Where to go next

- [Saving and loading files](saving-and-loading-files.md) — the `dialog.*` + `fs.*` side (letting users pick files from *within* your app).
- [JavaScript API](../javascript-api.md) — the `app.openFile` and `fs.*` references.
- [Shipping your app](shipping-your-app.md) — bundling (required for associations to take effect) and the per-platform Info.plist / manifest details.
