# Flexible, config-driven remote image provider — findings + design

**Status:** **shipped** as `RESTImageProvider` (v0.8.12). Started as a spike; this
doc records what we built, what we proved against real APIs, the friction we hit,
and the productized shape.

**Productized beyond the spike:** async submit→poll (`.qwen`) and multipart edits
(`.openAIEdit`) flows; a synchronous multimodal preset (`.qwenImageMax`); a
`RemoteImageProvider` conformance (so it also serves `ai.generateImage` in the
switcher, not just `ai.run`); preset descriptors as data; a `CritterFacts` "nano
banana" picker arm. **All five providers live-verified end-to-end** through the
provider: Gemini, Imagen, OpenAI `gpt-image-1` generations **and multipart edits**
(2.2 MB), Qwen `qwen-image` async submit→poll (~8 s), and `qwen-image-max` on
DashScope's synchronous multimodal endpoint (2.6 MB). DashScope needs the region
base + model to match the account (an international key uses
`dashscope-intl.aliyuncs.com/api/v1`; `qwen-image-max` is served on a *different*
endpoint from the async `wan*`/`qwen-image` family — hence the separate preset).

## The question

Do Qwen / OpenAI (gpt-image) / Google Gemini image ("nano banana") / etc. each
need their own hand-written Swift `RemoteImageProvider`, or can **one** provider
*read a descriptor and adapt* to their APIs?

**Finding: for the common one-shot JSON case, one config-driven provider works —
proven live against two structurally-different real APIs with only a descriptor
difference.** A few genuinely different patterns (async job APIs, multipart edits,
conditional parameter coupling) still need an escape hatch.

## What we built

`RESTImageWorkflowProvider` (in `SwiftPWARemoteAI`) — a single
`AIWorkflowProvider` driven by a `RESTImageAPISpec` **descriptor that travels in
the call** (carried in `AIWorkflowConfig.graph`, the same "the spec is data" idea
the ComfyUI runner uses for a node graph). So it plugs straight into the existing
runtime surface: `ai.describeInputs` / `ai.run`, no rebuild to add an API.

The descriptor:

```swift
struct RESTImageAPISpec {
    var endpoint: String          // "/models/${model}:predict"  (${key} interpolated)
    var method = "POST"
    var contentType = "application/json"
    var body: JSONValue           // request template with "${key}" placeholders
    var output: Output            // where the images are + how they're carried
    var errorPath: String?        // "error.message"
    var fields: [AIInputField]    // describeInputs schema AND the ${key} placeholder set
}
struct Output {                   // JSONPath-based extraction
    var kind: .base64 | .url
    var imagesPath: String        // "predictions[*]" | "data[*]" | "candidates[*].content.parts[*]"
    var dataField: String?        // relative path to the b64/url within each node
    var mimeField: String?
}
```

Three pieces do the work:
1. **Auth + endpoint** come from the `AIConnection` (baseURL + headers, with a
   `secretRef` resolved into `${secret}` server-side). *No key material in the
   descriptor.*
2. **Request** = a JSON template. An exact `"${key}"` node is replaced by the
   *typed* value; a `${key}` embedded in a larger string interpolates; an
   unresolved optional placeholder **drops its object key** (so omitted params
   default server-side). The endpoint string interpolates too (`${model}`).
3. **Response** = a tiny JSONPath (`a[*].b.c`): `imagesPath` selects the
   image-bearing nodes, then `dataField`/`mimeField` read within each. **Nodes
   missing `dataField` are skipped**, which is why Gemini's interleaved *text*
   parts are ignored for free.

## What we proved (live, against real APIs)

Same Swift code, two descriptors, one `GEMINI_API_KEY`:

