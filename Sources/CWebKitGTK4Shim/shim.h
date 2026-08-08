#ifndef SWIFT_PWA_WEBKITGTK_SHIM_H
#define SWIFT_PWA_WEBKITGTK_SHIM_H

#include <webkit2/webkit2.h>
#include <jsc/jsc.h>

/// Returns the GType name of a GObject instance, or NULL.
/// Owned by GLib — do *not* free the returned pointer.
static inline const char *swiftpwa_gobject_type_name(gpointer instance) {
    if (!instance) return NULL;
    return g_type_name(G_TYPE_FROM_INSTANCE(instance));
}

/// Extracts the JS string from the `script-message-received` signal's
/// value argument.
///
/// On webkit2gtk-4.1 the value is a `WebKitJavascriptResult*` — a
/// `G_DEFINE_BOXED_TYPE` (i.e. *not* a GObject, so
/// `G_TYPE_FROM_INSTANCE` reads garbage off its first field).
/// On webkit2gtk-6.0 it's a `JSCValue*` (a real GObject).
///
/// We can't safely runtime-detect between the two with a type check
/// because boxed pointers aren't GTypeInstances. Instead we trust the
/// compile-time ABI: when built against webkit2gtk-4.1 we treat the
/// arg as a WebKitJavascriptResult and unwrap. (When/if we add
/// webkit2gtk-6.0 support this shim ships in a separate target.)
///
/// Returned string is freshly allocated; caller must `g_free` it.
static inline char *swiftpwa_extract_message_string(gpointer arg) {
    if (!arg) return NULL;
    JSCValue *value = webkit_javascript_result_get_js_value((WebKitJavascriptResult *)arg);
    return value ? jsc_value_to_string(value) : NULL;
}

/// Async-evaluate callback dispatched from `swiftpwa_evaluate_javascript`.
/// `json` is a freshly-allocated JSON serialization of the result, or
/// NULL if there was no result. `error` is a freshly-allocated GError
/// message, or NULL on success. Exactly one of the two will be non-NULL
/// (or both NULL for `undefined`). Callee must `g_free` whichever it
/// receives.
typedef void (*swiftpwa_eval_callback)(char *json, char *error, void *user_data);

typedef struct {
    swiftpwa_eval_callback cb;
    void *user_data;
} swiftpwa_eval_box;

/// GAsyncReadyCallback trampoline. Hidden from Swift; only the
/// public wrapper below is meant to be called from Swift code.
static inline void swiftpwa_eval_finish(
    GObject *source,
    GAsyncResult *result,
    gpointer user_data
) {
    swiftpwa_eval_box *box = (swiftpwa_eval_box *)user_data;
    swiftpwa_eval_callback cb = box->cb;
    void *swift_ud = box->user_data;
    g_free(box);

    GError *error = NULL;
    JSCValue *value = webkit_web_view_evaluate_javascript_finish(
        WEBKIT_WEB_VIEW(source), result, &error
    );

    char *err_msg = NULL;
    char *json = NULL;
    if (error) {
        err_msg = g_strdup(error->message);
        g_error_free(error);
    } else if (value) {
        // jsc_value_to_json returns NULL for `undefined`, which is what
        // we want — a side-effecting snippet should resolve to `nil`.
        json = jsc_value_to_json(value, 0);
        g_object_unref(value);
    }
    cb(json, err_msg, swift_ud);
}

/// Async-evaluate `js` on `web_view`. The callback is dispatched on
/// the GMainContext that's active when this function is called (i.e.
/// the GTK main thread, since that's where we route Swift calls via
/// `MainThread.run`). Both strings handed to `cb` are heap-allocated;
/// the callee owns them and must `g_free` whichever is non-NULL.
static inline void swiftpwa_evaluate_javascript(
    WebKitWebView *web_view,
    const char *js,
    swiftpwa_eval_callback cb,
    void *user_data
) {
    swiftpwa_eval_box *box = (swiftpwa_eval_box *)g_malloc0(sizeof(swiftpwa_eval_box));
    box->cb = cb;
    box->user_data = user_data;
    webkit_web_view_evaluate_javascript(
        web_view, js, -1, NULL, NULL, NULL,
        swiftpwa_eval_finish, box
    );
}

