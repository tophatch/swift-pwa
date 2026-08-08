# Exposing your app's commands to an AI agent

An app built with swift-pwa already has a typed command catalog — every
`registry.register(...)` call, with its argument and result shapes. That is
most of what an MCP tool definition needs, so a swift-pwa app can offer an
agent its *own verbs* (`book.open`, `note.search`) rather than making it poke
at pixels.

This is not the same thing as [`swift-pwa drive`](app-driver.md), which is a
development tool for driving *any* build from the outside and is compiled out
of release builds. What's described here ships in release binaries, so it's
gated much more carefully.

> **Status: both gates work; the MCP relay is the last cut.** An app can
> declare its ceiling, a user can turn access on, and a client can speak the
> control protocol below to list and call tools. What's still to come is
> `swift-pwa mcp --attach` translating that into MCP for an agent host. See
> [docs/proposals/swift-pwa-app-driver.md](proposals/swift-pwa-app-driver.md).

## Two gates, two owners

Exposure needs two independent yeses, and they belong to different people:

- **The developer sets the ceiling**, at build time, in `pwa.json`. Which of
  the app's commands are eligible to be exposed at all. Off by default: an app
  that says nothing exposes nothing.
- **The user opens the door**, at runtime, inside the app. Whether anything is
  exposed *right now*. Off by default, per session, revocable.

Neither substitutes for the other. A build flag on its own is the developer
consenting on the user's behalf. A runtime toggle on its own asks the user to
approve a surface nobody bounded — and "allow agent access?" with no ceiling
isn't a question anyone can answer well.

## Declaring the ceiling

```jsonc
"agent": {
  "expose": [
    {
      "command": "book.open",
      "description": "Open a book by id.",
      "read_only": true
    },
    {
      "command": "book.search",
      "description": "Search the library. Returns matching book ids and titles.",
      "read_only": true,
      "idempotent": true
    },
    {
      "command": "book.delete",
      "description": "Permanently delete a book.",
      "destructive": true
    }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `command` | A registered command name. Must exist at build time. |
| `description` | What it does, in one line. **Required** — this is what the agent reads to decide whether to call it. |
| `read_only` | Only reads state. → MCP `readOnlyHint` |
| `destructive` | Can destroy or overwrite something the user cares about. → MCP `destructiveHint` |
| `idempotent` | Calling it twice is the same as calling it once. → MCP `idempotentHint` |
| `open_world` | Touches the network or other people's data. → MCP `openWorldHint` |
| `tool_name` | Override the derived agent-facing name (`book.open` → `book_open`). |

The annotations are your claim about your own commands, so they're exactly as
trustworthy as the app — the MCP spec says as much of tool annotations in
general. They inform the user; they don't constrain the runtime. What they buy
is a consent prompt that can say *"4 read-only tools, 1 that can delete"*
instead of "allow agent access?", which is the difference between consent and a
dialog people click through.

## The declaration is checked against reality

A stringly-typed allowlist fails quietly in both directions: a typo exposes
nothing, and a rename silently *un*-exposes. For a security surface that's the
worst available failure mode, so the build resolves the list against the app's
live command catalog — the same headless dump (`SWIFT_PWA_DESCRIBE`)
[`swift-pwa codegen`](../README.md) uses — and fails loud.

```console
$ swift-pwa agent check
Building Books (debug) for a headless catalog dump…
agent.expose: 3 tools eligible — 2 read-only, 1 destructive.
```

```console
$ swift-pwa agent check
Error: pwa.json's agent.expose doesn't match Books's registered commands:

  • agent.expose names 'book.opne', which the app doesn't register. Registered
    commands in that namespace: book.open, book.delete, book.search.
