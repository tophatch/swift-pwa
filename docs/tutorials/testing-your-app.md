# Testing your app from the outside

**Who this is for:** you want to check that your app actually *renders and works* — not just that its unit tests pass. Take a screenshot of the real webview, click a real button, type into a real field, and assert on the result. From a script, from CI, or from an AI agent, while you carry on using your machine.

`swift-pwa drive` opens a small control socket into a **debug build** of your app and gives you `eval`, `shot`, `click`, `type` and `scroll` against it.

New to the bridge? Read [Talking to the native side](talking-to-the-native-side.md) first — though you don't need it for this.

> Uses swift-pwa **0.9.4+**. Desktop only.

---

## The big picture

```
  swift-pwa drive shot out.png    ──▶ PNG of the webview's own pixels
                    eval "js"     ──▶ run JS in the page, get the value back
                    click/type    ──▶ real, trusted events into the app
       │
       └─ debug builds only, opt-in per launch, token per launch
```

Two things make this different from screen-capture-plus-synthetic-clicks:

- **The screenshot is the app's own render**, not the screen. A backgrounded, occluded or offscreen window still gives you a correct picture — and no Screen Recording grant is involved, so CI can do it.
- **Input goes into the app's own event queue**, not the system-wide one. The real cursor never moves, and you keep using your machine while a run is going.

---

## Step 1 — There's nothing to install

The driver is compiled into **debug builds only**. A release binary doesn't contain it at all, and even a debug build doesn't listen until it's asked to. You don't add a plugin or edit `pwa.json`.

Run this from your app's directory:

```bash
swift-pwa drive eval "document.title"
```

That builds your app, launches it, waits for the page, runs the JS, prints the value, and tears the app down.

---

If it stops with **"web bundle not found"**, your app predates
`WindowContent.bundledWeb` — `drive` symlinks your `web/` next to the binary to
cover exactly that, so this should be rare. See
[where the web bundle comes from](../app-driver.md#where-the-web-bundle-comes-from).

## Step 2 — Screenshot the real thing

```bash
swift-pwa drive shot screenshot.png
swift-pwa drive shot wide.png --window <id>     # a specific window
```

This is the one to reach for when you've changed CSS and want to *see* the result. It captures the webview's contents at its real backing scale, so a Retina window gives you a 2× PNG.

---

## Step 3 — Wait for something before you look

Pages load asynchronously, so a screenshot taken too early shows a spinner. `--wait` takes a JS expression and polls it until it's truthy:

```bash
swift-pwa drive shot ready.png --wait "document.querySelectorAll('.card').length > 3"
swift-pwa drive eval "document.querySelector('#total').textContent" --wait "!document.querySelector('.loading')"
```

`--timeout <seconds>` bounds the wait (default 30). The wait runs **in the CLI**, not the app, so you can change what you wait for without rebuilding anything.

---

## Step 4 — Drive the UI

```bash
swift-pwa drive click --selector "#save"           # measured and clicked in one round trip
swift-pwa drive click --x 0.5 --y 0.5 --fraction   # centre of the viewport
swift-pwa drive type "hello" --selector "#name"    # focus the field, then type
swift-pwa drive type --key Enter
swift-pwa drive scroll 400                          # pixels
```

These arrive as **trusted** events — `isTrusted: true`, real hit testing, focus changes and default actions all happen. That's the part a DOM event dispatched from `eval` can't do: those are untrusted and skip default behaviour, so a synthetic `click` on a `<label>` won't focus its input and a synthetic `keydown` won't insert text.

`--selector` measures the element and clicks it in the same round trip, so an animation can't move the button between measuring and clicking.

**Not every backend can do this.** Check before you rely on it:

```bash
swift-pwa drive info
```

| Backend | Screenshot | Input |
|---|---|---|
| **macOS** | Yes | Yes |
| **Linux GTK3** | Yes | Yes — including under Xvfb, with no input device |
| **Linux GTK4** | Yes | No — GTK4 removed public event synthesis |
| **Windows** | Yes | No — needs a composition controller swift-pwa doesn't create |

Where input isn't available, dispatch DOM events through `eval` instead and remember they're untrusted.

---

## Step 5 — Start on the screen you care about

Testing a settings page shouldn't mean clicking through three screens to reach it:

```bash
swift-pwa drive shot settings.png --route "/settings.html?tab=advanced"
```

That opens the app's **first** window at that path (query string and fragment included) instead of your declared entry. Everything after uses the normal entry, and your `web.entry` remains the SPA-fallback document — so a router-only route still resolves. It's the `SWIFT_PWA_INITIAL_ROUTE` environment variable underneath, useful well beyond testing: reproducing a bug report, or a demo that opens mid-flow.

---

## Step 6 — Drive an app you launched yourself

By default `drive` owns the app's lifecycle. To keep one app up across many commands, launch it yourself and attach:

```bash
SWIFT_PWA_DRIVE=0 ./.build/debug/MyApp &
# it prints: swift-pwa driver listening port=51423 token=ab12…

swift-pwa drive eval "location.href" --attach 51423 --token ab12…
swift-pwa drive click --selector "#next" --attach 51423 --token ab12…
```

`SWIFT_PWA_DRIVE=0` asks the OS for a free port; give it a fixed number if you'd rather pick. The token is minted fresh at every launch — an environment variable alone would be one `launchctl setenv` away from being a hole.

---

## Step 7 — In CI

On Linux, run it under a virtual display. GTK3's input path works there even though the display server has no input device at all:

```yaml
- run: |
    sudo apt-get install -y xvfb
    xvfb-run -a swift-pwa drive shot artifact.png --wait "document.readyState === 'complete'"
- uses: actions/upload-artifact@v4
  with:
    name: screenshot
    path: artifact.png
```

Uploading the PNG as an artifact means a failed run leaves you a picture of what the app looked like, which beats reading a stack trace and guessing.

---

## Step 8 — Hand it to an agent

The same verbs are available over MCP, so an AI agent can change a stylesheet, screenshot the result, and look at it:

```jsonc
{
  "mcpServers": {
    "myapp": { "command": "swift-pwa", "args": ["mcp"], "cwd": "/path/to/your/app" }
  }
}
```

The agent gets `app_screenshot`, `app_eval`, `app_click`, `app_type`, `app_press_key`, `app_scroll`, `app_windows` and `app_capabilities`. Screenshots come back as MCP **image** content, so it sees your app rather than a description of it.

This is a **development** tool: it's compiled out of release builds, so it can only ever reach a debug build on your own machine. Letting a *shipped* app offer an agent its own commands is a different feature with a different gate — see [Letting an agent use your app](letting-an-agent-use-your-app.md).

---

## One macOS detail worth knowing

For a click to reach a page in a window that isn't focused, the view under it has to accept "first mouse" — otherwise macOS treats the click as *activate the window* and swallows it. Driver builds opt into that; **release builds keep the platform default**, since whether a click into an unfocused window should reach your page is your design decision.

So if you're testing click-through behaviour by hand, test a release build — that one behaviour differs between the two.

---

## Where to go next

- [docs/app-driver.md](../app-driver.md) — every verb, the wire protocol (write your own client), and the full support table.
- [Letting an agent use your app](letting-an-agent-use-your-app.md) — the shipping counterpart.