| API | Shape | Result |
|---|---|---|
| **Imagen** `models/imagen-4.0-generate-001:predict` | `{instances:[{prompt}],parameters:{…}}` → `predictions[*].bytesBase64Encoded` | **1408×768 PNG** (16:9 from the descriptor's default), ~12.8 s |
| **Gemini** `models/gemini-2.5-flash-image:generateContent` ("nano banana") | `{contents:[{parts:[{text}]}]}` → `candidates[*].content.parts[*].inlineData.data` | **1024×1024 PNG**, ~6.4 s |

Both flowed `progress(running)` → `image` → `done` through the standard `ai.run`
stream. (Live tests are opt-in on `GEMINI_API_KEY` in `LiveRemoteAITests`.)

Unit-tested in addition (scripted responses): the **OpenAI** shape
(`data[*].b64_json`), **`.url` output** (follow-up GET), seed randomize+echo,
optional-param drop, error-path extraction, and descriptor JSON round-trip.

## What we learned (friction)

1. **Field defaults are load-bearing.** First live attempt sent
   `/models/$%7Bmodel%7D:predict` — the `model` field had a default but the caller
   didn't override it, and we only bound *supplied* inputs. Fix: an un-overridden
   field falls back to its advertised `value`. (So `describeInputs`' defaults and
   the run's binding must share one resolution path.)
2. **Typed vs interpolated substitution is a real distinction.** `"sampleCount":
   "${count}"` must become the number `2`, not `"2"`; `"/models/${model}:predict"`
   must stay a string. Rule: an *exact* placeholder node adopts the value's type;
   an embedded one interpolates as text. Clean and sufficient.
3. **"Drop the key if unresolved" is the right default** for optional params
   (aspectRatio, seed) — matches how these APIs treat omitted fields.
4. **Response extraction with node-skip handles the messiest real case for free.**
   Gemini returns image and text parts interleaved; selecting `parts[*]` and
   skipping nodes without `inlineData.data` needs no special logic.
5. **Auth variety is a non-problem.** The existing `headers` bag + `${secret}`
   substitution already covers `Authorization: Bearer …` vs `x-goog-api-key` vs
   custom — zero new code.
6. **Conditional parameter coupling is the real ceiling.** Imagen's "an explicit
   seed forces `sampleCount:1` + `addWatermark:false`" is *logic*, not data — a
   flat template can't express it. We sidestepped it (the Imagen descriptor omits
   seed). This is the honest boundary where a hand-written provider still wins.

## What this does *not* cover yet (deferred, tracked)

- **Async submit→poll APIs** (Qwen native `X-DashScope-Async` → task id → poll).
  The ComfyUI provider already has this shape; a `flow: .asyncPoll(taskIdPath,
  pollEndpoint, statusPath, successValues, resultPath)` would generalize it.
- **Multipart edits** (OpenAI `/images/edits` — image+mask form parts). Needs a
  `request: .multipart([...])` branch, not just JSON.
- **Per-step progress.** None of these cloud APIs stream it, so coarse `running`
  is the honest ceiling (unlike ComfyUI's `/ws`).
- **Conditional coupling / response quirks** (§6, Gemini safety-block responses).
  Keep the hand-written `RemoteImageProvider` seam as the escape hatch, and/or add
  an optional request/response transform hook later.

## The cheap-coverage shortcut

Several services (Qwen/DashScope, others, self-hosted gateways) expose an
**OpenAI-compatible** `/v1/images/generations`. The OpenAI descriptor we
unit-tested covers all of them with just a `baseURL` + key + `model` swap — the
biggest coverage-per-effort win, and a strong argument to ship *at least* that.

## Recommendation

**Worth productizing** — it directly extends the epic's thesis (add a cloud API at
runtime, no rebuild), and the spike shows the core is small and the hard 20% is
cleanly walled off behind the existing seam.

Suggested path:
1. Promote the spike to a shipped provider: also conform to `RemoteImageProvider`
   (so it serves `ai.generateImage`, not just `ai.run`); ship a handful of
   **preset descriptors** (`.imagen`, `.openAICompatible`, `.geminiImage`) as
   data; add docs + a `CritterFacts` "bring-your-own-API" arm.
2. Add `flow: .asyncPoll` (unlocks Qwen native and any job-based API) and
   `request: .multipart` (unlocks edits).
3. Consider giving `AIWorkflowConfig.graph` a neutral alias (`spec`) since it's no
   longer ComfyUI-specific — it's "the provider's opaque config blob."

Effort: the engine is ~250 lines + presets are ~15 lines each, vs ~120 lines per
hand-written provider — break-even ~3 APIs, plus the runtime-pluggability payoff
that hand-written providers can't offer.

## Files (shipped)

- `Sources/SwiftPWARemoteAI/RESTImageProvider.swift` — the provider (both
  surfaces) + the engine (binding, multipart, async-poll, JSONPath).
- `Sources/SwiftPWARemoteAI/RESTImageAPISpec.swift` — the `Codable` descriptor +
  preset factories (`.imagen` / `.openAICompatible` / `.geminiImage` /
  `.openAIEdit` / `.qwen`).
- `Tests/SwiftPWARemoteAITests/RESTImageProviderTests.swift` — 11 unit tests
  (Imagen/OpenAI/Gemini shapes, URL output, multipart, async submit→poll,
  binding, errors, round-trip).
- `Tests/SwiftPWARemoteAITests/LiveRemoteAITests.swift` — `restImagenLive` /
  `restGeminiLive` / `restOpenAILive` / `restOpenAIEditLive` / `restQwenLive`
  (opt-in on `GEMINI_API_KEY` / `OPENAI_API_KEY` / `DASHSCOPE_API_KEY`).
- `Examples/CritterFacts/.../web/workflow.html` + `CritterFacts.swift` — the
  "Gemini image (nano banana)" picker arm (device-verified on a Tab S10+).
