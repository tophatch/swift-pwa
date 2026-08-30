#include "swiftpwa_heif.h"

#ifdef __linux__

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// The slice of libheif's C ABI this needs, transcribed from libheif 1.21's
// headers. Only opaque pointers, scalars, and one small by-value struct cross
// the boundary, which is what makes binding it by hand reasonable.
typedef struct heif_context heif_context;
typedef struct heif_image_handle heif_image_handle;
typedef struct heif_image heif_image;

typedef struct {
    int code;    // enum heif_error_code
    int subcode; // enum heif_suberror_code
    const char *message;
} swiftpwa_heif_error;

// From heif_image.h / heif_context.h.
enum { HEIF_COLORSPACE_RGB = 1 };
enum { HEIF_CHROMA_INTERLEAVED_RGB = 10 };
enum { HEIF_CHANNEL_INTERLEAVED = 10 };
enum { HEIF_COMPRESSION_HEVC = 1, HEIF_COMPRESSION_AV1 = 4 };

typedef swiftpwa_heif_error (*fn_init)(void *);
typedef heif_context *(*fn_context_alloc)(void);
typedef void (*fn_context_free)(heif_context *);
typedef swiftpwa_heif_error (*fn_read_memory)(heif_context *, const void *, size_t, const void *);
typedef swiftpwa_heif_error (*fn_primary_handle)(heif_context *, heif_image_handle **);
typedef swiftpwa_heif_error (*fn_decode)(const heif_image_handle *, heif_image **, int, int, const void *);
typedef int (*fn_get_dimension)(const heif_image *, int);
typedef const uint8_t *(*fn_get_plane)(const heif_image *, int, int *);
typedef void (*fn_image_release)(const heif_image *);
typedef void (*fn_handle_release)(const heif_image_handle *);
typedef int (*fn_have_decoder)(int);

static struct {
    void *handle;
    fn_context_alloc context_alloc;
    fn_context_free context_free;
    fn_read_memory read_memory;
    fn_primary_handle primary_handle;
    fn_decode decode;
    fn_get_dimension get_width;
    fn_get_dimension get_height;
    fn_get_plane get_plane;
    fn_image_release image_release;
    fn_handle_release handle_release;
    fn_have_decoder have_decoder;
    int usable;
} lib;

static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void load_libheif(void) {
    // SONAME rather than the `.so` symlink: that symlink ships in libheif-dev,
    // which is exactly the package we're avoiding requiring.
    lib.handle = dlopen("libheif.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (!lib.handle) {
        return;
    }

    lib.context_alloc = (fn_context_alloc)dlsym(lib.handle, "heif_context_alloc");
    lib.context_free = (fn_context_free)dlsym(lib.handle, "heif_context_free");
    lib.read_memory = (fn_read_memory)dlsym(lib.handle, "heif_context_read_from_memory_without_copy");
    lib.primary_handle = (fn_primary_handle)dlsym(lib.handle, "heif_context_get_primary_image_handle");
    lib.decode = (fn_decode)dlsym(lib.handle, "heif_decode_image");
    lib.get_width = (fn_get_dimension)dlsym(lib.handle, "heif_image_get_width");
    lib.get_height = (fn_get_dimension)dlsym(lib.handle, "heif_image_get_height");
    lib.get_plane = (fn_get_plane)dlsym(lib.handle, "heif_image_get_plane_readonly");
    lib.image_release = (fn_image_release)dlsym(lib.handle, "heif_image_release");
    lib.handle_release = (fn_handle_release)dlsym(lib.handle, "heif_image_handle_release");
    lib.have_decoder = (fn_have_decoder)dlsym(lib.handle, "heif_have_decoder_for_format");

    // heif_init is how 1.x is meant to be started (it loads the codec plugins).
    // Optional: older builds without it still decode.
    fn_init init = (fn_init)dlsym(lib.handle, "heif_init");
    if (init) init(NULL);

    lib.usable = lib.context_alloc && lib.context_free && lib.read_memory &&
                 lib.primary_handle && lib.decode && lib.get_width &&
                 lib.get_height && lib.get_plane && lib.image_release &&
                 lib.handle_release;
    if (!lib.usable) {
        dlclose(lib.handle);
        lib.handle = NULL;
    }
}

int swiftpwa_heif_available(void) {
    pthread_once(&load_once, load_libheif);
    return lib.usable ? 1 : 0;
}

int swiftpwa_heif_can_decode(int is_avif) {
    if (!swiftpwa_heif_available()) return 0;
    // libheif present but its codec plugin absent is a real configuration —
    // libheif-dev without libde265, say — so ask rather than assume.
    if (!lib.have_decoder) return 1;
    return lib.have_decoder(is_avif ? HEIF_COMPRESSION_AV1 : HEIF_COMPRESSION_HEVC) ? 1 : 0;
}

unsigned char *swiftpwa_heif_decode_rgb(const unsigned char *data, int len,
                                        int *out_w, int *out_h, int *out_len) {
    if (!data || len <= 0 || !out_w || !out_h || !out_len) return NULL;
    if (!swiftpwa_heif_available()) return NULL;

    heif_context *ctx = lib.context_alloc();
    if (!ctx) return NULL;

    heif_image_handle *handle = NULL;
    heif_image *image = NULL;
    unsigned char *result = NULL;

    do {
        // "without_copy" borrows `data`, which stays alive for this whole scope.
        swiftpwa_heif_error err = lib.read_memory(ctx, data, (size_t)len, NULL);
        if (err.code != 0) break;
        err = lib.primary_handle(ctx, &handle);
        if (err.code != 0 || !handle) break;
        err = lib.decode(handle, &image, HEIF_COLORSPACE_RGB,
                         HEIF_CHROMA_INTERLEAVED_RGB, NULL);
        if (err.code != 0 || !image) break;

        int width = lib.get_width(image, HEIF_CHANNEL_INTERLEAVED);
        int height = lib.get_height(image, HEIF_CHANNEL_INTERLEAVED);
        if (width <= 0 || height <= 0) break;

        int stride = 0;
        const uint8_t *plane = lib.get_plane(image, HEIF_CHANNEL_INTERLEAVED, &stride);
        if (!plane || stride < width * 3) break;

        size_t total = (size_t)width * (size_t)height * 3;
        if (total == 0 || total > (size_t)INT32_MAX) break;
        unsigned char *buffer = (unsigned char *)malloc(total);
        if (!buffer) break;

        // libheif's rows are stride-padded; the rest of the package wants them
        // tightly packed.
        for (int y = 0; y < height; ++y) {
            memcpy(buffer + (size_t)y * (size_t)width * 3,
                   plane + (size_t)y * (size_t)stride, (size_t)width * 3);
        }

        *out_w = width;
        *out_h = height;
        *out_len = (int)total;
        result = buffer;
    } while (0);

    if (image) lib.image_release(image);
    if (handle) lib.handle_release(handle);
    lib.context_free(ctx);
    return result;
}

void swiftpwa_heif_free(unsigned char *data) {
    free(data);
}

#else // !__linux__

int swiftpwa_heif_available(void) { return 0; }
int swiftpwa_heif_can_decode(int is_avif) { (void)is_avif; return 0; }

unsigned char *swiftpwa_heif_decode_rgb(const unsigned char *data, int len,
                                        int *out_w, int *out_h, int *out_len) {
    (void)data; (void)len; (void)out_w; (void)out_h; (void)out_len;
    return 0;
}

void swiftpwa_heif_free(unsigned char *data) { (void)data; }

#endif // __linux__