// ---------------------------------------------------------------------
// Webview snapshot (the app driver's `screenshot` verb)
// ---------------------------------------------------------------------

/// Snapshot callback. `ok` is 1 when the PNG was written to the path
/// handed to `swiftpwa_webview_snapshot_png`, 0 otherwise. `error` is a
/// freshly-allocated message on failure and NULL on success; the callee
/// must `g_free` it.
typedef void (*swiftpwa_snapshot_callback)(int ok, char *error, void *user_data);

typedef struct {
    swiftpwa_snapshot_callback cb;
    void *user_data;
    char *path;
} swiftpwa_snapshot_box;

/// GAsyncReadyCallback trampoline for `swiftpwa_webview_snapshot_png`.
static inline void swiftpwa_snapshot_finish(
    GObject *source,
    GAsyncResult *result,
    gpointer user_data
) {
    swiftpwa_snapshot_box *box = (swiftpwa_snapshot_box *)user_data;
    swiftpwa_snapshot_callback cb = box->cb;
    void *swift_ud = box->user_data;
    char *path = box->path;
    g_free(box);

    GError *error = NULL;
    cairo_surface_t *surface = webkit_web_view_get_snapshot_finish(
        WEBKIT_WEB_VIEW(source), result, &error
    );

    int ok = 0;
    char *err_msg = NULL;
    if (error) {
        err_msg = g_strdup(error->message);
        g_error_free(error);
    } else if (surface) {
        cairo_status_t status = cairo_surface_write_to_png(surface, path);
        if (status == CAIRO_STATUS_SUCCESS) {
            ok = 1;
        } else {
            err_msg = g_strdup(cairo_status_to_string(status));
        }
        cairo_surface_destroy(surface);
    } else {
        err_msg = g_strdup("snapshot produced no surface");
    }
    g_free(path);
    cb(ok, err_msg, swift_ud);
}

/// Asynchronously snapshot the web view's **visible region** and write it
/// to `path` as a PNG.
///
/// Via a file rather than a buffer because cairo's in-memory PNG encoder is
/// a write-callback stream API, and the GTK4 sibling shim's `GdkTexture`
/// has a file-based saver too — one temp file keeps both backends on the
/// same shape, and the driver deletes it as soon as it's read.
static inline void swiftpwa_webview_snapshot_png(
    WebKitWebView *web_view,
    const char *path,
    swiftpwa_snapshot_callback cb,
    void *user_data
) {
    swiftpwa_snapshot_box *box =
        (swiftpwa_snapshot_box *)g_malloc0(sizeof(swiftpwa_snapshot_box));
    box->cb = cb;
    box->user_data = user_data;
    box->path = g_strdup(path);
    webkit_web_view_get_snapshot(
        web_view,
        WEBKIT_SNAPSHOT_REGION_VISIBLE,
        WEBKIT_SNAPSHOT_OPTIONS_NONE,
        NULL,
        swiftpwa_snapshot_finish,
        box
    );
}

/// Set the web view's base background colour (painted before/under the
/// page), so the surface matches the app background instead of flashing
/// opaque white before first paint. Components are 0...1.
static inline void swiftpwa_webkit_set_background_color(
    WebKitWebView *web_view, double r, double g, double b, double a
) {
    GdkRGBA rgba = { r, g, b, a };
    webkit_web_view_set_background_color(web_view, &rgba);
}

// ---------------------------------------------------------------------
// Range-aware asset serving (content packs / large media)
// ---------------------------------------------------------------------

/// Read the request's "Range" header value, or NULL if absent. The caller
/// must `g_free` the returned string.
static inline char *swiftpwa_uri_request_range_header(WebKitURISchemeRequest *request) {
    SoupMessageHeaders *headers = webkit_uri_scheme_request_get_http_headers(request);
    if (!headers) return NULL;
    const char *range = soup_message_headers_get_one(headers, "Range");
    return range ? g_strdup(range) : NULL;
}

