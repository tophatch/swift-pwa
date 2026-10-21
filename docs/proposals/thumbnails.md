# Proposal: `fs.thumbnail` — a file's thumbnail from the platform, without its bytes

Status: **implemented** (#320), 2026-10-21 — shape and platform-thumbnails-only
as accepted; Linux runs the desktop's `.thumbnailer` entries itself instead of
asking tumbler, because the GNOME box had no tumbler at all (see the table).

## The problem

An app showing a shelf of documents needs a cover per document. Off Apple there
is no thumbnailer in the app, so the page renders one itself — pdf.js drawing
page one from the served file. For a file on local disk that's merely slow. For
a file in a cloud folder it's a download: an Android Drive document is fetched
whole the first time any range of it is read (measured in #320: 64 KB from the
tail of a 47 MB PDF cost **49 MB** received and 2.7 s). A gallery of series
covers downloads every series' first chapter.

Yet the platform can usually draw that cover without the file. The system
picker shows Drive thumbnails at once: a cloud provider renders them server-side
and hands them out on request. The same is true of every platform we ship on, in
its own way. What's missing is a way for the page to ask.

There is no web API for this, so it's a new command rather than a filled-in
standard one.

## Proposed API

```js
const { image } = await __SWIFT_PWA__.invoke('fs.thumbnail', { path, maxSize: 256 });
// image: { dataBase64, mimeType: 'image/png', width, height } — or null
if (image) cover.src = `data:${image.mimeType};base64,${image.dataBase64}`;
```

```swift
// Fs, with a default that returns nil, so existing implementations compile
func thumbnail(path: String, maxSize: Int) async throws -> FsThumbnail?
```

- **`null`, not an error, when there is no thumbnail.** Most providers and most
  file types have none, and that's the normal case a page falls back from (its
  own renderer, a generic cover). An error is for a path that doesn't exist or
  can't be read.
- **`maxSize` is a bound, not a promise.** A provider answers with the size it
  has: Drive's provider gave macOS 128×128 when asked for 512. The reply says
  what came back.
- **Never downloads the document.** That's the point of the call, so a platform
  path that would need the bytes returns `null` rather than fetching them. A
  local file is different: its bytes are already here, and drawing one is the
  platform's own thumbnailer's job.
- **Base64 PNG in the reply.** A thumbnail is tens of KB; a URL scheme for them
  would be one more thing served, cached and invalidated, for no gain at this
  size.

## Per platform

| Platform | Source | Cloud file without download | Measured |
|---|---|---|---|
| macOS | `QLThumbnailGenerator`, `.thumbnail` representations only (never the icon) | **Yes**: Drive for desktop files evicted to dataless gave Drive's 128×128 page crop in 0.6–0.8 s and stayed dataless | `Scripts/verify-thumbnail.sh --folder` |
| iOS | `QLThumbnailGenerator`, same | **Yes**: iCloud Drive files not on the device gave full page-one thumbnails in ~1 s and stayed not downloaded | `Scripts/verify-thumbnail.sh --target ios` |
| Android | The provider (`loadThumbnail` / `getDocumentThumbnail`) only with `FLAG_SUPPORTS_THUMBNAIL`; `ThumbnailUtils` and `PdfRenderer` for a local file | **Yes**: a 40 MB Drive PDF never opened → page-one thumbnail for 12.5 KB received (control: 44 MB for 64 KB of it) | `Scripts/verify-android-thumbnail.sh` |
| Windows | `IShellItemImageFactory::GetImage(SIIGBF_THUMBNAILONLY)` | **null, no download**: the shell answers `WTS_E_DATAFILEUNAVAILABLE` for a OneDrive placeholder. No PDF thumbnailer without a reader that installs one | `Scripts\verify-thumbnail-windows.ps1 -OneDrive` |
| Linux | The freedesktop cache (validated by `Thumb::URI`/`Thumb::MTime`), then the `.thumbnailer` entry for the type, stored back to the cache; cache only on a FUSE/network mount | Cache only (no GVFS Drive mount on the boxes to measure) | `Scripts/verify-thumbnail.sh` on both boxes |

Measuring turned up one thing outside the API: on Windows, listing a OneDrive
folder with `fs.readDir` downloaded every file in it, because
swift-corelibs-foundation opens a file to stat it. Fixed alongside (see the
CHANGELOG).

## What the measurement has to show before this ships

For each platform, with a control:

1. A local PDF and a local image give a thumbnail (the control that the
   instrument works).
2. A cloud document that isn't local gives a thumbnail **and is still not
   local afterwards** (`dataless` on Apple, the placeholder state on Windows,
   received bytes on Android), or the platform returns `null` — never a
   download.
3. A type with no thumbnailer returns `null`, not an error.

## Decisions (accepted)

1. **The shape above** — `fs.thumbnail({ path, maxSize })` → `{ image }` with a
   base64 PNG or `null`.
2. **Only the platform's thumbnails**, never a renderer of our own. A page that
   wants a cover where the platform has none keeps its own fallback.
3. **Linux best-effort**: cache, then tumbler when present, else `null` —
   documented in the platform doc rather than worked around.
