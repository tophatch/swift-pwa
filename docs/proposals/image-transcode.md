# Proposal: Image transcode plugin (`image.*`)

> **Status: proposed**, from adopter feedback. Prompted by a reader app that
> wanted to serve a folder of iPhone photos and found HEIC unusable — see the
> `## [Unreleased]` HEIC/AVIF entry in [CHANGELOG.md](../../CHANGELOG.md), which
> records the measurements this proposal builds on.
>
> The MIME half of that report is fixed and shipped. This is the other half: the
> declared type was never what stopped the picture appearing.

## The problem

**HEIC renders in exactly one of the four webviews this project ships on.**
Measured by driving a scaffolded app serving real HEIC and AVIF files:

| Engine | HEIC | AVIF | How it was measured |
|---|---|---|---|
| WKWebView (macOS, iOS) | renders | renders | `<img>`, blob URL and `createImageBitmap`, all at full size |
| WebKitGTK 4.1 / 6.0 | **never** | **never** | `naturalWidth: 0`, blob URL broken, `InvalidStateError`; PNG fine in the same page |
| WebView2 (Chromium) | **never** | renders | same page, same fixtures |
| Android `WebView` | **never** | renders | same page on a Galaxy Z Fold7 (Android 16) over CDP |

WebKitGTK's failure is structural, not a codec-negotiation problem: neither the
6.0 nor the 4.1 build that distros ship links `libheif` or `libavif` (they carry
JPEG XL instead), so there is no decoder to reach at any declared MIME type.
Chromium has AVIF and no HEIC.

So an app that accepts photos from a user's filesystem — the iCloud Drive folder
case, where **every** photo an iPhone writes is HEIC — either ships Apple-only or
transcodes on import. Today the framework offers nothing for the second path, and
an adopter's only options are to write per-platform native code (exactly the work
swift-pwa exists to absorb) or to refuse the format.

## The insight: we already decode HEIC on two platforms

`SwiftPWAImageIO`'s `ImageCodec` — decode→RGB, encode→PNG — is `package`-internal
today, used by `LaMaBackend` (inpainting) and `StableDiffusionBackend`. Its
per-platform decoders are not equal:

| Platform | `ImageCodec` uses | Decodes HEIC/AVIF? |
|---|---|---|
| Apple | `CGImageSourceCreateWithURL` (ImageIO) | **yes, today** — measured, both at full size; ImageIO will *encode* both too |
| Android | `BitmapFactory` over the Kotlin `image.decode` RPC | **yes, measured** — HEIC and AVIF both decoded 240×240 and re-encoded to PNG on a Fold7 |
| Linux / Windows | vendored `stb_image` | **no** — stb does JPEG/PNG/TGA/BMP/PSD/GIF/HDR/PIC/PNM and contains no HEIC or AVIF code at all |

The decoder an adopter needs is therefore already compiled into their Apple and
Android builds, reachable from Swift, and simply not exposed to the page. That is
a "we haven't", not a "the platform can't" — and the project's standing rule is
that the first kind gets closed.

## What the platforms can do that their webviews can't

| Platform | Webview renders HEIC | Platform can decode HEIC | Via |
|---|---|---|---|
| Apple | yes | yes | ImageIO — already wired |
| Android | no | **yes — measured** | BitmapFactory — already wired |
| Windows | no | **yes — measured** | WIC, but see below |
| Linux | no | not without a new dependency | `libheif`/`libavif` present on both test boxes, unlinked |

**Windows is real but cannot be promised.** WIC decoded both HEIC and AVIF on the
x64 test box via `System.Windows.Media.Imaging.BitmapDecoder`. That box has
`Microsoft.HEIFImageExtension`, `Microsoft.HEVCVideoExtension` and
`Microsoft.AV1VideoExtension` installed. HEIC is HEVC-coded and the HEVC
extension is the paid/OEM-supplied one, so a bare Windows install may not decode
HEIC at all. Any Windows support must be **capability-reported at runtime**, never
advertised statically.

## JS API

Two commands, mirroring the shape of `net.*` and `secrets.*` (opt-in plugin,
injected backend):

```js
// What can this build actually do? Ask before relying on it — the answer is
// per-platform and, on Windows, per-machine.
const info = await __SWIFT_PWA__.invoke('image.info');
// { decode: ["heic","heif","avif","jpeg","png",…], encode: ["png","jpeg"] }

// Decode anything the platform can read, re-encode as something every webview
// can render. Source and destination are both path-or-inline, like ai.*.
const out = await __SWIFT_PWA__.invoke('image.transcode', {
    path: '/Users/x/Photos/IMG_0001.HEIC',   // or dataBase64
    to: 'jpeg',                              // 'png' | 'jpeg'
    maxSide: 2048,                           // optional downscale, as ImageCodec already does
    quality: 0.85,                           // jpeg only
    outputPath: '/…/cache/IMG_0001.jpg',     // optional; omit for dataBase64 back
});
// { path } or { dataBase64 }, plus { width, height }
```