/// Finish `request` by streaming `length` bytes of the file at `path`
/// starting at `offset`, with HTTP `status` (200 or 206) and `mime`. Reads
/// straight from disk via a seekable `GFileInputStream` — the file is never
/// fully buffered in memory. Adds `Accept-Ranges: bytes` and, for 206, a
/// `Content-Range: bytes <offset>-<offset+length-1>/<total>` header.
/// `webkit_uri_scheme_response_new` takes its own ref on the stream
/// (transfer-none) so we release ours; `set_http_headers` is transfer-full
/// so we don't. Returns 1 on success, 0 after finishing with an error.
static inline int swiftpwa_uri_request_finish_file(
    WebKitURISchemeRequest *request,
    const char *path,
    gint64 offset,
    gint64 length,
    gint64 total,
    int status,
    const char *mime
) {
    GFile *file = g_file_new_for_path(path);
    GError *error = NULL;
    GFileInputStream *fstream = g_file_read(file, NULL, &error);
    g_object_unref(file);
    if (!fstream) {
        webkit_uri_scheme_request_finish_error(request, error);
        if (error) g_error_free(error);
        return 0;
    }
    if (offset > 0 &&
        !g_seekable_seek(G_SEEKABLE(fstream), offset, G_SEEK_SET, NULL, &error)) {
        webkit_uri_scheme_request_finish_error(request, error);
        if (error) g_error_free(error);
        g_object_unref(fstream);
        return 0;
    }

    // WebKit reads the response stream to EOF (stream_length is only a
    // Content-Length hint), so the stream must contain *exactly* the bytes
    // to send. When the range runs to EOF the seeked file stream already
    // yields exactly that — and WebKit reads it lazily/cancellably, so a
    // multi-GB file never materializes (the streaming-video case). A
    // bounded sub-range (ends before EOF) must be capped: read just those
    // bytes (bounded ranges are small) so the 206 body matches
    // Content-Range.
    GInputStream *body = NULL;
    if (offset + length >= total) {
        body = G_INPUT_STREAM(fstream); // ownership flows to `body`
    } else {
        gpointer buf = g_malloc((gsize)length);
        gsize got = 0;
        gboolean ok = g_input_stream_read_all(
            G_INPUT_STREAM(fstream), buf, (gsize)length, &got, NULL, &error);
        g_object_unref(fstream);
        if (!ok) {
            g_free(buf);
            webkit_uri_scheme_request_finish_error(request, error);
            if (error) g_error_free(error);
            return 0;
        }
        body = g_memory_input_stream_new_from_data(buf, (gssize)got, g_free);
        length = (gint64)got; // honor a short read in the headers below
    }

    WebKitURISchemeResponse *response = webkit_uri_scheme_response_new(body, length);
    webkit_uri_scheme_response_set_status(response, (guint)status, NULL);
    if (mime) webkit_uri_scheme_response_set_content_type(response, mime);

    SoupMessageHeaders *headers = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    soup_message_headers_append(headers, "Accept-Ranges", "bytes");
    soup_message_headers_append(headers, "Access-Control-Allow-Origin", "*");
    if (status == 206) {
        char *cr = g_strdup_printf(
            "bytes %" G_GINT64_FORMAT "-%" G_GINT64_FORMAT "/%" G_GINT64_FORMAT,
            offset, offset + length - 1, total);
        soup_message_headers_append(headers, "Content-Range", cr);
        g_free(cr);
    }
    webkit_uri_scheme_response_set_http_headers(response, headers);

    webkit_uri_scheme_request_finish_with_response(request, response);
    g_object_unref(response);
    g_object_unref(body);
    return 1;
}

/// Finish `request` with `416 Range Not Satisfiable` (empty body +
/// `Content-Range: bytes *\/<total>`).
static inline void swiftpwa_uri_request_finish_range_not_satisfiable(
    WebKitURISchemeRequest *request,
    gint64 total
) {
    GInputStream *empty = g_memory_input_stream_new();
    WebKitURISchemeResponse *response = webkit_uri_scheme_response_new(empty, 0);
    webkit_uri_scheme_response_set_status(response, 416, NULL);
    SoupMessageHeaders *headers = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    char *cr = g_strdup_printf("bytes */%" G_GINT64_FORMAT, total);
    soup_message_headers_append(headers, "Content-Range", cr);
    g_free(cr);
    webkit_uri_scheme_response_set_http_headers(response, headers);
    webkit_uri_scheme_request_finish_with_response(request, response);
    g_object_unref(response);
    g_object_unref(empty);
}

#endif
