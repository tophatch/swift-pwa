# Wrapping an existing React / Vite app

**Who this is for:** you already have a web app built with a bundler — Vite, Create React App, SvelteKit (static), Next (static export), whatever — and you want to ship it as a native desktop/mobile app without restructuring your project. swift-pwa wraps your **build output**, so your source tree, tooling, and dev workflow stay exactly as they are.

We'll use Vite + React in the examples, but the shape is identical for any bundler: point swift-pwa at your output directory, develop against your bundler's own dev server, and let swift-pwa rebuild your assets before each native build.

New to swift-pwa? The [Hello, World](hello-world.md) tutorial covers the basics this one assumes.

> Uses swift-pwa **0.8+**.

---

## The big picture

```
  Dev:   npm run dev  (Vite @ :5173, HMR)  ◀── swift-pwa dev --server …  (native window)
  Ship:  swift-pwa build  ──▶ runs `npm run build` ──▶ copies dist/ into the app bundle
```

Two things to internalize:

- **swift-pwa never bundles your JS** — your bundler does. swift-pwa just copies the finished `dist/` (or `build/`) folder into the native app and serves it.
- **In dev, swift-pwa doesn't serve anything** — it points a native window at *your* dev server, so you keep Vite's hot-module reload exactly as-is.

---

## Step 1 — Add the native shell, in place

From the root of your existing app, run `init` with `--in-place`:

```sh
cd my-vite-app
swift-pwa init MyApp --in-place
```

`--in-place` tells swift-pwa to add only the native shell (`Package.swift`, `Sources/MyApp/`) *next to* your existing files and leave everything else — `src/`, `package.json`, `vite.config.js` — untouched.

> **Why `--in-place` is required here.** swift-pwa auto-adopts a folder only if it already contains a `web/` directory or a `pwa.json`. A typical Vite project has neither (it has `src/` and `index.html` at the root), so without the flag `init` would nest a brand-new project under `MyApp/` — not what you want. The flag forces adopt-in-place. (If you *do* already have a `pwa.json` or `web/`, adoption happens automatically and the flag is optional.)

You'll now have a `pwa.json` and a `Sources/MyApp/App.swift` alongside your app.

---

## Step 2 — Point swift-pwa at your build output

Edit the `web` block in `pwa.json` so `directory` is wherever your bundler emits — `dist` for Vite, `build` for CRA:

```json
"web": { "directory": "dist", "entry": "index.html" }
```

swift-pwa copies that directory **verbatim** into the app bundle and serves it. The `entry` is the HTML file to open (relative to `directory`).

> ⚠️ **The directory must exist and be populated when you build.** If `dist/` isn't there at `swift-pwa build` time (you forgot to build your frontend), swift-pwa **silently skips** copying it and you get a blank/erroring window at runtime instead of a build error. Step 4 wires this up so it can't happen — but it's the #1 gotcha, so know it's coming.

---

## Step 3 — The dev loop (keep your HMR)

Run two terminals. First, your bundler's dev server, exactly as you always do:

```sh
npm run dev            # Vite on http://localhost:5173, with hot reload
```

Then point a native swift-pwa window at it:

```sh
swift-pwa dev --server http://localhost:5173
```

That's it — the native window loads your Vite dev server, and **Vite's own HMR drives the refresh**. Edit a component, save, watch it update in the native window. (Under the hood, `--server` sets a `PWA_DEV_SERVER` env var that the generated `App.swift` checks: when it's set, the window loads that URL; in a real build it falls back to your bundled assets.)

> **Testing bridge calls in dev:** the `__SWIFT_PWA__` bridge is injected into the native window, so `invoke`/`subscribe` work while you develop *through `swift-pwa dev`*. If you open `http://localhost:5173` in a plain browser tab, there's no bridge there — so guard native calls when you want the app to also run in a browser:
> ```js
> if (window.__SWIFT_PWA__) {
>   await __SWIFT_PWA__.invoke('window.setTitle', { title: 'Native!' });
> }
> ```

---

## Step 4 — Build for real (rebuild assets automatically)

You *could* run `npm run build` by hand before every `swift-pwa build`, but it's easy to forget (and then hit the Step 2 gotcha). Instead, let swift-pwa run it for you via `build.prebuild` in `pwa.json`:

```json
"build": {
  "prebuild": "npm run build"
}
```

Now every `swift-pwa build` runs `npm run build` first, regenerating `dist/` right before it's copied in. If your build fails, swift-pwa aborts rather than shipping stale or missing assets:

```sh
swift-pwa build                # runs `npm run build`, then bundles for your OS
```

(For a quick native rebuild when you *know* `dist/` is current, `--skip-prebuild` bypasses it.)

> **CI note:** the release workflow `swift-pwa init` generates installs the *Swift* toolchains, not Node. Since `build.prebuild` runs on every build, add a Node setup step before the build step in each job of `.github/workflows/release.yml`:
> ```yaml
> - uses: actions/setup-node@v4
>   with: { node-version: 20 }
> - run: npm ci
> ```
> Full CI + shipping detail: [Shipping your app](shipping-your-app.md).

---

## Step 5 — The one thing to fix in your app: routing

Your app is served from a custom origin (`pwa://localhost/` on Apple/Linux, `https://swift-pwa.local/` on Windows/Android), and **there's no server-side SPA fallback** — swift-pwa serves files that exist on disk, and only maps the bare root to `index.html`. That has one practical consequence for single-page-app routers:

- **Client-side navigation works fine** — clicking `<Link>`s, `history.pushState`, etc. all stay in memory and never hit the "server."
- **But a hard reload (or first load) of a *nested* path** like `/settings` will 404 in **history/`BrowserRouter` mode**, because there's no `settings` file on disk and nothing rewrites it back to `index.html`.

**The fix is one line: use hash-based routing.** With React Router, that's `createHashRouter` (or `<HashRouter>`); the route lives in the URL fragment (`…/index.html#/settings`), which never becomes a file lookup, so reloads and deep links just work:

```jsx
import { createHashRouter, RouterProvider } from 'react-router-dom';
const router = createHashRouter([ /* your routes */ ]);
// <RouterProvider router={router} />
```

(Vue Router: `createWebHashHistory()`. SvelteKit: use the static adapter with a hash-based strategy.)

> **Vite `base`:** the default `base: '/'` is fine — your app is served at the root of its origin, so root-relative asset URLs resolve normally. You don't need to change it. (`base: './'` also works and is a harmless defensive choice if you want the same `dist/` to run from a path-prefixed web host too.)

---

## Recap

1. `swift-pwa init MyApp --in-place` — add the shell, keep your project.
2. `pwa.json` → `web.directory: "dist"` — point at your build output.
3. `npm run dev` + `swift-pwa dev --server http://localhost:5173` — develop with HMR.
4. `pwa.json` → `build.prebuild: "npm run build"` — rebuild assets on every native build.
5. Switch your router to hash mode.

From here, [Shipping your app](shipping-your-app.md) takes you to signed, distributable builds.

---

## Where to go next

- [Talking to the native side](talking-to-the-native-side.md) — call native features from your React components.
- [Making it feel native](making-it-feel-native.md) — window controls, notifications, a tray icon.
- [Shipping your app](shipping-your-app.md) — build, sign, and distribute on every platform.
