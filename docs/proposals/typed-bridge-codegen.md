# Proposal: typed JS↔Swift codegen layer

> **Status: Phases 1–2 shipped.** Roadmap item #6. Generate typed client
> bindings (TS + Swift) for `invoke` / `subscribe` / `session` from the
> registered command set, replacing the stringly-typed envelope at the call site.
>
> **Shipped (Phase 1 — catalog):** `BridgeSchema`, `CommandRegistry` records a
> `CommandDescriptor { name, kind, args, result, inbound? }` per `typed:`
> registration (`.descriptors()`), and the built-in `__bridge.describe` command
> exposes the catalog.
>
> **Shipped (Phase 1b — auto-derivation, *without* a macro):** schemas are
> derived by a **reflecting `Codable` probe** (`SchemaReflection`) rather than
> the `@BridgeType` macro this proposal originally recommended — see "Macro vs.
> probe" below. Plain command structs get a full schema with **zero
> annotation**; derivation is lazy (catalog-time only) and degrades unhandled
> types (enums, custom `init(from:)`, cycles) to `.unknown`, recoverable with an
> explicit `BridgeType` conformance.
>
> **Shipped (Phase 2 — generator + CLI):** `TypeScriptClientGenerator`
> (descriptors → a typed `bridge.ts` over `__SWIFT_PWA__`, all three call shapes,
> dotted names → namespaces, named `interface`/`type` decls) and the
> **`swift-pwa codegen`** CLI (reads a catalog JSON, writes the client; `--check`
> drift guard). Pure generator (no I/O), unit-tested.
>
> **Shipped (Phase 2b — headless dump):** `swift-pwa codegen` reads the catalog
> straight from the built app by default. Setting `SWIFT_PWA_DESCRIBE=<path>`
> makes a backend's `run(configure:)` build a UI-less `HeadlessAppContext`
> (built-ins + no-op `createWindow`), run the app's `configure`, write the
> `[CommandDescriptor]` catalog to that path, and exit before any window. Wired
> into the WebKit / GTK3 / GTK4 / Windows runtimes (Android is out of scope —
> codegen runs on the dev/CI host). See "Open questions" #2 for the purity
> caveat.
>
> **Remaining:** a Swift client (`--lang swift`); a `CritterFacts` demo.
>
> **Precursor #5 has shipped** ([bidirectional-bridge-sessions.md](bidirectional-bridge-sessions.md)):
> the codegen models **three** call shapes — unary, server-stream, and the duplex
> `session` (`registerSession` / `BridgeInbound<Frame>`). The descriptor `kind`
> enum covers all three.

## The problem

Every bridge call is stringly-typed on both ends. From JS:

```js
const info = await __SWIFT_PWA__.invoke("updater.check");   // name: string, result: any
```

Nothing checks that `"updater.check"` exists, that the payload shape is right,
or that you read the result's fields correctly. Same on the Swift side — the
command name is a bare string at `register`. Mistakes and drift between the two
sides surface at **runtime** (`E_DECODE`, "unknown command"), not at compile
time. This is pure DX debt: the bridge works, it just doesn't catch mistakes
early, and adopters hand-maintain parallel type declarations that rot.

The goal: generate a typed client so `bridge.updater.check()` is a real
function with a typed return, autocompletes, and **fails the build** if a
command is renamed, removed, or its payload/result shape changes.

## Why the naive approach doesn't work: types are erased at registration

