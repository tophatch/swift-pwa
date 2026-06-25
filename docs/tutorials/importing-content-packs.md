# Importing content packs (extract a zip, serve its media)

**Who this is for:** your app lets users bring their own content — a downloadable "pack" of images and video, a level bundle, a theme — shipped as a `.zip` that can be **hundreds of megabytes or more**. You want the user to import one at runtime, and then show its media (`<img>`, `<video>`) in the page.

You don't need to know Swift. This tutorial has you paste **one short JavaScript file** and **a few clearly-marked lines of Swift** into the project `swift-pwa` generates for you.

The two things that make this work — and that a plain browser can't do for gigabyte files — are:

1. **Native extraction** (`fs.extractZip`): the zip is unpacked **straight to disk**, entry by entry. The bytes never pass through JavaScript, so a 2 GB pack doesn't try to become a 2.7 GB base64 string in a tab that then crashes.
2. **Serving the extracted files** (`ctx.serveDirectory`): the unpacked folder is exposed on your app's own origin under a path you choose (e.g. `/packs`), so page code references a clip as `"/packs/my-pack/clip.webm"` — and it **streams** with HTTP range requests, so a long video seeks instantly instead of buffering the whole thing.

> Needs swift-pwa **0.6.3 or newer**. Works on macOS, iOS, Linux, Windows, and Android.

---

## The big picture

```
Your web app (JavaScript)                    The native shell (Swift)
  ┌─ user picks a .zip (Open dialog) ───────────────────────────────────┐
  │   ask the shell to extract it to disk  ──▶  fs.extractZip            │
  │     (progress events stream back)      ◀──  …writes files entry-by-  │
  │                                              entry, never via JS      │
  │   set videoEl.src = "/packs/<id>/clip.webm"                          │
  │     the shell serves it from disk      ──▶  ctx.serveDirectory       │
  │     with range support                 ◀──  206 Partial Content      │
  └──────────────────────────────────────────────────────────────────────┘
```

You wire the **mount** once (Swift, at startup). After that, every pack the user extracts into it is instantly viewable — no extra Swift call per pack.

---

## Step 1 — the native setup (a few lines of Swift, once)

In the generated `Sources/<YourApp>/App.swift`, inside the `configure` closure, do three things: pick a zip extractor, enable the `Fs` plugin with it, and mount a folder to serve.

```swift
import SwiftPWA
#if !os(Android)
    import SwiftPWAArchive   // ZIPExtractor (ZIPFoundation / tar.exe)
#endif

@MainActor
func configure(_ ctx: any AppContext) throws {
    // 1. Choose the extractor for this platform. (ZIPFoundation can't build
    //    on Android, so there it routes to Kotlin's java.util.zip instead.)
    #if os(Android)
        let extractor: any ArchiveExtractor = AndroidArchiveExtractor()
    #else
        let extractor: any ArchiveExtractor = ZIPExtractor()
    #endif
    ctx.use(FsPlugin(SystemFs(extractor: extractor)))

    // 2. Make a folder in the app's data dir and serve it at "/packs".
    let packs = ctx.dataDirectory().appendingPathComponent("packs", isDirectory: true)
    try? FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    ctx.serveDirectory(packs, at: "/packs")

    // …your existing createWindow(...) call stays as-is.
}
```

That's the whole native side. `ctx.dataDirectory()` is a per-app, writable, persistent folder (`app.dataDir()` from JS is the same path).

### Android needs one extra line in `pwa.json`

On Android the web-asset server is built before any Swift runs, so a startup mount has to be **declared** in `pwa.json` as well (the desktop `serveDirectory` call above still applies everywhere):

```json
"build": {
  "serve": [
    { "mount": "/packs", "from": "data/packs" }
  ]
}
```

`from: "data/packs"` means "the `packs` folder inside the app's data dir" — the same folder the Swift code mounts. (`cache/…` would root it in the cache dir instead.)

---

## Step 2 — the JavaScript (pick → extract → show)

Paste this wherever your "Import pack" button lives. It uses `dialog.openFile` to pick the zip, `fs.extractZip` (with a progress bar) to unpack it, then points an `<img>`/`<video>` at the served path.

```js
async function importPack() {
  // 1. Let the user pick a .zip (native file picker).
  const picked = await __SWIFT_PWA__.invoke("dialog.openFile", {
    filters: [{ name: "Content pack", extensions: ["zip"] }],
  });
  const zipPath = picked.paths?.[0];
  if (!zipPath) return; // user cancelled

  // 2. (Optional) Peek inside before committing to a big extract.
  const { entries } = await __SWIFT_PWA__.invoke("fs.listZip", { from: zipPath });
  const manifest = entries.find((e) => e.path === "pack.json");
  if (!manifest) { alert("Not a valid pack — no pack.json"); return; }

  // 3. Extract into our served folder, streaming progress.
  const dataDir = (await __SWIFT_PWA__.invoke("app.dataDir")).value;
  const dest = `${dataDir}/packs/my-pack`;
  await new Promise((resolve, reject) => {
    const unsub = __SWIFT_PWA__.subscribe(
      "fs.extractZipProgress",
      { from: zipPath, to: dest },
      (e) => {
        if (e.type === "progress") {
          setProgress(e.totalEntries ? e.entriesDone / e.totalEntries : 0);
        } else if (e.type === "done") { unsub(); resolve(); }
        else if (e.type === "error") { unsub(); reject(new Error(e.message)); }
      },
    );
  });

  // 4. Show the media — origin-relative URL, served from disk, range-streamed.
  document.querySelector("#preview").src = `/packs/my-pack/clip.webm`;
}
```

Prefer a one-shot extract without progress? Drop the subscription and call:

```js
const { entries, uncompressedBytes } =
  await __SWIFT_PWA__.invoke("fs.extractZip", { from: zipPath, to: dest });
```

That's it. The `<video src="/packs/my-pack/clip.webm">` (or `<img>`) loads from the extracted files, and the shell answers range requests so seeking is instant.

---

## You get the safety guards for free

The zip comes from outside your app, so `fs.extractZip` enforces, by default:

- **Path traversal** — an entry named `../../etc/passwd` is rejected; everything lands inside your destination.
- **Symlinks** — rejected (they could point outside the destination).
- **Zip bombs** — caps on total uncompressed size, entry count, and per-entry compression ratio (8 GiB / 50 000 entries / 200:1 by default), so a tiny malicious zip can't fill the disk. Override per call: `{ from, to, maxUncompressedBytes, maxEntries, maxCompressionRatio }`.

A failed or aborted extract cleans up after itself — you never end up serving a half-unpacked pack.

---

## Notes

- **Serving is read-only.** `/packs/…` only *reads* files. To write, use `fs.writeText` / `fs.writeBinary` with a real path under `app.dataDir()`.
- **Pick any prefix.** `/packs` is just an example; use `/library`, `/levels`, anything that isn't a path your bundled site already uses.
- **No browser fallback.** Unlike the [file save/load tutorial](saving-and-loading-files.md), this is a native-shell capability — `fs.extractZip` / `serveDirectory` don't exist in a plain browser tab. Gate the "Import pack" UI on `__platform.info.commands.includes("fs.extractZip")` so it only shows in the packaged app.

For the full reference, see the [`fs.*` section of the JavaScript API](../javascript-api.md#fs) and [Serving extra directories in the Swift API](../swift-api.md#serving-extra-directories-content-packs). The design rationale lives in [docs/design/runtime-content-packs.md](../design/runtime-content-packs.md).
