# Letting an agent use your app

**Who this is for:** you want an AI agent to be able to *use* your app — open a document, run a search, start an export — by calling your app's own commands, not by guessing at pixels. And you want your users to stay in charge of whether that's happening.

Your app already has everything needed: every `registry.register(...)` call has a name, an argument shape and a result shape, which is most of an MCP tool definition. What this guide adds is the part that decides *which* commands, and who gets to decide.

Read [Talking to the native side](talking-to-the-native-side.md) first — this builds directly on registering commands.

> Uses swift-pwa **0.9.4+**. Desktop only.

---

## The big picture

Two independent yeses, from two different people:

```
  pwa.json  "agent": { "expose": [...] }   ──▶ the developer's ceiling
       │                                        (which commands are eligible at all)
       │                                        off by default, checked at build time
       ▼
  your app's own consent UI → agent.enable ──▶ the user's door
                                               (whether anything is exposed right now)
                                               off at launch, per session, revocable
```

Neither replaces the other. A build-time list on its own is you consenting on your user's behalf. A runtime toggle on its own asks them to approve a surface nobody bounded — "allow agent access?" isn't a question anyone can answer well.

---

## Step 1 — Pick what to offer

Expose **your app's verbs**, not general primitives. `book.open` is a good tool; `fs.readText` is the filesystem wearing your app's name.

The rule worth internalising: **expose the function, never the key.** If a feature calls a paid API, expose `myapp.translate` — your app reads the key natively and makes the call — so the credential never crosses the tool boundary. An agent can't do anything with a key that a command couldn't do for it, and everything it *could* do is unbounded. (`secrets.*` is refused outright for this reason.)

---

## Step 2 — Declare the ceiling (`pwa.json`)

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

The `description` is required — it's what an agent reads to decide whether to call the tool, so an undocumented one is unusable. The flags map to MCP's `readOnlyHint` / `destructiveHint` / `idempotentHint` / `openWorldHint`, and they're what lets your consent UI say *"2 read-only tools, 1 that can delete"* instead of "allow agent access?".

Not every command can be a tool. The build tells you which rule you hit:

- **Unary only** — an MCP tool call is one request and one result, so `subscribe` / `session` commands don't map.
- **Object or no arguments** — a command taking a bare `String` has no field name to give the agent, so wrap it in a struct.
- **Never `secrets.*` or `__*`.**

---

## Step 3 — Wire it up (Swift)

The list in `pwa.json` is what a reviewer reads; the list compiled into your app is what the runtime enforces. Both, and they have to agree:

```swift
ctx.use(AgentPlugin(tools: [
    AgentTool(command: "book.open",   description: "Open a book by id.", readOnly: true),
    AgentTool(command: "book.search", description: "Search the library. Returns matching book ids and titles.",
              readOnly: true, idempotent: true),
    AgentTool(command: "book.delete", description: "Permanently delete a book.", destructive: true)
]))
```

`swift-pwa build` resolves both lists against your app's real command catalog and **fails** on a mismatch — a command that doesn't exist, a description that differs, an annotation that differs, a tool declared in one place and not the other. That's deliberate: a stringly-typed allowlist otherwise fails silently in both directions, where a typo exposes nothing and a rename quietly *un*-exposes.

Check it on its own at any time:

```bash
swift-pwa agent check
# agent.expose: 3 tools eligible — 2 read-only, 1 destructive.

swift-pwa agent check --json     # exactly what an agent would be sent
```

---

## Step 4 — Ask the user (your UI)

Nothing is exposed yet. `AgentPlugin` gives your page four commands to build a consent UI with:

| Command | |
|---|---|
| `agent.status` | current state, including the tools and their risk annotations |
| `agent.enable` | binds a loopback port, mints a token, returns both |
| `agent.disable` | closes it, **and drops a connected client** |
| `agent.state` | a subscription — updates when a client attaches or drops |

The UI is yours on purpose: it knows your vocabulary, and a swift-pwa-drawn dialog would look foreign across five platforms.

```js
const bridge = window.__SWIFT_PWA__;

bridge.subscribe('agent.state', undefined, (state) => {
  render(state);        // state.tools, state.enabled, state.attached, state.port, state.token
});

allowButton.onclick = async () => {
  const state = await bridge.invoke(state?.enabled ? 'agent.disable' : 'agent.enable');
  render(state);
};
```

Show people what they're agreeing to. Group the tools by risk from the annotations you declared, and lead with the count:

```js
function tier(tool) {
  if (tool.destructive) return 'can delete';
  if (tool.readOnly) return 'read-only';
  return 'makes changes';
}
```

There's a complete, working version in [`Examples/CritterFacts/Sources/CritterFacts/web/agent.html`](../../Examples/CritterFacts/Sources/CritterFacts/web/agent.html) — copy it as a starting point.

---

## Step 5 — Connect an agent

Once a user turns access on, show them the port and token in a host configuration they can paste:

```jsonc
{
  "mcpServers": {
    "myapp": {
      "command": "swift-pwa",
      "args": ["mcp", "--agent", "--attach", "51423", "--token", "…"]
    }
  }
}
```

Their agent host spawns `swift-pwa mcp --agent`, which connects to your running app, asks it what it offers, and serves that as MCP tools. Your app checks its allowlist on every call — the relay is an ordinary local process, and none of the safety depends on it behaving.

Your app never runs an HTTP server for this.

---

## What your users see

While access is open, **swift-pwa** shows a status item in the system tray — waiting or connected, with a menu item to turn access off. Your app doesn't create it and can't hide it. That's the point: a developer who skips asking still can't make the fact invisible.

It appears from the moment access is enabled, not when a client connects, because the port is open either way.

---

## The honest limits

- **Consent can't be enforced.** Your app is native code; nothing stops it calling `enable()` at launch. The design makes the honest path easy and the dishonest one visible — it doesn't make the dishonest one impossible.
- **Annotations are your claim.** `readOnlyHint` is as trustworthy as your app. The MCP spec says the same of tool annotations generally. They inform the user; they don't constrain the runtime.
- **The refusals aren't a security boundary.** A `myapp.readSecret` command looks like any other command, and the build can't see through it. What the rules stop is the careless case, and they make intent explicit: doing the wrong thing takes deliberate code, not one string in a JSON file.
- **Desktop only.** iOS and Android have no tray for the indicator, and the relay is a desktop CLI.

---

## Where to go next

- [docs/agent-tools.md](../agent-tools.md) — the full reference: every rule the build enforces, the schema lowering, and the control protocol if you want to write your own client.
- [Testing your app from the outside](testing-your-app.md) — the development-time counterpart, where an agent drives *any* debug build rather than the commands you chose.
