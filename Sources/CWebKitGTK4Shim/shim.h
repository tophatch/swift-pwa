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

// ---------------------------------------------------------------------
// Synthetic input (the app driver's `input.*` verbs)
// ---------------------------------------------------------------------
//
// Events are built by hand and pushed through `gtk_main_do_event`, which is
// GTK's own dispatch entry point — the same one the X/Wayland event reader
// calls. So they travel the real path (grabs, widget hierarchy, WebKit's own
// hit testing) without going anywhere near an X test extension or an
// OS-wide injection API. GTK4 removed all of this: `GdkEvent` is opaque
// there with no public constructors, which is why the GTK4 shim has no
// counterpart.

/// The `GdkWindow` events should target, plus the widget's offset within it.
/// A `WebKitWebView` usually draws into an ancestor's `GdkWindow` rather than
/// owning one, so coordinates have to be translated from widget space.
static inline GdkWindow *swiftpwa_event_target(
    GtkWidget *widget, int *out_dx, int *out_dy
) {
    GdkWindow *window = gtk_widget_get_window(widget);
    if (!window) return NULL;
    int dx = 0, dy = 0;
    GtkAllocation alloc;
    gtk_widget_get_allocation(widget, &alloc);
    if (!gtk_widget_get_has_window(widget)) {
        // The widget shares its parent's GdkWindow: its own origin is the
        // allocation's origin inside that window.
        dx = alloc.x;
        dy = alloc.y;
    }
    if (out_dx) *out_dx = dx;
    if (out_dy) *out_dy = dy;
    return window;
}

static inline GdkDevice *swiftpwa_pointer_device(GdkWindow *window) {
    GdkDisplay *display = gdk_window_get_display(window);
    if (!display) return NULL;
    GdkSeat *seat = gdk_display_get_default_seat(display);
    return seat ? gdk_seat_get_pointer(seat) : NULL;
}

/// Push a button press / release (`phase` 0 = press, 1 = release) or motion
/// (`phase` 2) at widget-relative `x`,`y`. `button` is GDK's numbering:
/// 1 left, 2 middle, 3 right. `click_count` > 1 additionally emits GDK's
/// double/triple-press event, which is how GTK reports a double-click.
static inline void swiftpwa_send_pointer_event(
    GtkWidget *widget, int phase, double x, double y,
    int button, int click_count, unsigned int state
) {
    int dx = 0, dy = 0;
    GdkWindow *window = swiftpwa_event_target(widget, &dx, &dy);
    if (!window) return;
    GdkDevice *device = swiftpwa_pointer_device(window);

    double wx = x + dx, wy = y + dy;
    int origin_x = 0, origin_y = 0;
    gdk_window_get_origin(window, &origin_x, &origin_y);
    guint32 time = (guint32)(g_get_monotonic_time() / 1000);

    GdkEventType type = phase == 2 ? GDK_MOTION_NOTIFY
                      : (phase == 0 ? GDK_BUTTON_PRESS : GDK_BUTTON_RELEASE);
    GdkEvent *event = gdk_event_new(type);
    // `gdk_event_free` unrefs the window, so hand it a reference of its own.
    event->any.window = g_object_ref(window);
    event->any.send_event = TRUE;

    if (type == GDK_MOTION_NOTIFY) {
        event->motion.time = time;
        event->motion.x = wx;
        event->motion.y = wy;
        event->motion.x_root = origin_x + wx;
        event->motion.y_root = origin_y + wy;
        event->motion.state = state;
        event->motion.is_hint = FALSE;
        if (device) gdk_event_set_device(event, device);
    } else {
        event->button.time = time;
        event->button.x = wx;
        event->button.y = wy;
        event->button.x_root = origin_x + wx;
        event->button.y_root = origin_y + wy;
        event->button.state = state;
        event->button.button = (guint)button;
        if (device) gdk_event_set_device(event, device);
    }
    gtk_main_do_event(event);
    gdk_event_free(event);

    // GTK reports a double-click as a plain press followed by a
    // GDK_2BUTTON_PRESS, not as a press with a count — so emit the second
    // event rather than leaving the page to infer it from timing.
    if (type == GDK_BUTTON_PRESS && click_count > 1) {
        GdkEvent *multi = gdk_event_new(
            click_count >= 3 ? GDK_3BUTTON_PRESS : GDK_2BUTTON_PRESS);
        multi->any.window = g_object_ref(window);
        multi->any.send_event = TRUE;
        multi->button.time = time;
        multi->button.x = wx;
        multi->button.y = wy;
        multi->button.x_root = origin_x + wx;
        multi->button.y_root = origin_y + wy;
        multi->button.state = state;
        multi->button.button = (guint)button;
        if (device) gdk_event_set_device(multi, device);
        gtk_main_do_event(multi);
        gdk_event_free(multi);
    }
}

