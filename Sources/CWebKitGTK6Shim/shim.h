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
///
/// The WebKitGTK 6.0 ABI difference from the 4.1 shim: `get_snapshot_finish`
/// hands back a `GdkTexture*`, not a `cairo_surface_t*`, so the PNG write
/// goes through GDK rather than cairo.
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
    GdkTexture *texture = webkit_web_view_get_snapshot_finish(
        WEBKIT_WEB_VIEW(source), result, &error
    );

    int ok = 0;
    char *err_msg = NULL;
    if (error) {
        err_msg = g_strdup(error->message);
        g_error_free(error);
    } else if (texture) {
        ok = gdk_texture_save_to_png(texture, path) ? 1 : 0;
        if (!ok) err_msg = g_strdup("gdk_texture_save_to_png failed");
        g_object_unref(texture);
    } else {
        err_msg = g_strdup("snapshot produced no texture");
    }
    g_free(path);
    cb(ok, err_msg, swift_ud);
}

/// Asynchronously snapshot the web view's **visible region** and write it
/// to `path` as a PNG. See the 4.1 shim for why this goes via a file.
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

// ---------------------------------------------------------------------
// Permission requests (camera / microphone / location / notifications)
// ---------------------------------------------------------------------

// A bitmask of what one `WebKitPermissionRequest` is asking for. A single
// `getUserMedia({audio: true, video: true})` is *one* request needing two
// permissions, and WebKit only lets it be allowed or denied as a whole —
// which is why this is a mask rather than an enum.
// File-scope constants rather than `#define`s: the clang importer surfaces
// these to Swift as plain `let`s, where a macro's arithmetic may not survive.
static const unsigned int SWIFTPWA_PERM_MICROPHONE    = 1u << 0;
static const unsigned int SWIFTPWA_PERM_CAMERA        = 1u << 1;
static const unsigned int SWIFTPWA_PERM_GEOLOCATION   = 1u << 2;
static const unsigned int SWIFTPWA_PERM_NOTIFICATIONS = 1u << 3;
// `enumerateDevices()` asking for device *labels*. Not a capture grant, but
// it does reveal what hardware exists, which is why WebKit gives it its own
// request type rather than folding it into user-media.
static const unsigned int SWIFTPWA_PERM_DEVICE_INFO   = 1u << 4;

/// Classify a `WebKitPermissionRequest`. Returns 0 for a request type we
/// don't model (screen capture, media-key system, pointer lock), which the
/// caller must refuse rather than wave through.
///
/// In C because the `G_TYPE_CHECK_INSTANCE_TYPE` macros behind
/// `WEBKIT_IS_*_PERMISSION_REQUEST` don't survive the clang importer. Takes
/// `gpointer` so Swift never needs the request types imported at all.
static inline unsigned int swiftpwa_permission_request_kinds(gpointer request) {
    if (!request) return 0;
    unsigned int mask = 0;
    if (WEBKIT_IS_USER_MEDIA_PERMISSION_REQUEST(request)) {
        WebKitUserMediaPermissionRequest *media =
            WEBKIT_USER_MEDIA_PERMISSION_REQUEST(request);
        if (webkit_user_media_permission_is_for_audio_device(media)) {
            mask |= SWIFTPWA_PERM_MICROPHONE;
        }
        if (webkit_user_media_permission_is_for_video_device(media)) {
            mask |= SWIFTPWA_PERM_CAMERA;
        }
    } else if (WEBKIT_IS_GEOLOCATION_PERMISSION_REQUEST(request)) {
        mask |= SWIFTPWA_PERM_GEOLOCATION;
    } else if (WEBKIT_IS_NOTIFICATION_PERMISSION_REQUEST(request)) {
        mask |= SWIFTPWA_PERM_NOTIFICATIONS;
    } else if (WEBKIT_IS_DEVICE_INFO_PERMISSION_REQUEST(request)) {
        mask |= SWIFTPWA_PERM_DEVICE_INFO;
    }
    return mask;
}

static inline void swiftpwa_permission_request_allow(gpointer request) {
    if (request) webkit_permission_request_allow(WEBKIT_PERMISSION_REQUEST(request));
}

static inline void swiftpwa_permission_request_deny(gpointer request) {
    if (request) webkit_permission_request_deny(WEBKIT_PERMISSION_REQUEST(request));
}

/// The page URI a request came from, for the diagnostic. Freshly allocated;
/// the caller must `g_free` it. NULL when the view has no URI yet.
static inline char *swiftpwa_web_view_uri_copy(gpointer web_view) {
    if (!web_view) return NULL;
    const char *uri = webkit_web_view_get_uri(WEBKIT_WEB_VIEW(web_view));
    return uri ? g_strdup(uri) : NULL;
}

