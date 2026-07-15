# Proposal: bidirectional bridge sessions (duplex streaming)

> **Status: shipped** (Phases 1–4). Roadmap item #5. A bridge-layer capability
> (not a plugin): a duplex *session* primitive so JS can push frames **into** an
> already-open subscription, not just receive them. Shipped as the `push`
> inbound frame kind + `CommandRegistry.registerSession` / `BridgeInbound<Frame>`
> + the `__SWIFT_PWA__.session(...)` JS sugar — **zero per-backend code** (the
> inbound `postMessage` path is uniform across all five backends). Verified
> end-to-end on macOS through a real WKWebView + real `bridge.js`; demo at
> `Examples/CritterFacts/web/session.html`. Precursor to the typed codegen layer
> (#6), which must model this third call shape — see
> [typed-bridge-codegen.md](typed-bridge-codegen.md). The v1 scope note below
> (droppedCount) records what shipped vs. deferred.

## The problem

The bridge is **request → server-stream-out**. Three inbound frame kinds
(`invoke`, `subscribe`, `unsubscribe`) and four outbound (`reply`, `replyError`,
`event`, `end`) — see [Invocation.swift](../../Sources/SwiftPWACore/Bridge/Invocation.swift).
Once JS opens a `subscribe`, the only thing it can do to that stream is *close*
it (`unsubscribe`). There is no way to feed data **into** an open stream.

That's fine for everything shipped so far — `events.subscribe`, `ai.run`
progress, `process.stream`, `net.ws` frames, model-download progress — because
they're all one-directional fan-out. But it can't express a **live, duplex
session** where the client keeps pushing frames while the server responds on the
same logical channel:

- **Continuous speech evaluation** — mic PCM chunks stream *up* while partial
  transcripts / scores stream *down*, on one correlated session, for the whole
  utterance. (Directly pairs with roadmap #3/#4, the audio backend + native
  capture.)
- **Interactive/streaming LLM chat** — push a follow-up turn into an
  already-warm generation context without tearing down and re-opening.
- **Collaborative / real-time streams** — a cursor or edit feed where both
  sides emit continuously.

Today the only workaround is a correlation kludge: open a `subscribe` for the
downstream, then fire a series of separate `invoke`s tagged with a
session id you invent and match by hand. That has no lifecycle tie (the uploads
outlive the download, or vice versa), no ordering guarantee relative to the
open, no backpressure story, and it leaks the correlation bookkeeping into every
adopter. It's the kind of thing the bridge should own once, correctly.

## The key insight: the inbound channel is already uniform

Every backend funnels JS→Swift frames through one `postMessage` path into
`webView.inboundFrames()` (WK `messageHandlers`, WebView2 `postMessage`, the
Android `@JavascriptInterface`, WebKitGTK's script-message handler). **A new
inbound frame kind rides that existing path on all five platforms with zero
per-backend code** — the same reason `unsubscribe` needed no backend work. So
the entire feature is: one new inbound kind, a duplex registration variant, and
the JS sugar. No new outbound kind is needed — client-bound frames reuse
`event` / `end` / `replyError`.

That keeps the cross-platform-parity cost at essentially zero, which is why this
is worth doing at the bridge layer rather than faking per-plugin.

## Wire protocol

One new inbound frame kind, `push`, targeting an open session by its
correlation id. No new outbound kind.

```
in : {v:1, kind:"push", id, payload}      # client → open session `id`
```

`unsubscribe` doubles as the client-initiated half-close/close (as it already
does for `subscribe`). A session that ends naturally sends `end`; an error sends
`replyError` — unchanged.

`InboundFrame` gains `case push(id: UInt64, payload: Data)`; `Envelope.decode`
learns the `"push"` kind (requires `id` + `payload`, no `cmd` — the command was
fixed at open time).

## Swift API

A duplex registration variant. The handler receives the **open args** (opening
params, like today), an **inbound stream of typed client frames**, and returns
its outbound stream — same `AsyncThrowingStream` it returns today:

```swift
registry.registerSession(
    "speech.evaluate",
    typed: { (open: EvalConfig, inbound: BridgeInbound<AudioChunk>, ctx)
        -> AsyncThrowingStream<EvalEvent, any Error> in
        AsyncThrowingStream { continuation in
            let task = Task {
                for await chunk in inbound {           // client → server
                    let partial = evaluator.feed(chunk.pcm)
                    continuation.yield(.partial(partial))   // server → client
                }
                continuation.yield(.final(evaluator.finish()))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
)
```

`BridgeInbound<Frame>` is a thin `AsyncSequence` wrapper over the raw
`AsyncStream<Data>` that decodes each `push` payload to `Frame` (a decode
failure is skipped + logged, matching the typed-args contract). `postMessage`
is fire-and-forget — JS can't be back-pressured — so the underlying stream is
bounded `.bufferingNewest(n)` and **drops oldest on overflow**.

**As shipped:** the bound is **per-registration** —
`registerSession(name, maxBufferedFrames: 256, typed:)` — looked up by command
name in `BridgeRuntime` at subscribe time (the handler closure that carries it
doesn't run until dispatch, so the registry records it separately). Overflow
drops are **counted**: `BridgeRuntime.routePush` inspects the
`AsyncStream.Continuation.YieldResult` and bumps a per-session `DropCounter` on
`.dropped`, surfaced to the handler as **`BridgeInbound.droppedCount`** (a live
read, threaded through a `SessionInbound` value on `CommandContext`). Decode
skips are *not* counted as drops — they're a separate malformed-frame signal.

`CommandContext` gains an optional `sessionInbound: AsyncStream<Data>?` that
`BridgeRuntime` threads in; the typed `registerSession` wraps/decodes it into
`BridgeInbound<Frame>`. The untyped raw path stays available for the rare
adopter who wants bytes.

## BridgeRuntime — closing the open/push race

The subtlety: a `push` can arrive before the session handler has installed a
sink for its id. Because the pump task is **serial** (`for await frame in
stream`), a `subscribe`-open is *handled* before any later `push` for that id —
but "handled" means `dispatch` is *awaited*, and the handler's inbound
consumption starts asynchronously inside it. To avoid the same class of race the
Android cold-launch buffer solved: **`BridgeRuntime` creates the inbound
`AsyncStream` + continuation synchronously when it handles the open, stores it
in a lock-guarded `sessions[id]` map, and threads it into `CommandContext`
before dispatching.** `push` frames then route to `sessions[id]` continuation;
`unsubscribe`/`end`/teardown finish the continuation and remove the entry. A
`push` for an unknown id is dropped (logged once) — the session already closed.

This reuses the existing `subscriptions[id]` lifecycle machinery
([BridgeRuntime.swift:150-161](../../Sources/SwiftPWACore/Bridge/BridgeRuntime.swift#L150-L161))
— a session is a subscription that also owns an inbound continuation.

## JS API

Sugar over the existing `subscribe` + a new `push`:

```js
const session = __SWIFT_PWA__.session("speech.evaluate", { lang: "en" }, {
  onChunk: (e) => renderPartial(e),
  onError: (err) => showError(err),
  onEnd:   () => finalize(),
});

micStream.on("data", (pcm) => session.push({ pcm }));   // client → server
// ... later
session.close();                                         // sends unsubscribe
```

`session(cmd, openArgs, handlers)` opens a `subscribe` under the hood and returns
`{ push(frame), close() }`. `push` posts a `push` frame with the session's id;
`close` posts `unsubscribe` (identical to today's returned unsubscribe fn). No
change to `invoke` / `subscribe` / `on` / `emit`.

## Backpressure & ordering — the honest limits

- **No true backpressure JS→Swift.** `postMessage` can't block, so a client that
  floods faster than the handler drains will hit the bounded buffer and drop
  oldest (per-registration `maxBufferedFrames`, default 256; drops counted in
  `BridgeInbound.droppedCount`). Adopters that can't tolerate loss (a command
  channel) should ack-gate in their own protocol (yield an `event` the client
  waits for before pushing the next frame) — the primitive supports it, it
  isn't imposed.
- **Ordering** is preserved per session: `push` frames traverse the same single
  message channel as the open, and the pump is serial, so a handler sees pushes
  in send order (modulo drops).
- **Large frames** (audio PCM) go base64 in `payload`, same as every other
  binary on the bridge today; the existing `net.downloadFile`/model-progress
  precedent stands. If profiling shows base64 churn hurts on a hot mic path,
  a transferable/`ArrayBuffer` fast path is a later optimization, not v1.

## Phasing (all shipped)

1. **Core wire + runtime.** ✅ `push` inbound kind + `Envelope` decode, the
   `sessionInbound[id]` map + inbound threading in `BridgeRuntime`,
   `BridgeInbound`, `registerSession`. Unit-tested against `MockWebView` (no
   backend work) — round-trip, open/push race, malformed-drop, close, unknown-id.
2. **JS sugar.** ✅ `session()` + `push` in `bridge.js`.
3. **A real duplex consumer.** ✅ A `demo.runningTotal` session in
   `Examples/CritterFacts` (`web/session.html`: push numbers → the handler keeps
   a per-session running total and streams it back) — a deliberately simple
   stand-in until #3's audio backend gives a production consumer. Verified
   end-to-end on **macOS through a real WKWebView + real `bridge.js`** (a
   `WKBridgeIntegrationTests` case drives `session()` open → push → downstream
   echo → close). Android device-verification deferred alongside a heavier
   consumer (the inbound path is the uniform `postMessage`/JNI one already
   exercised by every other command, so the risk is low).
4. **Docs.** ✅ `docs/javascript-api.md` (`session`, "Duplex sessions"),
   `docs/swift-api.md` (`registerSession`), CHANGELOG. (No feature-matrix row —
   sessions are a core bridge primitive, not an opt-in plugin.)

## Deferred / out of scope

- **True flow control / credit-based backpressure** — start with bounded-drop +
  optional app-level acking; revisit only if a real consumer needs it.
- **Binary transferables** — base64 first; `ArrayBuffer` fast path later if
  measured.
- **Multiplexing several logical sub-streams over one session** — YAGNI; open
  multiple sessions.

## Resolved / deferred (post-ship)

1. **Push decode failures** → **silent-drop + log**, matching the typed-args
   contract; the session survives. A per-frame `replyError` strict mode is
   deferred until asked for.
2. **`droppedCount` + a configurable `maxBufferedFrames`** → **shipped.**
   `registerSession(maxBufferedFrames:)` (default 256) sets a per-command
   drop-oldest bound; overflow drops are counted (`routePush` inspects
   `YieldResult.dropped`) and surfaced as `BridgeInbound.droppedCount`.
3. **An untyped raw `registerSession`** → **not shipped;** the typed surface is
   the only one. Add a raw variant if an adopter genuinely needs bytes.