`maxSide` is not decoration: `LaMaBackend` already learned that decoding a
24-megapixel phone photo at full resolution is ~72 MB per buffer and OOMs the
Android JNI RPC payload, which is why `ImageCodec.decodeRGBFit` and
`maxWorkingSide` exist. A transcode surface that ignored size would rediscover
that on the first real photo library.

An unsupported format fails as `E_UNSUPPORTED` naming the format and the platform
— the same rule as the permission refusals: the error tells you what to do, and
never silently returns a broken image.

## Scope for v1

**Phase 1 — Apple + Android, no new dependencies.** Make a narrow public API over
the existing `ImageCodec` (or a thin public wrapper; `ImageCodec` itself stays
`package`), add `ImagePlugin(ImageCodecBackend)`, wire `image.info` from what the
platform actually reports rather than a hard-coded list. Android's Kotlin side
already has `image.decode` / `image.encodePng` handlers, so the RPC is in place.
Desktop returns `E_UNSUPPORTED` for HEIC/AVIF honestly.

This alone covers the reporting adopter's deployment (iPad) and Android — most of
the value for a fraction of the work.

**Phase 2 — Windows via WIC.** An in-box COM API, so no third-party dependency,
but a new decoder path in the shim and genuine per-machine capability reporting.

**Phase 3 — Linux via `libheif`/`libavif`.** The only cell that is a real new
system dependency. Best as an opt-in build flag in the shape of
`ai.local_onnx_runtime` rather than a hard requirement, because it adds
`-dev` packages at build time, AppImage bundling, and CI provisioning in several
places — the `libsecret` change is the precedent for how much that costs.

## Verification

Phase 1 is not done until a real HEIC from a real phone round-trips on a real
device — a scaffolded app, not an Example. Concretely: transcode → serve the
output → assert the page's `naturalWidth` is non-zero on the engine that
refused the original. The fixtures and the driven page from the HEIC/AVIF
measurement above are reusable as-is.

## Alternatives considered

**Do nothing; adopters transcode themselves.** They can, but only by writing the
per-platform native code this framework exists to absorb, and only after
discovering the engine matrix above — which took real hardware on three engines
to establish and is not documented anywhere else.

**Bundle a decoder (`libde265` / `dav1d`) for guaranteed support everywhere.**
This is the only option that makes HEIC work on a bare Windows and on Linux with
no system packages. It is also a sizeable third-party dependency in a
dependency-averse project, and HEVC carries patent questions that a "just add a
decoder" framing hides. Not the place to start; revisit only if phases 1–3 leave
a gap someone actually hits.

**Transcode in the page on a canvas.** Where the webview renders the format,
`drawImage` + `toBlob('image/png')` needs no native code at all — a genuinely
useful trick, and the right immediate answer for an Apple-only app. It is also
exactly backwards for this problem: it works only on the engine that already
worked, and not on the three that need help.

## Open questions

1. ~~Android's two unverified rows.~~ **Settled on a Galaxy Z Fold7 (Android 16,
   API 36).** Its `WebView` renders AVIF and not HEIC, as Chromium does
   elsewhere; `BitmapFactory` decodes **both**, and a full decode→encode round
   trip through the existing `image.decode` / `image.encodePng` RPCs returned
   240×240 and a valid PNG for each. So Android is exactly the shape this
   proposal is for — the webview cannot show the file, the platform underneath
   it can, and the plumbing is already generated into every app. Phase 1 covers
   Apple *and* Android as hoped. (Verified by calling the RPCs straight from a
   scaffolded app: `AndroidRPC` is public and the umbrella re-exports it, so no
   framework change was needed to test it.)
2. **Should `image.*` also expose plain resize / re-encode** for formats that
   already render? It falls out of the same code, and thumbnail generation is
   what an importing app is doing anyway — but it widens a capability surface
   beyond the problem that justified it.
3. **Android does honour the MIME table** — `image/heic` and `image/avif` were
   served correctly there (measured), unlike Windows, whose bundle bypasses it.
   Not a question so much as a note for whoever writes phase 1's tests.

4. **Does the Windows bundle path even matter here?** On Windows the bundle is
   served natively by `SetVirtualHostNameToFolderMapping`, so Chromium picks the
   Content-Type and our table is bypassed (measured). A transcode output written
   to a served directory sidesteps that entirely — but see the unrelated
   `serveDirectory` bug noted during the same session.
