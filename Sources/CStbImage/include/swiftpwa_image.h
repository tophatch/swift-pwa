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

#endif