The obvious idea — iterate the live registry and emit types — fails. The generic
typed registration path closes over `Args`/`Result` inside an opaque `Handler`
closure and stores only `handlers[name] = handler`
([CommandRegistry.swift:37-59](../../Sources/SwiftPWACore/Bridge/CommandRegistry.swift#L37-L59)).
Once registered, **the registry has no runtime record of what `Args`/`Result`
were.** The generic parameters are gone; the return is `some Encodable`. So the
type information must be *captured* deliberately, and Swift has no built-in
structural reflection over `Codable` to recover a schema from a type alone.

Three strategies were considered:

1. **Source parsing.** A build tool greps `register(…, typed: { (a: FooArgs, _)
   -> BarResult in … })` call sites and follows the structs. Zero runtime cost,
   but it's a mini Swift parser, breaks on dynamic command names (`ai.*`
   registers names built at runtime), typealiases, and generics. Rejected: the
   dynamic-name case (workflow/AI plugins) is exactly where adopters most want
   types.
2. **Hand-authored IDL.** A schema file is the source of truth; both the Swift
   `register` and the TS client generate from it. Most robust typing, but it
   inverts today's model (the Swift handler *is* the source of truth) and adds a
   file everyone must keep in sync — the very drift we're removing.
3. **Registration-time catalog (recommended).** Capture `(name, kind,
   argsSchema, resultSchema)` *at the moment `register` is called*, so the
   descriptor set is populated by actually running the app's `configure`
   closure. This is the only approach that captures **dynamically registered
   commands**, and it keeps the Swift handler authoritative.

The one hard part of (3): turning a Swift `Codable` type into a schema, since
reflection can't. The modern idiomatic answer is a **Swift macro** — the single
piece of compile-time magic, avoiding both a source parser and lossy `Mirror`
introspection.

## Design (recommended path)

### 1. A schema-bearing type protocol + macro

```swift
@BridgeType
struct UpdateInfo: Codable, Sendable {
    let version: String
    let notes: String?
    let mandatory: Bool
}
```

`@BridgeType` is a member macro that synthesizes a
`static var bridgeSchema: BridgeSchema` from the stored properties (name, type,
optionality, nested `BridgeType`s, arrays, enums-with-raw-values). `BridgeType`
is `Codable & Sendable` **plus** `static var bridgeSchema`. The schema is a small
JSON-Schema-subset value — enough to generate TS interfaces and Swift structs,
not a full JSON Schema validator.

Migration is mechanical: the handful of shared Args/Result structs
(`Sources/**/*Args.swift`, `*Result.swift`) gain `@BridgeType`. The untyped
`register` raw path and non-annotated typed path both keep working — codegen just
emits `unknown`/`Data` for un-annotated commands and warns, so adoption is
incremental, never a big-bang migration.

### 2. Typed registration records a descriptor

`register(_:typed:)` / `registerStream(_:typed:)` / `registerSession(_:typed:)`
constrain `Args`/`Result`/`Frame` to `BridgeType` and, alongside installing the
handler, record a `CommandDescriptor { name, kind, argsSchema, resultSchema,
inboundSchema? }` in the registry. `kind` ∈ `{unary, stream, session}` — the
three shapes, session's inbound schema coming from #5's `BridgeInbound<Frame>`.
The descriptor list is the catalog codegen consumes.

### 3. A describe surface + a headless dump

A built-in, **dev-only** command `__bridge.describe` returns
`[CommandDescriptor]`. But we don't want codegen to require a running window /
webview, so the primary path mirrors the existing env-flag convention
(`SWIFT_PWA_GTK4`, `SWIFT_PWA_LINUX_GUI`, …): when `SWIFT_PWA_DESCRIBE=<path>`
is set, `runtime.run` populates the registry via the app's `configure` closure,
**serializes the catalog to `<path>`, and exits before creating any window**.
This runs the real registration code (capturing dynamic names) with no UI, on
any platform the app already builds for.

### 4. The `swift-pwa codegen` CLI subcommand

```bash
swift run swift-pwa codegen --out ./src/bridge --lang ts,swift
```

Builds the app, runs it with `SWIFT_PWA_DESCRIBE=<tmp>`, reads the catalog, and
emits:

- **`bridge.ts`** — a typed façade over `__SWIFT_PWA__`:
  ```ts
  const bridge = createBridge(window.__SWIFT_PWA__);
  const info = await bridge.updater.check();          // UpdateInfo | null, typed
  const unsub = bridge.events.subscribe({ channel }, onPayload);
  const sess = bridge.speech.evaluate({ lang: "en" }, handlers); // { push, close }
  ```
  Dotted command names (`updater.check`) become nested namespaces; each shape
  gets the right signature (unary → `Promise<R>`, stream → `(args, cb) => unsub`,
  session → `(args, handlers) => { push, close }`). Plus emitted `interface`s for
  every `BridgeType`.
- **`Bindings.swift`** *(optional, `--lang swift)*` — a typed client for
  Swift-side callers (multi-window, tests) and, more usefully, compile-time
  assurance that a command name string still resolves.

### 5. Drift protection

`swift-pwa codegen --check` (CI mode) regenerates to a temp dir and diffs
against the committed bindings, failing if they differ — so a renamed command or
changed struct breaks CI until the bindings are regenerated. This is the payoff:
JS/TS call sites now fail the build, not the user's session.

## Phasing

1. **`BridgeSchema` + `@BridgeType` macro + catalog.** The macro, the
   descriptor recording in the three typed `register*` variants, unit tests that
   assert the emitted schema for representative structs (optionals, arrays,
   nested, enums). No CLI yet.
2. **Describe + headless dump.** `__bridge.describe` + the `SWIFT_PWA_DESCRIBE`
   exit-early path; test that a mock app's catalog round-trips.
3. **`swift-pwa codegen` (TS).** Generator + emitted `bridge.ts`; wire it into
   `Examples/CritterFacts` and convert a page to the typed client to prove it
   end-to-end (learn-by-doing — real friction: nullable results, streaming
   handler ergonomics, dotted-name collisions).
4. **`--check` + Swift bindings + docs.** CI drift guard, optional Swift client,
   `docs/javascript-api.md` + `docs/swift-api.md` + a codegen tutorial +
   README/CHANGELOG.

## Deferred / out of scope

- **Full JSON Schema** — emit only the subset the two generators need; not a
  runtime validator (the bridge already validates by decoding).
- **Enums with associated values / heavily generic payloads** — the macro
  handles structs + raw-value enums first; anything it can't model degrades to
  `unknown`/`Data` with a warning rather than failing codegen.
- **Runtime-shape-changing commands** (`ai.run`, whose inputs come from an
  imported graph): these are dynamic *by design* — codegen types the *envelope*
  (`ai.run` exists, takes `AIWorkflowConfig`) but the graph's inner input shape
  stays `describeInputs`-driven at runtime. Correct and expected.
- **Publishing bindings as an npm package** — emit into the app's source tree
  first; a distributable `@swift-pwa/bridge` client is a later nicety.

## Open questions

1. **Macro vs. probe — RESOLVED: reflecting probe, no macro.** The design above
   recommends a `@BridgeType` macro to synthesize schemas. Shipped instead: a
   reflecting `Codable` **probe** (`SchemaReflection`) that derives the schema by
   decoding a throwaway instance through a recording `Decoder`, capturing the
   keys/types the synthesized `init(from:)` asks for. Why the probe won:
   - **No build tax.** A macro drags **swift-syntax into the core build graph** —
     every contributor and every app that links `SwiftPWACore` pays a multi-minute
     cold-build cost, forever, for a codegen convenience. The probe is pure
     Foundation, zero new dependencies.
   - **Zero annotation.** The probe types *existing* command structs as-is; a
     macro would require adding `@BridgeType` to each. (`BridgeType` survives as a
     manual override for what the probe can't do.)
   - **Safe by construction.** Derivation is lazy (catalog-time only) and any
     failure degrades to `.unknown`, so it never touches normal dispatch/startup.

   Probe limitations (enums, custom `init(from:)`, cycles → `.unknown`) are the
   documented case for a `BridgeType` override. A macro could still be added later
   purely for those cases without re-taxing the core graph (it'd be opt-in), but
   there's no pressing need.
2. **Headless dump vs. a pure static extractor — RESOLVED: headless dump.** The
   `SWIFT_PWA_DESCRIBE` boot captures dynamic names but requires the app to
   build+run and runs the `configure` closure, which may have side effects. This
   shipped with both mitigations from the original question: the purity
   requirement ("`configure` must be pure up to registration") is documented, and
   `HeadlessDescribe.isDumping` is the `describeOnly` guard an adopter branches on
   to skip side-effectful work. `createWindow` / `serveDirectory` / `emit` are
   inert in the headless context, so the common `configure` body needs no changes;
   only *extra* work (downloads, subprocesses) needs the guard.
3. **How much does #5 reshape this?** The `session` shape and
   `BridgeInbound<Frame>` schema are the main additions vs. a pre-#5 design; if
   #5 slips, Phase 1 can ship unary+stream and add session later without
   rework — the descriptor's `kind` enum is the only forward-compat seam needed.
