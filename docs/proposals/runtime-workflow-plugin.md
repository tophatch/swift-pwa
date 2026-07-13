# Proposal: a runtime, JS-reachable AI workflow plugin (`ai.run` / `ai.describeInputs`)

> **Status: Phases 1a + 1b + 3 implemented** (follow-up to the ComfyUI workflow
> runner, v0.8.9). `AIWorkflowPlugin` + `ai.run` / `ai.describeInputs`,
> connection-per-call, `/interrupt` cancel, graph-only `describeInputs` fallback,
> server-side `secretRef`, and (1b) **per-step `/ws` progress** over a new
> `NetworkClient.openWebSocket` transport — `URLSessionWebSocketTask` on
> Apple/Linux/Windows, and on Android an OkHttp-backed `net.ws.*` Kotlin RPC
> (`HttpURLConnection` has no WebSocket) that forwards frames to Swift as
> host-events. All live-verified against a real ComfyUI (device-verified on a
> Galaxy Tab S10+: a 15-step run streamed `1/15`…`15/15` live; some mobile radios
> reap a fully *idle* socket, which the reconnect covers — see the CHANGELOG).
> Phase 3 (example + JS-API docs) landed too: `Examples/CritterFacts`'
> `web/workflow.html` (import a graph → `describeInputs` → controls → `ai.run`
> with a reference image → progress → cancel) + `docs/javascript-api.md` +
> `docs/remote-ai.md`. **Deferred:** the cross-provider schema generalization
> (Phase 2 — `ImagenProvider`/on-device `describeInputs`). Depends on
> `SwiftPWARemoteAI` + the `ai.*` plugin + the shipped
> `runWorkflow` / `inspectWorkflow` Swift primitives.

## The problem

v0.8.9 shipped a real workflow runner — but only as a **Swift** API, wired at
**build time**. Adopter feedback pinpointed the gap precisely, and it's correct:

1. **No JS bridge.** `runWorkflow` / `inspectWorkflow` are methods on
   `ComfyUIProvider`; there is no bridge command. The only JS-reachable image
   path is `ai.generateImage`, whose fields are fixed (`prompt` / `image` /
   `mask` / `seed` / `size`).
2. **Build-time registration, not runtime.** Each `ComfyWorkflowProvider` binds
   **one** graph in `App.swift` at startup. To add a workflow — even a trivial
   txt2img — you rebuild the Swift app. You cannot register a new workflow from
   the running web app, and you cannot pass a **graph** or **arbitrary inputs**
   (e.g. a face-input reference image) through `ai.generateImage`.
3. **No progress, no cancellation.** `runWorkflow` polls `/history` and returns;
   ComfyUI's live `/ws` progress and `POST /interrupt` are unwired.
4. **Introspection is ComfyUI-only.** `inspectWorkflow` (graph × `/object_info`)
   is a `ComfyUIProvider` method. Imagen has a hardcoded field set. There's no
   shared way for a UI to ask *any* provider "what inputs do you take?"

The through-line: swift-pwa's model here is **build-time provider registration**;
what's wanted is **runtime plugin registration** reachable from JS — paste/select
a workflow, introspect it, run it with arbitrary typed inputs (including images),
watch progress, cancel.

## The key insight: the graph travels in the call

You don't need to *register* a Swift provider per workflow. If a bridge command
takes the **graph (and inputs) per call**, that *is* runtime registration:

- The app already owns importing / storing / selecting workflows (v0.8.9's
  division of responsibility). It hands one to the runner **at call time**.
- No Swift rebuild, no `App.swift` edit, no per-graph `AIModelInfo`.
- A reference image (face input, control image, second image) rides in the
  call's `inputs` as base64 or an on-disk path — the same `AIImage` carrier the
  rest of `ai.*` uses.

So the fix is a **generic, streaming, JS-reachable run + introspect surface**,
with a **provider-agnostic typed input schema** so it's not ComfyUI-only.

