# Proposal: `fs.thumbnail` — a file's thumbnail from the platform, without its bytes

Status: **accepted** (#320), 2026-10-21 — shape, platform-thumbnails-only and
Linux best-effort as below. Built only after the per-platform measurement.

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

| Platform | Source | Cloud file without download | Status |
|---|---|---|---|
| macOS | `QLThumbnailGenerator`, `.thumbnail` representations only (never the icon) | **Yes, measured**: a 7.3 MB PDF in a Google Drive for desktop folder, not downloaded (`dataless`), gave a 128×128 page-one thumbnail in ~1 s (10 ms cached) and stayed `dataless` | measured |
| iOS | `QLThumbnailGenerator`, same | To measure: an iCloud Drive file not on the device; a file in a picked folder | to measure |
| Android | `content://`: `ContentResolver.loadThumbnail` (API 29+), `DocumentsContract.getDocumentThumbnail` (28), only when the document has `FLAG_SUPPORTS_THUMBNAIL`. A local path: `ThumbnailUtils` for images and video, `PdfRenderer` page one for a PDF | To measure: a Drive PDF never opened, received bytes counted as in #320 | to measure |
| Windows | `IShellItemImageFactory::GetImage` with `SIIGBF_THUMBNAILONLY`; with `SIIGBF_INCACHEONLY` first for a cloud placeholder | To measure: a OneDrive placeholder; and whether Windows 11 thumbnails a PDF at all without a third-party handler | to measure |
| Linux | The freedesktop thumbnail cache (GIO's `thumbnail::path`), then the thumbnailer D-Bus service (tumbler) where one runs; `null` otherwise | To measure on both boxes: is tumbler present; what a GVFS Drive mount gives | to measure |

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
