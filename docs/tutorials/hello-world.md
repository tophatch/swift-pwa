# Hello, World — your first app

**Who this is for:** you've heard swift-pwa turns a web page into a real cross-platform app and you want to see it happen — from nothing to a window on your screen — in a few minutes. No prior swift-pwa (or Swift) knowledge assumed.

By the end you'll have a real native app running, with **live reload** so your edits show up instantly, and you'll understand every file the tool generated for you.

> Uses swift-pwa **0.8+**. Any recent version works the same way.

---

## What you'll have at the end

```
  swift-pwa init   →   a project    →   swift-pwa dev   →   a live window
   (scaffold)          (your files)     (edit → refresh)     you can build & ship
```

---

## Before you start

You need two things:

- **The `swift-pwa` CLI** — grab a release binary or build from source (see the [Quickstart](../../README.md#quickstart)).
- **A toolchain for your platform** — for the fastest path, a Mac with Xcode (macOS build). Linux and Windows work too; each platform's [`docs/*-setup.md`](../) lists what's needed.

Not sure you have the pieces? Run:

```sh
swift-pwa doctor
```

It checks your machine and prints a copy-paste fix for anything missing. Green across the board? Let's go.

---

## Step 1 — Create the project

Pick a folder and run `init` with your app's name:

```sh
swift-pwa init MyApp
cd MyApp
```

That's it — you now have a complete, buildable app. (Want a specific bundle id? Add `--bundle-id com.yourname.myapp`. Already have a web app in this folder? swift-pwa notices and wraps it *in place* instead — see [Where the web source goes](../../README.md#where-the-web-source-goes).)

---

## Step 2 — Look at what got made

```
MyApp/
├── pwa.json                 ← your app's settings (name, window size, bundle ids…)
├── Package.swift            ← the Swift build file (you won't touch this)
├── Sources/MyApp/
│   ├── App.swift            ← the native "shell" — the one Swift file you'll ever edit
│   └── AndroidEntry.swift   ← only matters if you ship to Android
├── web/
│   └── index.html           ← YOUR app — this is where you live
└── .github/workflows/release.yml   ← push a tag → cloud builds for every desktop OS
```

The mental model: **`web/` is your app; everything else is the shell that turns it into a native binary.** You spend ~all your time in `web/`, writing plain HTML/CSS/JS (or the build output of React/Vue/Svelte/whatever).

The generated `web/index.html` is a tiny working page — a heading, a **Rename window** button, and a log. Two lines in it already talk to the native side; we'll come back to those in Step 4.

> **`pwa.json` vs `App.swift` — a gotcha worth knowing now.** `pwa.json`'s `window` block (size, title…) only *seeds* the scaffold at `init` time. The **running** window is defined by the `WindowConfig` literal in `App.swift`. So if you resize the window later, edit `App.swift`, not `pwa.json`. (`pwa.json` still drives everything else: bundle ids, icons, `Info.plist`, etc.)

---

## Step 3 — Run it, with live reload

```sh
swift-pwa dev
```

This compiles the shell, opens your app in a native window, and serves `web/` with a **live-reload** server — so every time you save a file in `web/`, the window refreshes automatically. No rebuild, no restart.

Try it: open `web/index.html`, change `Hello, MyApp` to something else, hit save, and watch the window update.

> **First run is the slow one** — it compiles the Swift shell. After that, `dev` reuses the build and only your web edits refresh, so it's instant.

> **Already using Vite / Next / a dev server of your own?** Point swift-pwa at it instead of the built-in server: `swift-pwa dev --server http://localhost:5173`. Your bundler's own hot-reload drives the refresh; swift-pwa just hosts the native window. (The generated `App.swift` loads the dev URL when the `PWA_DEV_SERVER` env var is set, and falls back to the bundled assets in a real build — that's the `if let dev = …` branch you'll see near the top of the file.)

---

## Step 4 — The one line of "magic"

Look at the bottom of the generated `web/index.html`:

```js
// Call a native command and wait for the result:
await __SWIFT_PWA__.invoke('window.setTitle', { title: 'renamed at ' + new Date().toISOString() });

// Subscribe to a stream of native events:
__SWIFT_PWA__.subscribe('window.subscribe', {}, (e) => log('event: ' + JSON.stringify(e)));
```

That `__SWIFT_PWA__` object is the entire bridge between your web code and the native shell. It's injected before your page runs, so it's just *there* — no import, no setup, nothing to await.

- **`invoke(command, options)`** runs a native command once and returns a Promise with the result — here, renaming the OS window.
- **`subscribe(command, options, callback)`** opens a stream — the callback fires each time the native side has something to report (here, window focus/resize events).

swift-pwa ships a pile of built-in commands (`window.*`, `app.*`, `dialog.*`, `fs.*`, and more — see the [feature matrix](../../README.md#feature-matrix)). And when you need something we don't ship, you can add **your own** command in a few lines of Swift — that's the next tutorial: **[Talking to the native side](talking-to-the-native-side.md)**.

---

## Step 5 — Build the real thing

`dev` is for iterating. When you want an actual app to double-click or hand to someone:

```sh
swift-pwa build            # builds for your current OS (macOS/Linux/Windows)
open build/macos/MyApp.app # each target gets its own dir: build/linux, build/windows, …
```

`--target` defaults to whatever OS you're on, so you can omit it for a local build. That's a genuine native app: your web assets bundled inside, running on the system webview, no browser shipped.

Getting it signed and into users' hands (App Store, download page, Play Store, …) is its own guide: **[Shipping your app](shipping-your-app.md)**.

---

## Where to go next

- **[Talking to the native side](talking-to-the-native-side.md)** — how the bridge works and how to add your own native commands.
- **[Saving and loading files](saving-and-loading-files.md)** — real Open/Save dialogs, with a browser fallback.
- **[On-device AI](on-device-ai.md)** — local text and image generation behind the `ai.*` API.
- **[Shipping your app](shipping-your-app.md)** — build, sign, and distribute on every platform.

Want a fuller reference app to read? [`Examples/HelloPWA`](../../Examples/HelloPWA) in the repo exercises the bridge, a custom command, the tray, and more.