## The target model: provider + connection + input-schema + bindings

Model an AI image capability as four things, uniform across providers:

- **Provider** — the engine (ComfyUI, Imagen, an on-device backend).
- **Connection** — how to reach it (base URL, headers, credentials/key).
  **Travels in the call, symmetric with the graph** — see below. A runtime
  plugin's endpoint is user-entered at runtime (`http://my-nas.local:8188`
  today, a cloud URL + key + reverse-proxy header tomorrow); binding it at init
  (`ComfyUIProvider(baseURL:)`) would reintroduce the build-time problem one
  level down (a Swift rebuild per endpoint), so the runner is **stateless w.r.t.
  the endpoint** and takes the connection per call.
- **Typed input-schema** — the set of inputs it accepts, each with a type,
  range, options, default, and image-flag. **Populated by introspection where
  possible**, static where fixed:
  - **ComfyUI**: derived from the graph × `/object_info` (this is exactly
    today's `inspectWorkflow`, generalized).
  - **Imagen**: a fixed schema (`prompt`, `aspectRatio` enum, `count`, `seed`).
  - **On-device (SD/LaMa)**: a fixed schema (`prompt`, `steps`, `guidanceScale`,
    `image`, `mask`, …).
- **Bindings** — how a schema field reaches the provider's actual knobs.
  Explicit and app-visible for graph providers (node-input locations, with
  fan-out — today's `WorkflowBinding`); internal for fixed providers.

A JS app then does the same dance for any provider: **pick provider → point at a
connection → (supply a graph if graph-based) → `describeInputs` → render controls
→ `ai.run` with values → stream progress → images; cancel anytime.** Both the
graph *and* the connection are call-time, so an app's "Workflows" registry can add
a plugin (provider + endpoint + saved graph) purely at runtime with no rebuild.

## JS surface (on the existing `ai.*` plugin)

Two new commands, provider-agnostic:

### `ai.describeInputs`

```js
const schema = await __SWIFT_PWA__.invoke('ai.describeInputs', {
  provider: 'comfyui',         // routes to the provider (no pre-registered model)
  connection: { baseURL: '…' },// where to introspect (see `ai.run` for the shape)
  graph: importedGraphJSON,    // required for graph-based providers, omitted otherwise
  titledOnly: false,           // graph providers: narrow to author-titled inputs
});
// schema.inputs: [{
//   key, label, type: 'text'|'int'|'float'|'bool'|'enum'|'image'|'mask'|'seed',
//   value, min?, max?, step?, options?, group?, isImage
// }]
```

For Imagen, `graph`/`connection` introspection is unused and the fixed schema
comes back. For ComfyUI, the graph's literal inputs are crossed with the
connection's `/object_info` (today's `WorkflowInput`, renamed to a shared
`AIInputField`), each carrying its binding location so the UI needn't know node
ids.

- **The schema is connection-specific.** Combo options are *that box's* checkpoint
  / sampler / model-file lists, so it must be re-fetched when the connection
  changes and **not** cached across endpoints.
- **Graph-only fallback when the box is unreachable.** `/object_info` needs a
  reachable connection; if it's down (or omitted), return the graph's literal
  widget inputs with widget-derived types (no ranges / combo options) so a pasted
  graph can be authored before the box is up and a transient outage doesn't blank
  the builder.
- `'mask'` is a **distinct** input type from `'image'` (the Swift
  `WorkflowInputValue` already separates `.image`/`.mask`): a masked-inpaint
  workflow binds both, and the UI must know which to source from where.

### `ai.run` (streaming)

```js
const sub = __SWIFT_PWA__.subscribe('ai.run', {
  provider: 'comfyui',
  connection: {                    // travels in the call, symmetric with graph
    baseURL: 'http://my-nas.local:8188',
    headers: { /* … */ },          // open bag — reverse-proxy tokens, custom auth
    secretRef: 'plugin:abc/apiKey', // resolved server-side against secrets.* (below)
  },
  graph: importedGraphJSON,        // graph-based providers only
  inputs: {                        // arbitrary, keyed by schema field
    prompt: 'a red panda astronaut',
    image:  { dataBase64: '…' },   // or { path: '…' } — reference/control image
    mask:   { path: '…' },         // distinct from image (masked-inpaint workflows)
    seed:   null,                  // null ⇒ randomized per run
    width:  1024,
  },
  bindings: { /* optional overrides; else schema-derived / title convention */ },
  outputDirectory: '…',            // optional path-vs-base64 policy
}, {
  next: (e) => {                   // e.type: 'progress' | 'image' | 'done'
    if (e.type === 'progress') updateBar(e.value, e.max, e.node);
    if (e.type === 'image') show(e);   // { dataBase64 | path, seed, width, height }
  },
  error: (e) => …,
});
// cancel: sub.unsubscribe()  → interrupts the running job (see below)
```

A unary `invoke('ai.run', …)` form returns `{ images }` for callers that
don't want progress. `inputs` are validated against the schema; an image/mask
input is uploaded by the provider (ComfyUI `/upload/image`) before the run. The
`.image` event **echoes the resolved seed + dimensions** (`{ …, seed, width,
height }`) — the randomized-per-run seed has to survive the bridge or
reproducibility is lost the moment the result reaches JS.

This subsumes `ai.generateImage` for the graph case without changing it —
`ai.generateImage` stays as the fixed-field convenience path, and
`ComfyWorkflowProvider` stays as the turnkey build-time rung. Additive.

## Swift side

Extend the provider seam (a superset of `RemoteImageProvider`, or a new
`AIWorkflowProvider` protocol the remote providers adopt):

```swift
struct AIConnection: Sendable {          // travels per call
    var baseURL: URL
    var headers: [String: String] = [:]
    var secretRef: String? = nil         // resolved server-side (see below)
}
struct WorkflowRunConfig: Sendable {
    var connection: AIConnection
    var graph: Data? = nil               // graph-based providers only
    var inputs: [String: WorkflowInputValue] = [:]
    var bindings: [String: WorkflowBinding] = [:]
    var titledOnly = false
    var outputDirectory: String? = nil
}

struct AIInputField: Sendable, Codable { /* key,label,type,value,min?,max?,step?,options?,group?,isImage, binding? */ }
struct AIInputSchema: Sendable, Codable { var inputs: [AIInputField] }

protocol AIWorkflowProvider: Sendable {  // provider is STATELESS w.r.t. the endpoint
    // graph-based providers read `graph` from config; fixed providers ignore it.
    func describeInputs(config: WorkflowRunConfig, client: any NetworkClient) async throws -> AIInputSchema
    // streaming run with progress; cancellation via stream teardown.
    func run(config: WorkflowRunConfig, client: any NetworkClient)
        -> AsyncThrowingStream<AIImageEvent, any Error>   // .progress / .image / .done
}
```

- The provider holds **no endpoint** — the connection is in every call, so one
  registered provider serves any number of user-entered endpoints.
- **`secretRef` is resolved on the Swift side**, just before the request, against
  the `secrets.*` store (0.8.8). If JS did `secrets.get` and passed a bearer
  header itself, the key would sit in the web context and cross the bridge on
  every call; carrying a *reference* the net layer dereferences last-moment keeps
  the material out of JS entirely — the clean pairing with `SecretsPlugin`, and
  what makes "headers as an open bag" safe.
- **`ComfyUIProvider`** implements both natively: `describeInputs` = today's
  `inspectWorkflow` returning the shared `AIInputField`s; `runWorkflow` = today's
  runner wrapped in a streaming loop fed by `/ws`.
- **`ImagenProvider`** returns its fixed schema and maps `run` inputs onto
  its `:predict` call (no graph, no progress).
- The `ai.*` bridge routes `describeInputs` / `run` to the provider by
  the call's `provider` field. (`MultiModelImageBackend` routing still serves the
  build-time `ai.generateImage` path; the runtime path routes by provider, not a
  pre-registered model — since the connection now travels in the call there's no
  per-endpoint provider to register.)

