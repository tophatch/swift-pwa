// swift-pwa bridge runtime, injected at document start.
//
// Exposes globalThis.__SWIFT_PWA__ with:
//   .invoke(cmd, args)             -> Promise<result>
//   .subscribe(cmd, args, onChunk) -> () => void  (unsubscribe)
//   .session(cmd, openArgs, {onChunk,onError,onEnd})
//                                  -> { push(frame), close() }  (duplex session)
//   .on(channel, cb)               -> () => void  (server-push subscribe)
//   .emit(channel, payload)        -> Promise<void>  (publish to a channel)
//
// Wire envelope (matches Sources/SwiftPWACore/Bridge/Invocation.swift):
//   in : {v:1, kind:"invoke"|"subscribe"|"unsubscribe", id, cmd?, payload?}
//      | {v:1, kind:"push", id, payload}   (client frame into an open session)
//   out: {v:1, kind:"reply", id, ok?, err?}
//      | {v:1, kind:"event", id, chunk}
//      | {v:1, kind:"end",   id}
(function () {
    if (globalThis.__SWIFT_PWA__) return;

    const VERSION = 1;
    let nextId = 1;
    const invokes = new Map();      // id -> {resolve, reject}
    const subscribes = new Map();   // id -> {onChunk, onError, onEnd}

    function post(frame) {
        // Four native message channels, picked by what the platform
        // exposes:
        //   - WKWebView (macOS/iOS):
        //     window.webkit.messageHandlers.__SwiftPWA__post.postMessage(json)
        //   - WebKitGTK (Linux):
        //     window.webkit.messageHandlers.__SwiftPWA__post.postMessage(json)
        //     (registered via webkit_user_content_manager_register_script_message_handler)
        //   - WebView2 (Windows):
        //     window.chrome.webview.postMessage(json)
        //     (the inbound side of WebView2's host<->web message channel)
        //   - android.webkit.WebView (Android):
        //     window.__SwiftPWA__post.postMessage(json)
        //     (an `@JavascriptInterface`-annotated object the Kotlin
        //     SwiftPWABridge registers via addJavascriptInterface).
        const json = JSON.stringify(frame);
        const mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.__SwiftPWA__post;
        if (mh) { mh.postMessage(json); return; }
        if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === "function") {
            window.chrome.webview.postMessage(json);
            return;
        }
        if (window.__SwiftPWA__post && typeof window.__SwiftPWA__post.postMessage === "function") {
            window.__SwiftPWA__post.postMessage(json);
            return;
        }
        throw new Error("swift-pwa bridge: native message handler unavailable");
    }

    function deliver(jsonText) {
        let frame;
        try { frame = JSON.parse(jsonText); }
        catch (e) { console.error("swift-pwa bridge: malformed frame", e, jsonText); return; }
        if (frame.v !== VERSION) {
            console.error("swift-pwa bridge: unsupported version", frame.v);
            return;
        }
        const id = frame.id;
        switch (frame.kind) {
            case "reply": {
                const inv = invokes.get(id);
                if (!inv) {
                    // May be a one-shot subscribe reply: forward error if present.
                    const sub = subscribes.get(id);
                    if (sub && frame.err) { sub.onError(frame.err); subscribes.delete(id); }
                    return;
                }
                invokes.delete(id);
                if (frame.err) inv.reject(Object.assign(new Error(frame.err.message), frame.err));
                else inv.resolve(frame.ok);
                return;
            }
            case "event": {
                const sub = subscribes.get(id);
                if (sub) sub.onChunk(frame.chunk);
                return;
            }
            case "end": {
                const sub = subscribes.get(id);
                if (sub) { sub.onEnd(); subscribes.delete(id); }
                return;
            }
            default:
                console.warn("swift-pwa bridge: unknown frame kind", frame.kind);
        }
    }

    function invoke(cmd, args) {
        const id = nextId++;
        return new Promise((resolve, reject) => {
            invokes.set(id, { resolve, reject });
            try {
                post({ v: VERSION, kind: "invoke", id, cmd, payload: args === undefined ? null : args });
            } catch (e) {
                invokes.delete(id);
                reject(e);
            }
        });
    }

    function subscribe(cmd, args, onChunk, onError, onEnd) {
        const id = nextId++;
        subscribes.set(id, {
            onChunk: onChunk || (() => {}),
            onError: onError || ((e) => console.error("swift-pwa subscribe error:", e)),
            onEnd: onEnd || (() => {}),
        });
        try {
            post({ v: VERSION, kind: "subscribe", id, cmd, payload: args === undefined ? null : args });
        } catch (e) {
            subscribes.delete(id);
            throw e;
        }
        return function unsubscribe() {
            if (!subscribes.has(id)) return;
            subscribes.delete(id);
            try { post({ v: VERSION, kind: "unsubscribe", id }); } catch (_) {}
        };
    }

    // Duplex session: open a `subscribe`, then push client frames *into* it
    // while receiving downstream events on the same correlated channel. The
    // server side is a `registerSession` command. Returns { push, close }:
    //   push(frame)  posts a `push` frame into the open session (fire-and-forget;
    //                a no-op once the session has ended or been closed).
    //   close()      ends the session (posts `unsubscribe`).
    function session(cmd, openArgs, handlers) {
        handlers = handlers || {};
        const id = nextId++;
        subscribes.set(id, {
            onChunk: handlers.onChunk || (() => {}),
            onError: handlers.onError || ((e) => console.error("swift-pwa session error:", e)),
            onEnd: handlers.onEnd || (() => {}),
        });
        try {
            post({ v: VERSION, kind: "subscribe", id, cmd, payload: openArgs === undefined ? null : openArgs });
        } catch (e) {
            subscribes.delete(id);
            throw e;
        }
        return {
            push(frame) {
                if (!subscribes.has(id)) return;   // ended or closed
                post({ v: VERSION, kind: "push", id, payload: frame === undefined ? null : frame });
            },
            close() {
                if (!subscribes.has(id)) return;
                subscribes.delete(id);
                try { post({ v: VERSION, kind: "unsubscribe", id }); } catch (_) {}
            },
        };
    }

    // Server-push sugar over the `events.*` command set (EventsPlugin).
    //
    //   on(channel, cb)      -> () => void  (off)   subscribe to a channel;
    //                                               `cb` gets each payload.
    //   emit(channel, payload[, {retain}])          publish to a channel; fans
    //                                               out to every subscriber in
    //                                               every window.
    //
    // A named event bus lives on the Swift `AppContext`, so Swift can push
    // (`ctx.emit(channel, payload)`) without the client having asked, and a
    // retained channel replays its latest value to late subscribers.
    function on(channel, cb, onError) {
        return subscribe(
            "events.subscribe",
            { channel },
            (payload) => { if (cb) cb(payload); },
            onError,
            undefined,
        );
    }

    function emit(channel, payload, opts) {
        return invoke("events.emit", {
            channel,
            payload: payload === undefined ? null : payload,
            retain: !!(opts && opts.retain),
        });
    }

    // WebView2's host-to-web channel surfaces native frames as
    // `message` events on `window.chrome.webview` rather than
    // `evaluateJavaScript("...__deliver(json)")` calls. Subscribe so
    // PostWebMessageAsString-delivered frames flow through `deliver`
    // the same way the WK / WebKitGTK paths do.
    if (window.chrome && window.chrome.webview && typeof window.chrome.webview.addEventListener === "function") {
        window.chrome.webview.addEventListener("message", (event) => {
            if (typeof event.data === "string") {
                deliver(event.data);
            }
        });
    }

    Object.defineProperty(globalThis, "__SWIFT_PWA__", {
        value: Object.freeze({
            invoke,
            subscribe,
            session,
            on,
            emit,
            __deliver: deliver,    // called by the native side via evaluateJavaScript (WK / WebKitGTK)
            __version: VERSION,
        }),
        writable: false,
        configurable: false,
        enumerable: false,
    });
})();
