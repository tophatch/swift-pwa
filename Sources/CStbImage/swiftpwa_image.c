// The single translation unit that compiles stb_image's implementation, plus
// the small RGB-decode wrapper declared in include/swiftpwa_image.h. stb_image
// itself stays private to this target (not under include/), so Swift only ever
// imports the two-function surface.
#include "swiftpwa_image.h"

// Trim stb to the formats the segmentation backend actually receives from web
// content (PNG/JPEG), and drop the stdio path (we always decode from memory) —
// smaller object, no libc file API surface.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"

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