`WorkflowInput` → `AIInputField` and `WorkflowBinding` are lifted from
`SwiftPWARemoteAI` toward `SwiftPWACore` (or a shared spot) so the schema is part
of the `ai.*` contract, not ComfyUI-private.

## Progress + cancellation

- **ComfyUI progress:** open `/ws?clientId=<client_id>` for the run and translate
  its frames into `.progress` events — `progress` (`value`/`max`/`node`),
  `executing` (current node), `executed` (node output), `execution_error`. Falls
  back to `/history` polling if the socket can't open. *(Exact frame shapes to be
  confirmed against the box during impl — we have it.)*
  - **Transport dependency (new, not in the original spec):** per-step progress
    is *only* on `/ws`; ComfyUI has no HTTP progress endpoint (`/history` is
    done/not-done, `/prompt` queue is coarse counts). But `NetworkClient` today
    is `send` + `download` — **no WebSocket** — and that seam exists because
    Android can't use `URLSession` directly (it routes through a Kotlin RPC). So
    real progress needs a **cross-platform WebSocket added to `NetworkClient`**:
    `URLSessionWebSocketTask` on Apple/Linux/Windows + a new Kotlin `net.ws` RPC
    on Android. This is its own sub-project. Scoping options:
    - **1a (HTTP-only, ship first):** `ai.run` + `ai.describeInputs` +
      connection-per-call + `/interrupt` cancel, with **coarse** progress polled
      from `/history`+`/prompt` (queued → running → done, no step %). Fully
      useful; unblocks the runtime door on every platform with no new transport.
    - **1b (add the WebSocket transport):** extend `NetworkClient` with a
      `connectWebSocket` (+ Android `net.ws` RPC), then per-step `/ws` progress.
      Bigger, cross-platform, verified per platform.
