// A small C surface over Windows Imaging Component (WIC) — the platform image
// codec, and the Windows counterpart to ImageIO on Apple and BitmapFactory on
// Android.
//
// Why this exists: Chromium (and therefore WebView2) has no HEIC decoder, but
// Windows itself frequently does, so a page that cannot display a photo can
// still be handed a converted one. What WIC can read is a property of the
// *machine*, not the build — HEIC decoding needs the HEVC codec extension,
// which is the paid/OEM-supplied one — so `swiftpwa_wic_decode_extensions`
// enumerates the registered decoders at runtime rather than assuming.
//
// Everything is `extern "C"` and returns null / 0 on failure: a C++ exception
// unwinding across a C ABI into Swift terminates the process with no message,
// so every entry point swallows its own.
#ifndef SWIFTPWA_WIC_H
#define SWIFTPWA_WIC_H

#ifdef __cplusplus
extern "C" {
#endif

// Decode encoded image bytes to tightly-packed RGB8 (`*out_w * *out_h * 3`).
// When `max_side` is > 0 and the image's longest edge exceeds it, the image is
// scaled down proportionally by WIC before the pixels are copied — decoding a
// 24-megapixel photo at full size is ~72 MB of RGB, which is worth avoiding
// before it reaches Swift. Returns a buffer to free with swiftpwa_wic_free, or
// NULL on failure (including a format this machine has no decoder for).
unsigned char *swiftpwa_wic_decode_rgb(const unsigned char *data, int len,
                                       int max_side, int *out_w, int *out_h,
                                       int *out_len);

// Encode tightly-packed RGB8 pixels as PNG (`is_jpeg` = 0) or JPEG
// (`is_jpeg` = 1, `quality` 1-100). Returns a buffer to free with
// swiftpwa_wic_free, or NULL on failure.
unsigned char *swiftpwa_wic_encode_rgb(const unsigned char *pixels, int width,
                                       int height, int is_jpeg, int quality,
                                       int *out_len);

// Write a comma-separated, lowercase, dot-less list of the file extensions this
// machine's registered WIC decoders claim (e.g. "bmp,gif,heic,jpeg,jpg,png").
// Returns the number of bytes written (excluding the terminator), or 0 on
// failure. Truncates rather than overflowing `buf`.
int swiftpwa_wic_decode_extensions(char *buf, int buf_len);

// Free a buffer returned by the decode/encode functions above.
void swiftpwa_wic_free(unsigned char *data);

#ifdef __cplusplus
}
#endif

#endif // SWIFTPWA_WIC_H
