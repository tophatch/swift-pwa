// HEIC / AVIF decoding on Linux, via libheif — loaded with `dlopen` at runtime
// rather than linked.
//
// Why dlopen rather than a normal dependency: Linux is the one platform this
// project targets with no system image codec of its own, and the vendored
// stb_image build reads PNG and JPEG only. Linking libheif would put a
// `libheif-dev` package in every Linux adopter's build and a hard `libheif.so.1`
// requirement in every AppImage, to serve a capability most apps never use.
// Loading it on demand costs nothing when it's absent — `image.info` simply
// won't list `heic` — and needs no build flag, no `-dev` package, and no
// bundling. It is also the honest shape: whether HEIC decodes is a property of
// the machine (libheif dlopens its own codec plugins — libde265 for HEVC/HEIC,
// aomdec for AV1/AVIF), exactly as it is on Windows via WIC.
//
// The ABI declared here was read from libheif 1.21's headers. libheif has kept
// this C surface stable across 1.x; anything unresolvable simply disables the
// feature rather than crashing.
#ifndef SWIFTPWA_HEIF_H
#define SWIFTPWA_HEIF_H

#ifdef __cplusplus
extern "C" {
#endif

// 1 if libheif could be loaded on this machine, 0 otherwise. Cheap after the
// first call; the result is cached.
int swiftpwa_heif_available(void);

// 1 if a decoder for this container is actually usable right now. libheif can
// be installed while the codec plugin that backs a format is not, so this asks
// libheif rather than inferring from its presence. `is_avif` selects AV1
// (AVIF) over HEVC (HEIC/HEIF).
int swiftpwa_heif_can_decode(int is_avif);

// Decode HEIC/HEIF/AVIF bytes to tightly-packed RGB8 (`*out_w * *out_h * 3`).
// Returns a buffer to free with swiftpwa_heif_free, or NULL if libheif is
// absent, no codec plugin is installed for the format, or the data isn't one.
unsigned char *swiftpwa_heif_decode_rgb(const unsigned char *data, int len,
                                        int *out_w, int *out_h, int *out_len);

// Free a buffer returned by swiftpwa_heif_decode_rgb.
void swiftpwa_heif_free(unsigned char *data);

#ifdef __cplusplus
}
#endif

#endif // SWIFTPWA_HEIF_H