- **Cancellation:** the `subscribe` stream's `onTermination` (unsubscribe / window
  close) issues `POST /interrupt` for the in-flight `prompt_id` (and a `/queue`
  delete if still queued), mirroring how `process.stream` binds a child's lifetime
  to its subscription.
- **Other providers:** Imagen is one-shot — no progress; cancellation is
  best-effort task cancel. The event contract degrades gracefully (a provider that
  can't report progress emits only `.image`/`.done`).

WebView plumbing already exists — this is the same `subscribe` → `event` → `end`
path `ai.generateImageStream` and `process.stream` use.

## Backward compatibility

Entirely additive. `ai.generateImage` / `ai.generateImageStream` are unchanged;
`ComfyWorkflowProvider` and the Swift `runWorkflow`/`inspectWorkflow` primitives
stay. This adds a *runtime* door alongside the *build-time* one.

## Security

An arbitrary graph + inputs arriving from JS **runs on the connection named in the
call** (a LAN ComfyUI or a cloud key). This is the adopter's own web app on their
own bundle origin, and the plugin is opt-in (the app installs it + a net client).
Document that: (a) the workflow plugin is opt-in like `process.*`/`net.*`;
(b) inputs are validated/coerced against the schema; (c) a bad/mistyped graph
surfaces ComfyUI's `/prompt` validation message as `E_AI_GENERATION`;
(d) **a run egresses the canvas pixels (and any input image) to the connection** —
fine because the connection is explicit and opt-in, but state it so an adopter is
deliberate about pointing a run at a cloud endpoint; (e) a `secretRef` is resolved
against `secrets.*` **on the Swift side** so key material never enters JS or the
bridge payload.

## Reuse of what shipped

- `inspectWorkflow` → `describeInputs` (generalized return type).
- `WorkflowInput` → `AIInputField`; `WorkflowBinding` unchanged.
- `runWorkflow`'s binding engine + `/upload/image` + seed policy reused verbatim;
  only the completion path grows a streaming (`/ws`) variant.
- `MultiModelImageBackend` routing reused for `model`-based dispatch.

## Phasing

- **Phase 1 — JS-reachable ComfyUI run + introspect (streaming), connection
  per-call.** `ai.describeInputs` + `ai.run` on the `ai.*` plugin,
  ComfyUI-backed, with **both graph and connection in the call** (endpoint +
  headers + `secretRef` → resolved server-side), plus the graph-only
  `describeInputs` fallback and the seed/dims echo on `.image`. Progress via
  `/ws`, cancel via `/interrupt`. Connection-per-call is **not** deferrable — a
  build-time endpoint would collapse the "runtime" claim. Verified live: enter an
  endpoint + paste a graph → describe → render → run a reference-image workflow →
  progress bar → cancel mid-run.
- **Phase 2 — generalize the schema across providers.** Lift `AIInputField` /
  `AIInputSchema` into the shared contract; `ImagenProvider.describeInputs`
  (fixed) and on-device providers; one JS UI renders any provider's controls.
- **Phase 3 — example + docs.** A `CritterFacts` page that imports a workflow,
  builds controls from `describeInputs`, runs with a reference image, shows
  progress, and cancels; `docs/remote-ai.md` + `docs/javascript-api.md`.

## Open questions

1. **Command naming — resolved: `ai.run` + `ai.describeInputs`.** The neutral
   `ai.run` (with `graph` optional) was chosen over `ai.runWorkflow` so the verb
   doesn't leak the ComfyUI "workflow" model into a surface Imagen / on-device
   also answer. The shipped Swift `ComfyUIProvider.runWorkflow` primitive keeps
   its name; the new provider-protocol method is `run(config:)`.
2. **One workflow plugin vs. the existing `AIPlugin`.** Fold onto `AIPlugin` (one
   `ai.*` surface) — **resolved**. Gate the runtime door on "**the app installed
   the workflow plugin + a net client**," *not* "a workflow-capable model is
   registered": once the connection travels in the call there's no pre-registered
   per-endpoint provider to detect, so the gate is capability-present, not
   model-present.
3. **Schema for non-image modalities.** `AIInputField` is drawn for image gen;
   does it generalize to text/audio provider inputs later, or stay image-scoped?
4. **Graph size / cache handle — defer (resolved).** A big graph as a JSON string
   per call is fine. The network-expensive call is `describeInputs`
   (`/object_info`), which the app caches in its stored plugin definition;
   `ai.run` re-sends the graph either way (it's in `POST /prompt`), so a
   graph cache handle saves nothing.

---

## Incorporated review

An adopter review (against a concrete consumer: an in-app "Workflows" registry
where users add ComfyUI / Imagen / on-device plugins at runtime, point them at
their own endpoints, and run them against a selection) endorsed the direction and
surfaced one blocking gap plus a few refinements, all now folded into the design
above:

- **Blocking → fixed: the *connection* travels in the call too, not just the
  graph.** Binding the endpoint at init would reintroduce the build-time problem
  one level down (a rebuild per endpoint). The runner is now stateless w.r.t. the
  endpoint; `connection` (baseURL + open-bag headers + `secretRef`) rides in every
  call, and `secretRef` resolves against `secrets.*` server-side so key material
  never enters JS. Must land in **Phase 1**.
- **`mask` is a distinct input type** (not folded into `image`) — added to the
  schema type enum.
- **The `.image` event echoes the resolved seed + dimensions** so reproducibility
  survives the bridge.
- **`describeInputs` degrades to a graph-only schema** when the box is unreachable
  (literal widget inputs, widget-derived types, no ranges/options); the schema is
  **connection-specific** and re-fetched per endpoint, not cached across them.
- Open questions updated: fold onto `AIPlugin` gated on **capability present**
  (plugin + net client), not a registered model; cache handle deferred
  (`describeInputs` is the expensive call, cached app-side); naming still open.
- Security: named that a run **egresses canvas pixels to the connection**.
