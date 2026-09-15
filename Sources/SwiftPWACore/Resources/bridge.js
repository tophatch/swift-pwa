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
// Wire envelope (matches Sources/SwiftPWACore/Bridge/Invocation.swift).
// Every frame carries `ep`, the epoch of the document that owns it:
//   in : {v:1, ep, kind:"hello", id:0}   (this document is taking over the window)
//      | {v:1, ep, kind:"invoke"|"subscribe"|"unsubscribe", id, cmd?, payload?}
//      | {v:1, ep, kind:"push", id, payload}   (client frame into an open session)
//   out: {v:1, ep, kind:"reply", id, ok?, err?}
//      | {v:1, ep, kind:"event", id, chunk}
//      | {v:1, ep, kind:"end",   id}
(function () {
    if (globalThis.__SWIFT_PWA__) return;

    const VERSION = 1;
    let nextId = 1;
    const invokes = new Map();      // id -> {resolve, reject}
    const subscribes = new Map();   // id -> {onChunk, onError, onEnd}

    // Per-document epoch. This file is injected at document *start*, so a fresh
    // document mints a fresh one — which is the only signal the native side
    // needs to notice that a window navigated, and it arrives identically on
    // all five backends without any of them observing navigation themselves.
    //
    // It does two jobs. The `hello` frame below hands it over before the page's
    // own scripts run, and the runtime tears down everything the previous
    // document subscribed. And every frame carries it in both directions, so a
    // native stream that outlives its document can never bind to a live
    // subscription: correlation ids restart at 1 in each document, so without
    // this a leaked stream's frames resolve against whatever the *new* document
    // has since put in that slot — reproducibly, not as a race.
    //
    // Only the top frame takes part. This script is injected into subframes
    // too, and a subframe minting its own epoch would announce itself as the
    // window's new document and tear the *parent's* subscriptions down. A
    // subframe therefore sends unstamped frames, which the runtime accepts
    // as-is — the same (id-colliding, main-frame-delivered) behaviour subframes
    // have always had here; fixing that needs per-frame delivery, which is a
    // different change.
    const IS_TOP = (function () {
        try { return window.top === window; } catch (e) { return false; }
    })();
    const EPOCH = IS_TOP ? mintEpoch() : null;

    function mintEpoch() {
        const c = globalThis.crypto;
        if (c && typeof c.randomUUID === "function") return c.randomUUID();
        if (c && typeof c.getRandomValues === "function") {
            return Array.from(c.getRandomValues(new Uint8Array(16)), (b) =>
                b.toString(16).padStart(2, "0")).join("");
        }
        return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
    }

    function post(frame) {
        if (EPOCH) frame.ep = EPOCH;
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
        // A frame the native side stamped with a previous document's epoch: a
        // stream that outlived the document that opened it. Its correlation id
        // means nothing here, so resolving it would fire *this* document's
        // handler for whatever now holds that id.
        if (frame.ep && frame.ep !== EPOCH) return;
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

    // --- navigator.audioSession polyfill ---------------------------------
    //
    // The W3C Audio Session API decides what this app's audio *means* against
    // everything else on the device: whether it ducks the user's music or mixes
    // with it, whether it keeps playing in the background, and on iOS whether
    // the page keeps running at all once it isn't in front.
    //
    // Apple's WebKit ships it. Measured on all five engines, nothing else does
    // — not Android's WebView, not WebKitGTK 4.1 or 6.0, not WebView2. Rather
    // than add a swift-pwa-shaped API beside the standard one (which would make
    // every app carry a branch, and the branch would break on the platform its
    // author can't test), fill the standard one where it's missing.
    //
    // Deliberately *not* installed when the engine has its own: a real
    // implementation always wins, and this never wraps it.
    if (IS_TOP && !("audioSession" in navigator)) {
        // The web API is a property assignment, which can't await. So assign
        // optimistically, send, and reconcile from the reply: `type` reads back
        // what the page last asked for until the platform answers, then reads
        // what the platform actually did — which differ when an OS coerces or
        // refuses a type.
        let requested = "auto";
        // The platform's answer for the *latest* request, or null while one is
        // in flight — so `type` reads back optimistically until the platform
        // has spoken, then reads what it actually did.
        let reported = "auto";
        let state = "inactive";
        let inFlight = null;

        const apply = (value) => {
            requested = value;
            reported = null;
            const call = invoke("__audio.session.set", { type: value })
                .then((status) => {
                    if (inFlight !== call) return;   // superseded by a later assignment
                    reported = status.type;
                    state = status.state;
                })
                .catch((e) => {
                    // A backend without an implementation must not look like a
                    // page that never set a type: say so once, loudly, rather
                    // than leaving `type` reading back a value nothing honoured.
                    console.warn(
                        "swift-pwa: navigator.audioSession.type = '" + value +
                        "' was not applied by this platform:", e && e.message ? e.message : e
                    );
                });
            inFlight = call;
        };

        // WebIDL enum semantics, checked against WebKit's real implementation
        // rather than assumed: an unrecognised value is **ignored** — no throw,
        // no change — and a non-string is stringified first and then ignored if
        // it isn't a member. Measured on macOS: assigning "nonsense", 42 or
        // null after "playback" leaves `type` reading "playback" every time.
        // Getting this wrong is the exact divergence this polyfill exists to
        // prevent, so it is validated here rather than round-tripped.
        const TYPES = new Set([
            "auto", "playback", "ambient",
            "transient", "transient-solo", "play-and-record",
        ]);

        const audioSession = {
            get type() { return reported === null ? requested : reported; },
            set type(value) {
                const name = String(value);
                if (!TYPES.has(name)) return;
                apply(name);
            },
            get state() { return state; },
        };

        // On the prototype, where the real one lives, so a page that reflects
        // over `Navigator.prototype` sees the same shape it would on Apple.
        const target = (typeof Navigator === "function" && Navigator.prototype) || navigator;
        Object.defineProperty(target, "audioSession", {
            get() { return audioSession; },
            configurable: true,   // configurable: a real implementation arriving in a
            enumerable: true,     // future engine update should be able to replace this.
        });
    }

    // --- audio policy diagnostic -----------------------------------------
    //
    // The trap: a page that plays audio without ever setting
    // `navigator.audioSession.type` works perfectly on the developer's machine
    // and goes silent the moment the app is backgrounded on iOS. Nothing
    // reports it — no console error, no rejected promise — and an adopter who
    // doesn't own an iPhone cannot discover it at all, which is exactly the
    // class of gap this project exists to close.
    //
    // It fires only when audio is *actually* sounding and the type is still
    // the default. That pairing is what keeps it from crying wolf: a page with
    // an unused `<audio>` element never sees it, nor does one that has already
    // declared its policy, nor an `OfflineAudioContext` rendering silently.
    if (IS_TOP) {
        let audioPolicyReported = false;
        // A page may reasonably set the type in the same handler that starts
        // the sound, in either order; without this the warning is a race.
        const AUDIO_POLICY_GRACE_MS = 1000;

        const reportAudioPolicy = () => {
            if (audioPolicyReported) return;
            audioPolicyReported = true;
            setTimeout(() => {
                let type;
                try {
                    type = navigator.audioSession && navigator.audioSession.type;
                } catch (e) {
                    return;
                }
                if (type !== "auto") return;
                console.warn(
                    "swift-pwa: this page is playing audio with navigator.audioSession.type " +
                    "still 'auto'. On iOS that audio stops when the app goes to the " +
                    "background; on Android 'auto' requests no audio focus, so the user's " +
                    "own music keeps playing over it. Set the type to what the audio is " +
                    "for — 'playback' for something the user chose to listen to, 'ambient' " +
                    "for game or UI sound that should mix, 'transient' to duck others. " +
                    "See docs/javascript-api.md, 'audioSession'."
                );
            }, AUDIO_POLICY_GRACE_MS);
        };

        // Media elements need no patching: `play` doesn't bubble, but a
        // capturing listener on the document still sees it on every element.
        document.addEventListener("play", reportAudioPolicy, true);

        // Web Audio has no equivalent hook — nothing fires when a context
        // starts — so the constructor is subclassed. Subclassing rather than
        // wrapping keeps `instanceof`, the prototype chain and a page's own
        // `extends AudioContext` all working; the only added behaviour is the
        // check. Keyed on the context actually *running*, since a suspended
        // one makes no sound, and `OfflineAudioContext` is deliberately not
        // touched — rendering to a buffer isn't playback.
        for (const name of ["AudioContext", "webkitAudioContext"]) {
            const Original = globalThis[name];
            if (typeof Original !== "function") continue;
            const Observed = class extends Original {
                constructor(...args) {
                    super(...args);
                    const check = () => {
                        if (this.state === "running") reportAudioPolicy();
                    };
                    check();
                    this.addEventListener("statechange", check);
                }
            };
            Object.defineProperty(Observed, "name", { value: name });
            globalThis[name] = Observed;
        }
    }

    // --- navigator.mediaSession polyfill ---------------------------------
    //
    // Everything the OS shows for the audio you're playing: the lock-screen
    // entry, the media notification, what the headset button does.
    //
    // Four of the five engines already route this to the OS — verified by
    // driving the real control, not by checking for the property: a hardware
    // media key on macOS and Windows, the lock screen on iOS, an MPRIS Pause
    // over D-Bus on both GTK backends. Android's WebView doesn't expose the API
    // at all, so an Android app playing audio is invisible to the system.
    if (IS_TOP && !("mediaSession" in navigator)) {
        // MediaMetadata is missing wherever mediaSession is, so the constructor
        // a page calls has to exist too.
        if (typeof globalThis.MediaMetadata !== "function") {
            globalThis.MediaMetadata = class MediaMetadata {
                constructor(init) {
                    init = init || {};
                    this.title = init.title === undefined ? "" : String(init.title);
                    this.artist = init.artist === undefined ? "" : String(init.artist);
                    this.album = init.album === undefined ? "" : String(init.album);
                    this.artwork = init.artwork === undefined ? [] : init.artwork;
                }
            };
        }

        const STATES = new Set(["none", "paused", "playing"]);
        const handlers = new Map();   // action -> callback
        let metadata = null;
        let playbackState = "none";

        // Roughly what a lock screen draws cover art at on a high-density
        // phone. Picking by size rather than taking artwork[0] matters: a page
        // that offers 96px and 512px versions gets the sharp one, and a page
        // that offers a 2048px master doesn't push 4 MB through the bridge for
        // a thumbnail.
        const ARTWORK_TARGET_PX = 512;
        // A ceiling rather than a resize, because re-encoding the page's own
        // artwork would be a surprise. Over this it's skipped with a warning —
        // the track still shows, just without the image.
        const ARTWORK_MAX_BYTES = 4 * 1024 * 1024;
        // Bumped on every assignment, so a slow fetch for the previous track
        // can't land its cover on the current one.
        let metadataGeneration = 0;

        // `sizes` is a space-separated list ("96x96 128x128") or "any"; 0 means
        // "no usable size given", not "zero pixels".
        const artworkMaxDimension = (sizes) => {
            let max = 0;
            for (const token of String(sizes === undefined ? "" : sizes).split(/\s+/)) {
                const parsed = /^(\d+)x(\d+)$/i.exec(token);
                if (parsed) max = Math.max(max, Number(parsed[1]), Number(parsed[2]));
            }
            return max;
        };

        // Smallest entry that still covers the target; an entry with no usable
        // size ("any", an SVG) is preferred over one known to be too small,
        // since upscaling a thumbnail looks worse than whatever "any" turns
        // out to be.
        const pickArtwork = (list) => {
            let best = null;
            let bestScore = Infinity;
            for (const entry of Array.isArray(list) ? list : []) {
                if (!entry || !entry.src) continue;
                const max = artworkMaxDimension(entry.sizes);
                const score = max === 0
                    ? 1e4
                    : max >= ARTWORK_TARGET_PX ? max - ARTWORK_TARGET_PX
                        : 1e5 + (ARTWORK_TARGET_PX - max);
                if (score < bestScore) {
                    bestScore = score;
                    best = entry;
                }
            }
            return best;
        };

        // Fetched here, in the document, because that is the only place the
        // page's own artwork URL means anything — a bundle asset sits on a
        // virtual origin, and a `blob:` handle exists nowhere else at all.
        const readArtwork = async (entry) => {
            const response = await fetch(entry.src);
            if (!response.ok) throw new Error("HTTP " + response.status);
            const blob = await response.blob();
            if (blob.size > ARTWORK_MAX_BYTES) {
                throw new Error(blob.size + " bytes exceeds the " + ARTWORK_MAX_BYTES + "-byte limit");
            }
            const dataURL = await new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(String(reader.result));
                reader.onerror = () => reject(reader.error || new Error("unreadable"));
                reader.readAsDataURL(blob);
            });
            return {
                data: dataURL.slice(dataURL.indexOf(",") + 1),
                mimeType: blob.type || null,
            };
        };

        const publishActions = () => {
            invoke("__audio.nowPlaying.setActions", { actions: [...handlers.keys()] })
                .catch(() => {});
        };

        // The user pressed something on the lock screen, a headset, or a media
        // key. The runtime pushes it here; dispatch to whatever the page
        // registered. Subscribed once, up front, because the user can press
        // pause before the page has set anything.
        on("__audio.action", (payload) => {
            const handler = handlers.get(payload && payload.action);
            if (!handler) return;
            try {
                handler({ action: payload.action });
            } catch (e) {
                console.error("swift-pwa: a mediaSession action handler threw", e);
            }
        });

        const mediaSession = {
            get metadata() { return metadata; },
            set metadata(value) {
                metadata = value || null;
                const generation = ++metadataGeneration;
                const published = metadata && {
                    title: metadata.title || null,
                    artist: metadata.artist || null,
                    album: metadata.album || null,
                };
                invoke("__audio.nowPlaying.setMetadata", { metadata: published }).catch(() => {});

                // Artwork follows the text rather than gating it, so the track
                // appears on the lock screen straight away and gains its image
                // when the bytes arrive. A page that sets metadata from a
                // network response would otherwise show nothing until the
                // image downloaded.
                const chosen = metadata && pickArtwork(metadata.artwork);
                if (!chosen) return;
                readArtwork(chosen).then((artwork) => {
                    if (generation !== metadataGeneration) return;
                    invoke("__audio.nowPlaying.setMetadata", {
                        metadata: { ...published, artwork },
                    }).catch(() => {});
                }, (error) => {
                    // Warned rather than swallowed: the track still shows, so
                    // the only symptom is a missing image, and a page author
                    // needs to be told which URL didn't load.
                    console.warn("swift-pwa: mediaSession artwork could not be loaded", chosen.src, error);
                });
            },

            get playbackState() { return playbackState; },
            set playbackState(value) {
                const name = String(value);
                // WebIDL enum semantics, as with audioSession: an unrecognised
                // value is ignored rather than throwing.
                if (!STATES.has(name)) return;
                playbackState = name;
                invoke("__audio.nowPlaying.setPlaybackState", { state: name }).catch(() => {});
            },

            setActionHandler(action, handler) {
                const name = String(action);
                if (handler === null || handler === undefined) handlers.delete(name);
                else handlers.set(name, handler);
                publishActions();
            },

            setPositionState(state) {
                if (!state) {
                    invoke("__audio.nowPlaying.setPosition", { position: null }).catch(() => {});
                    return;
                }
                const duration = Number(state.duration);
                const position = Number(state.position === undefined ? 0 : state.position);
                const rate = Number(state.playbackRate === undefined ? 1 : state.playbackRate);
                // The spec throws for these, and a page relying on that to
                // validate its own numbers should get the same answer here.
                if (!(duration >= 0)) throw new TypeError("duration must be >= 0");
                if (!(position >= 0) || position > duration) {
                    throw new TypeError("position must be between 0 and duration");
                }
                invoke("__audio.nowPlaying.setPosition", {
                    position: { duration, position, playbackRate: rate },
                }).catch(() => {});
            },
        };

        Object.defineProperty(Navigator.prototype, "mediaSession", {
            get() { return mediaSession; },
            configurable: true,
            enumerable: true,
        });
    }

    // Tell the runtime this document owns the window now. First frame on the
    // channel, and it runs before the page's own scripts, so the previous
    // document's subscriptions are cancelled before this one opens any.
    if (IS_TOP) {
        try { post({ v: VERSION, kind: "hello", id: 0 }); } catch (e) {
            console.error("swift-pwa bridge: could not announce document", e);
        }
    }
})();
