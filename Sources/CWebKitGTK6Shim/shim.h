#ifndef SWIFT_PWA_WEBKITGTK6_SHIM_H
#define SWIFT_PWA_WEBKITGTK6_SHIM_H

#include <webkit/webkit.h>
#include <jsc/jsc.h>

// Forward declarations for the WebKit types we reference from Swift.
// In webkitgtk-6.0 the umbrella `<webkit/webkit.h>` reaches them via
// `G_DECLARE_FINAL_TYPE` macros — but Swift's clang importer doesn't
// always pick up types defined that way through transitive includes,
// and emits "cannot find type 'WebKitUserContentManager' in scope" /
// "WebKitURISchemeRequest" at the Swift-side use sites. Re-declaring
// them here gives the importer a direct anchor; the typedefs are
// identical to what the WebKit headers produce, so C11 accepts the
// duplicate.
typedef struct _WebKitUserContentManager WebKitUserContentManager;
typedef struct _WebKitURISchemeRequest WebKitURISchemeRequest;
typedef struct _WebKitWebView WebKitWebView;

/// Returns the GType name of a GObject instance, or NULL.
/// Owned by GLib — do *not* free the returned pointer.
static inline const char *swiftpwa_gobject_type_name(gpointer instance) {
    if (!instance) return NULL;
    return g_type_name(G_TYPE_FROM_INSTANCE(instance));
}

/// Extracts the JS string from a `script-message-received::<name>`
/// signal's value argument.
///
/// On webkit2gtk-4.1 this argument was a `WebKitJavascriptResult*`
/// (boxed type) that you had to unwrap. On webkitgtk-6.0 the signal
/// passes a `JSCValue*` directly — a real GObject — so this is just a
/// thin wrapper around `jsc_value_to_string`. The function exists in
/// both shims so the Swift backend can call the same name regardless
/// of ABI.
///
/// Returned string is freshly allocated; caller must `g_free` it.
static inline char *swiftpwa_extract_message_string(gpointer arg) {
    if (!arg) return NULL;
    return jsc_value_to_string((JSCValue *)arg);
}

/// `webkit_web_view_new_with_user_content_manager` was removed in
/// webkitgtk-6.0; construction goes through `g_object_new` with the
/// content manager as a property.
static inline GtkWidget *swiftpwa_web_view_new_with_user_content_manager(
    WebKitUserContentManager *ucm
) {
    return GTK_WIDGET(g_object_new(
        WEBKIT_TYPE_WEB_VIEW,
        "user-content-manager", ucm,
        NULL
    ));
}

/// Async-evaluate callback dispatched from `swiftpwa_evaluate_javascript`.
typedef void (*swiftpwa_eval_callback)(char *json, char *error, void *user_data);

typedef struct {
    swiftpwa_eval_callback cb;
    void *user_data;
} swiftpwa_eval_box;

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
        json = jsc_value_to_json(value, 0);
        g_object_unref(value);
    }
    cb(json, err_msg, swift_ud);
}

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

/// Wrapper around `webkit_user_content_manager_register_script_message_handler`,
/// which takes an extra `world_name` argument in webkitgtk-6.0 (NULL =
/// default JS world). Wrapping it keeps the Swift backend's call site
/// identical between the two ABIs.
static inline void swiftpwa_register_script_message_handler(
    WebKitUserContentManager *ucm,
    const char *name
) {
    webkit_user_content_manager_register_script_message_handler(ucm, name, NULL);
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