/// Push a key press (`phase` 0) or release (`phase` 1). `keyval` is a GDK
/// keyval; the hardware keycode is looked up from the active keymap, because
/// WebKit maps a key to a DOM `code` through it and leaves it undefined
/// otherwise.
static inline void swiftpwa_send_key_event(
    GtkWidget *widget, int phase, unsigned int keyval, unsigned int state
) {
    GdkWindow *window = swiftpwa_event_target(widget, NULL, NULL);
    if (!window) return;
    GdkDisplay *display = gdk_window_get_display(window);

    GdkEvent *event = gdk_event_new(phase == 0 ? GDK_KEY_PRESS : GDK_KEY_RELEASE);
    event->any.window = g_object_ref(window);
    event->any.send_event = TRUE;
    event->key.time = (guint32)(g_get_monotonic_time() / 1000);
    event->key.state = state;
    event->key.keyval = keyval;
    event->key.hardware_keycode = 0;
    event->key.group = 0;
    event->key.is_modifier = 0;

    GdkKeymap *keymap = gdk_keymap_get_for_display(display);
    GdkKeymapKey *keys = NULL;
    gint n_keys = 0;
    if (keymap && gdk_keymap_get_entries_for_keyval(keymap, keyval, &keys, &n_keys) && n_keys > 0) {
        event->key.hardware_keycode = (guint16)keys[0].keycode;
        event->key.group = (guint8)keys[0].group;
    }
    if (keys) g_free(keys);

    GdkSeat *seat = gdk_display_get_default_seat(display);
    if (seat) {
        GdkDevice *kbd = gdk_seat_get_keyboard(seat);
        if (kbd) gdk_event_set_device(event, kbd);
    }
    gtk_main_do_event(event);
    gdk_event_free(event);
}

/// Push a smooth-scroll event. `dx`/`dy` are in the DOM's sense (positive dy
/// scrolls content down); GDK's smooth deltas use the same sign, so they pass
/// through unchanged.
static inline void swiftpwa_send_scroll_event(
    GtkWidget *widget, double x, double y, double dx, double dy, unsigned int state
) {
    int off_x = 0, off_y = 0;
    GdkWindow *window = swiftpwa_event_target(widget, &off_x, &off_y);
    if (!window) return;
    GdkDevice *device = swiftpwa_pointer_device(window);

    double wx = x + off_x, wy = y + off_y;
    int origin_x = 0, origin_y = 0;
    gdk_window_get_origin(window, &origin_x, &origin_y);

    GdkEvent *event = gdk_event_new(GDK_SCROLL);
    event->any.window = g_object_ref(window);
    event->any.send_event = TRUE;
    event->scroll.time = (guint32)(g_get_monotonic_time() / 1000);
    event->scroll.x = wx;
    event->scroll.y = wy;
    event->scroll.x_root = origin_x + wx;
    event->scroll.y_root = origin_y + wy;
    event->scroll.state = state;
    event->scroll.direction = GDK_SCROLL_SMOOTH;
    event->scroll.delta_x = dx;
    event->scroll.delta_y = dy;
    if (device) gdk_event_set_device(event, device);
    gtk_main_do_event(event);
    gdk_event_free(event);
}

/// Look up a GDK keyval from a name (`"Return"`, `"Left"`), or 0.
static inline unsigned int swiftpwa_keyval_from_name(const char *name) {
    return (unsigned int)gdk_keyval_from_name(name);
}

/// Look up a GDK keyval from a Unicode scalar.
static inline unsigned int swiftpwa_keyval_from_unicode(unsigned int scalar) {
    return (unsigned int)gdk_unicode_to_keyval((guint32)scalar);
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
