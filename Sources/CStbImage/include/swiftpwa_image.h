// A deliberately tiny image-decode surface for the desktop segmentation
// backend (Linux/Windows, which have no CoreGraphics / BitmapFactory). Wraps
// the vendored public-domain stb_image (v2.30) so Swift sees only these two
// functions rather than stb's full API. See Sources/CStbImage/swiftpwa_image.c.
#ifndef SWIFTPWA_IMAGE_H
#define SWIFTPWA_IMAGE_H

// Decode an encoded image (PNG/JPEG/etc.) from an in-memory buffer into a
// freshly allocated tightly-packed RGB8 buffer (`*width * *height * 3` bytes,
// row-major, no alpha). Returns NULL on failure. Free the result with
// swiftpwa_free_image. `data`/`len` are the encoded bytes.
unsigned char *swiftpwa_decode_image_rgb(const unsigned char *data, int len,
                                         int *width, int *height);

// Free a buffer returned by swiftpwa_decode_image_rgb.
void swiftpwa_free_image(unsigned char *pixels);

// Like swiftpwa_decode_image_rgb, but keeps the alpha channel: decodes into a
// tightly-packed RGBA8 buffer (`*width * *height * 4` bytes, row-major). Sources
// without alpha decode with alpha = 255. Used by the Windows multi-size icon
// builder, which must preserve transparency when down-rendering the app icon.
// Free the result with swiftpwa_free_image.
unsigned char *swiftpwa_decode_image_rgba(const unsigned char *data, int len,
                                          int *width, int *height);

// Encode tightly-packed RGB8 pixels (`width * height * 3` bytes, row-major) to
// an in-memory PNG. Returns a freshly allocated buffer (free with
// swiftpwa_free_png) and writes its byte length to *out_len; returns NULL on
// failure. Used by SwiftPWAImageEdit's desktop ImageCodec (Linux/Windows have
// no CoreGraphics PNG encoder).
unsigned char *swiftpwa_encode_png_rgb(const unsigned char *pixels, int width,
                                       int height, int *out_len);

// Encode tightly-packed RGB8 pixels to an in-memory JPEG at `quality` (1-100).
// Returns a freshly allocated buffer (free with swiftpwa_free_png) and writes
// its byte length to *out_len; returns NULL on failure. stb only exposes a
// callback-based JPEG writer, so this accumulates into a growing buffer.
unsigned char *swiftpwa_encode_jpg_rgb(const unsigned char *pixels, int width,
                                       int height, int quality, int *out_len);

// Free a buffer returned by swiftpwa_encode_png_rgb or swiftpwa_encode_jpg_rgb.
void swiftpwa_free_png(unsigned char *data);

// Like swiftpwa_encode_png_rgb, but for tightly-packed RGBA8 pixels
// (`width * height * 4` bytes, row-major) — preserves the alpha channel. Used by
// the Windows multi-size icon builder. Free the result with swiftpwa_free_png.
unsigned char *swiftpwa_encode_png_rgba(const unsigned char *pixels, int width,
                                        int height, int *out_len);

#endif