```

`swift-pwa agent check --json` prints the resolved tools exactly as an agent
would receive them, which is the quickest way to see what a schema lowered to.

`swift-pwa build` runs the same check automatically. Because validating means
*running* the app, it can only do so when the target's binary runs on the build
host — a cross-compiled Android / iOS artifact can't be asked what it
registered. Rather than skip silently, the build says so and points at
`swift-pwa agent check`, which you can run on a host that can run it (CI, or
your dev machine).

## What can be exposed

Not every command can be a tool, and the check explains which rule it hit:

- **Unary only.** An MCP tool call is one request and one result. `subscribe`
  and `session` commands have no analogue.
- **Object or no arguments.** MCP requires `inputSchema` to be an object
  schema. A command taking a bare `String` has no field name to give the agent,
  and swift-pwa won't invent one — wrap it in a struct.
- **Never `secrets.*`.** A hard error, not a warning — because this is the one
  case the risk annotations can't describe honestly. `secrets.get` genuinely
  *is* read-only, so a consent sheet built from "Read a stored setting,
  `read_only: true`" would be accurate right up to the moment an agent walks
  off with the API key.
- **Never `__*`.** Bridge internals.

### Expose the function, never the key

Whatever needs a credential, **your app should do**. If a feature calls a paid
API, expose `myapp.translate` — the app reads the key natively and makes the
call — and the key never crosses the tool boundary at all. There is no version
of this where an agent is better off holding the secret: it can't do anything
with the key that a command couldn't do for it, and everything it *could* do
with the key is unbounded.

That's a design rule, not something the check enforces — a command that returns
a credential looks like any other command, and this can't see through it. The
`secrets.*` refusal exists to stop the careless case (pasting a whole command
list into the allowlist) and to make the intent explicit. Writing a command that
hands a key to an agent takes deliberate code; it isn't something you can do by
typing one string into a JSON file.

(An app whose actual product is dispensing credentials isn't blocked by any of
this — it has its own store and its own commands. Even there, "fill this field"
is the better verb than "return the password.")

Exposing a *built-in* capability — `fs.*`, `process.*`, `net.*`, `clipboard.*`,
`dialog.*` — warns rather than fails. It's your app, and there are legitimate
reasons. But these are general primitives: `fs.readText` gives an agent the
filesystem, not a verb from your app's vocabulary. A narrow command that does
only the thing you meant is nearly always the better shape.

Arguments that carry no schema (a type that doesn't conform to `BridgeType`)
also warn: the agent will be told the field accepts any JSON, which in practice
means guessing.

## Schema lowering

`BridgeSchema` lowers to JSON Schema structurally, and `swift-pwa codegen`'s
TypeScript output is the same information in a different grammar. Worth knowing:

- An **optional** field is described but left out of `required`.
- Objects are **strict** (`additionalProperties: false`), so an agent that
  invents a field is told, rather than having it silently dropped by the
  decoder on the far side.
- A **string enum** becomes an `enum` constraint, so the agent sees the valid
  options instead of guessing at a string.
- `Int` lowers to `integer` and `Double` to `number` — JSON has one number
  type, but an agent that sends `1.5` for an `Int` would otherwise only find
  out at the decoder.

## The runtime gate

The declared list is compiled in with `AgentPlugin`, which is what the runtime
enforces — a manifest isn't reachable from inside a shipped bundle, and a
reviewer shouldn't have to read Swift. The two are checked against each other
at build time, so they can't drift apart:

```swift
ctx.use(AgentPlugin(tools: [
    AgentTool(command: "book.open", description: "Open a book by id.", readOnly: true)
]))
```

That still exposes nothing. `AgentPlugin` registers four commands for the app's
*own* page to drive a consent UI with:

| Command | |
| --- | --- |
| `agent.status` | current state, including the declared tools and their risk annotations — what a consent sheet is built from |
| `agent.enable` | user says yes: binds a loopback port, mints a token, returns both |
| `agent.disable` | user says no: closes the listener **and drops a connected client** |
| `agent.state` | a subscription, so the UI updates when a client attaches or drops |

The properties that matter:

- **Off at launch, always.** No configuration key makes an app exposed from
  startup; something has to call `enable()`.
- **Per session.** Nothing is persisted. A user who allowed an agent once
  hasn't allowed it forever.
- **Revocation reaches a connected client**, not just the next one. Someone
  turning access off means now.
- **A fresh token per enable**, so one written down doesn't outlive its session.
- **One client at a time.** A second connection waits in the accept backlog
  until the first disconnects.

`agent.*` is itself a refused prefix in `agent.expose` — a tool that could call
`agent.enable` would widen its own access, which makes the user's gate
decorative.

### The indicator

While access is open, swift-pwa shows a **system-tray status item** — waiting or
connected, with a menu item to turn access off. It's runtime-owned: the app
doesn't create it, can't restyle it, and can't hide it.

That's the point. Consent can't be enforced in native code, so the design goal
is narrower: a developer who skips asking can't also make the fact invisible. A
window-title suffix was the cheaper option and fails exactly this test — the
app's next `setTitle` overwrites it.

It appears from the moment access is **enabled**, not from the moment a client
connects, since the port is open either way and a user who forgot they'd allowed
it should still see something. Being tray-based, it's **desktop-only**: iOS and
Android have no equivalent surface, and the relay is a desktop CLI anyway.

### The control protocol

Newline-delimited JSON on `127.0.0.1`, one request per line. Every frame
carries the token from `agent.enable`.

```text
→ {"id":1,"token":"…","cmd":"describe"}
← {"id":1,"ok":true,"result":{"protocolVersion":1,"tools":[
    {"name":"book_open","command":"book.open","description":"…",
     "args":{…BridgeSchema…},"annotations":{"readOnlyHint":true}}]}}

→ {"id":2,"token":"…","cmd":"call","payload":{"name":"book_open","arguments":{"id":"7"}}}
← {"id":2,"ok":true,"result":{…}}
```

`describe` returns each tool's arguments as a `BridgeSchema` rather than JSON
Schema: the lowering is a pure function the CLI owns, so fixing a
schema-mapping bug doesn't need an app rebuild.

**The allowlist is enforced in the app**, not in the relay — a relay is an
ordinary local process and can't be trusted to filter on the runtime's behalf.
Calls are looked up by *tool* name; passing a raw command name that was never
declared is refused with `E_AGENT_NOT_ALLOWED` either way.

## What's next

**Serving the tools** over `swift-pwa mcp --attach`, which is already a
stdio↔loopback relay, so no shipped app needs to stand up its own HTTP server.

Consent can't be *enforced* — the app is native code, and a developer who wants
to skip asking will. The design goal is narrower and achievable: make the
honest path the easy one, and the dishonest one visible.
