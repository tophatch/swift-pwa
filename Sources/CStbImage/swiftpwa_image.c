// The single translation unit that compiles stb_image's implementation, plus
// the small RGB-decode wrapper declared in include/swiftpwa_image.h. stb_image
// itself stays private to this target (not under include/), so Swift only ever
// imports the two-function surface.
#include "swiftpwa_image.h"
#include <stdlib.h> // free (for swiftpwa_free_png)

// Trim stb to the formats the segmentation backend actually receives from web
// content (PNG/JPEG), and drop the stdio path (we always decode from memory) —
// smaller object, no libc file API surface.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"

// PNG *encode* for the image-edit backend's desktop output (LaMa result →
// PNG). No stdio path — we always return the bytes in memory.
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

unsigned char *swiftpwa_decode_image_rgb(const unsigned char *data, int len,
                                         int *width, int *height) {
    int channels = 0;
    // Force 3 channels (RGB) regardless of the source's channel count — the
    // encoder wants raw RGB with alpha dropped, matching the Apple/Android
    // preprocessing paths.
    return stbi_load_from_memory(data, len, width, height, &channels, 3);
}

void swiftpwa_free_image(unsigned char *pixels) {
    stbi_image_free(pixels);
}

unsigned char *swiftpwa_encode_png_rgb(const unsigned char *pixels, int width,
                                       int height, int *out_len) {
    // 3 = RGB, stride = width*3 (tightly packed). stb returns a malloc'd PNG.
    return stbi_write_png_to_mem(pixels, width * 3, width, height, 3, out_len);
}

void swiftpwa_free_png(unsigned char *data) {
    // stbi_write_png_to_mem allocates via STBIW_MALLOC (default malloc); free
    // it the same way (STBIW_FREE defaults to free).
    free(data);
}