/// Run WebKit's own `Undo` / `Redo` editing command on the focused editable
/// element, the way an embedder is expected to.
///
/// WebKit's GTK port binds cut / copy / paste / select-all itself, but leaves
/// **undo and redo to the embedder** — so without this, Ctrl+Z in a text field
/// does nothing at all in any swift-pwa app on Linux. (Measured identically on
/// WebKitGTK 4.1 and 6.0.) The macOS counterpart is the Edit menu's
/// `undo:` / `redo:` items.
static inline void swiftpwa_web_view_undo(gpointer web_view) {
    if (!web_view) return;
    webkit_web_view_execute_editing_command(
        WEBKIT_WEB_VIEW(web_view), WEBKIT_EDITING_COMMAND_UNDO
    );
}

static inline void swiftpwa_web_view_redo(gpointer web_view) {
    if (!web_view) return;
    webkit_web_view_execute_editing_command(
        WEBKIT_WEB_VIEW(web_view), WEBKIT_EDITING_COMMAND_REDO
    );
}

/// The URI a navigation decision is about, or NULL if this decision isn't a
/// navigation (a *response* decision — display vs download — which the policy
/// leaves to WebKit). Freshly allocated; the caller must `g_free` it.
///
/// Both navigation decision types carry a `WebKitNavigationAction`:
/// `NAVIGATION_ACTION` is an ordinary load, `NEW_WINDOW_ACTION` a
/// `target="_blank"` / `window.open`.
static inline char *swiftpwa_policy_decision_uri_copy(
    gpointer decision, unsigned int decision_type
) {
    if (!decision) return NULL;
    if (decision_type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION
        && decision_type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        return NULL;
    }
    WebKitNavigationPolicyDecision *nav = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(nav);
    if (!action) return NULL;
    WebKitURIRequest *request = webkit_navigation_action_get_request(action);
    const char *uri = request ? webkit_uri_request_get_uri(request) : NULL;
    return uri ? g_strdup(uri) : NULL;
}

/// The *target* frame name of a navigation, or NULL when it has none.
/// Freshly allocated; the caller must `g_free` it.
static inline char *swiftpwa_policy_decision_frame_name_copy(
    gpointer decision, unsigned int decision_type
) {
    if (!decision) return NULL;
    if (decision_type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION
        && decision_type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        return NULL;
    }
    WebKitNavigationPolicyDecision *nav = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(nav);
    if (!action) return NULL;
    const char *name = webkit_navigation_action_get_frame_name(action);
    return name ? g_strdup(name) : NULL;
}

/// The `WebKitNavigationType` behind a navigation decision, or -1 if this
/// isn't one. 0 = link clicked, 1 = form submitted, 2 = back/forward,
/// 3 = reload, 4 = form resubmitted, 5 = other.
static inline int swiftpwa_policy_decision_navigation_type(
    gpointer decision, unsigned int decision_type
) {
    if (!decision) return -1;
    if (decision_type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION
        && decision_type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        return -1;
    }
    WebKitNavigationPolicyDecision *nav = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(nav);
    if (!action) return -1;
    return (int)webkit_navigation_action_get_navigation_type(action);
}

/// The URI of a *response* decision — the point at which WebKit has the
/// headers and is deciding whether to display. Freshly allocated; `g_free` it.
static inline char *swiftpwa_response_decision_uri_copy(gpointer decision) {
    if (!decision) return NULL;
    WebKitResponsePolicyDecision *response = WEBKIT_RESPONSE_POLICY_DECISION(decision);
    WebKitURIRequest *request = webkit_response_policy_decision_get_request(response);
    const char *uri = request ? webkit_uri_request_get_uri(request) : NULL;
    return uri ? g_strdup(uri) : NULL;
}

/// Whether a response decision is the **main frame's main resource** — the
/// one question the navigation decision can't answer. Subframe loads are
/// false, which is how an embedded iframe is told apart from the app
/// navigating away from itself.
static inline int swiftpwa_response_decision_is_main_frame(gpointer decision) {
    if (!decision) return 0;
    return webkit_response_policy_decision_is_main_frame_main_resource(
        WEBKIT_RESPONSE_POLICY_DECISION(decision)
    ) ? 1 : 0;
}

/// Let the navigation proceed.
static inline void swiftpwa_policy_decision_use(gpointer decision) {
    if (decision) webkit_policy_decision_use(WEBKIT_POLICY_DECISION(decision));
}

/// Cancel it. The page stays where it is — which is the point: an off-origin
/// load in the main frame strands the app, since a swift-pwa window has no
/// address bar and no back button.
static inline void swiftpwa_policy_decision_ignore(gpointer decision) {
    if (decision) webkit_policy_decision_ignore(WEBKIT_POLICY_DECISION(decision));
}

/// Hand a URI to the desktop — the browser for http(s), whichever app claims a
/// custom scheme. gio rather than `gtk_show_uri*`, which is spelled differently
/// in GTK3 and GTK4 and needs a window; this needs neither.
static inline int swiftpwa_open_uri_external(const char *uri) {
    if (!uri) return 0;
    GError *error = NULL;
    gboolean ok = g_app_info_launch_default_for_uri(uri, NULL, &error);
    if (error) g_error_free(error);
    return ok ? 1 : 0;
}

#endif
