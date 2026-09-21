# swift-pwa

Build your app as a web frontend — HTML/CSS/JS, or React/Vue/Svelte — and ship it as a genuine native app on macOS, iOS, Linux, Windows, and Android, all from one Swift package. `swift-pwa` wraps each platform's own system webview in a thin native shell, so there's no bundled browser and downloads stay small (5–15 MB). It's Tauri or Wails for the Swift world, with on-device AI built in.

> **Status:** [`v0.11.2`](https://github.com/tophatch/swift-pwa/releases/tag/v0.11.2) is the current release. macOS 15+, iOS 18+, Linux (GTK3 / GTK4), Windows 11 (WebView2), and Android (API 28+) are all first-class — one Swift package, one JS API, one CLI, five platforms from the same source.
>
> This is young, fast-moving software (pre-1.0, under heavy active development) — expect rapid iteration and the occasional breaking change before 1.0. **Feedback, [issues](https://github.com/tophatch/swift-pwa/issues), and contributions are very welcome** — real-world usage reports are especially valuable at this stage.

Highlights: a [feature matrix](#feature-matrix) of native plugins (files, dialogs, secrets, notifications, subprocess, and more), [built-in on-device & cloud AI](#on-device--cloud-ai) on every platform, an [app driver](docs/tutorials/testing-your-app.md) that screenshots and clicks your real UI from a script or an agent, an [agent-callable tool surface](docs/tutorials/letting-an-agent-use-your-app.md) your users consent to, and per-platform [setup docs](docs/). See [`CHANGELOG.md`](CHANGELOG.md) for the full release-by-release history.

## Why

If you want to ship a web frontend as a real native app on every platform, today's options each make you give something up:

- **Electron** ships an 80 MB Chromium with every download, in JavaScript. Desktop only.
- **Tauri** is small, fast, and reaches mobile — but the native shell is Rust, a steep learning curve if it isn't already your language.
- **Wails** is small and fast in Go — but desktop only.
- **Hand-rolled WKWebView** locks you to Apple, and you're rebuilding the JS↔Swift bridge, the bundler, and the multi-window plumbing yourself.
- **SwiftUI WebView** is single-platform and ships no bridge or bundling story.

`swift-pwa` matches Tauri on the fundamentals — a system webview, a 5–15 MB bundle, and all five of macOS, iOS, Linux, Windows, and Android from one source — and then wins on three fronts:

- **You build in web; the native shell is a thin slice of Swift.** The whole frontend is the web stack you already know — plain HTML/CSS/JS or React/Vue/Svelte — and the wrapper is a small Swift package you rarely touch, shipped everywhere by one CLI (`.app`, `.ipa`, `.AppImage`, a portable Windows `.exe`, MSIX, and an Android project → APK / AAB) with one JS API (`__SWIFT_PWA__.invoke()`). Tauri and Wails wrap a web frontend too, but their shell is Rust or Go — a second systems language to pick up (or hire for) just to get a native window. Swift is a gentle on-ramp if you've ever opened an Xcode project, and for a team already on Apple platforms it's the stack, packages, and models you use every day, now driving Linux, Windows, and Android as well.
- **The native capabilities a real app needs are built in.** A web page can't touch the filesystem, the system tray, or a fingerprint reader — swift-pwa hands them to your JS through opt-in plugins: local files and native Open/Save dialogs, secrets in the OS keychain (Keychain / Keystore / DPAPI / libsecret), biometric auth (Touch/Face ID, Windows Hello, Android fingerprint), clipboard, tray icons, native notifications, subprocesses, server-push events, and a CORS-free HTTP client — each adapted to every platform's conventions and App Store friendly (it bundles to store-ready `.ipa`, `.aab`, and MSIX artifacts, using the system webview and sanctioned native APIs). See the [feature matrix](#feature-matrix) for what lands where, and **image conversion** for photos the webview itself cannot display (`image.*` — HEIC renders in only one of the four engines, while the platform underneath usually decodes it).
- **AI is a framework feature, not an integration you assemble.** The whole [`ai.*` API](#on-device--cloud-ai) — on-device text, image generation / editing / segmentation, and cloud and LAN providers — ships with the framework, cross-platform. In Electron / Tauri / Wails, local inference is DIY: bundle a sidecar, stand up a Python backend, or reach for a third-party plugin. The same goes for the other direction: your app can [offer its own commands to an AI agent](docs/tutorials/letting-an-agent-use-your-app.md) as MCP tools, behind a build-checked allowlist and your user's consent, without writing a server.

|                   | **swift-pwa**       | Tauri    | Wails    | Electron |
|-------------------|---------------------|----------|----------|----------|
| Host language     | Swift               | Rust     | Go       | Node.js  |
| Webview           | System              | System   | System   | Bundled  |
| Bundle size       | ~5-15 MB            | ~5-15 MB | ~5-15 MB | ~80+ MB  |
| macOS             | Yes                 | Yes      | Yes      | Yes      |
| Linux             | Yes                 | Yes      | Yes      | Yes      |
| Windows           | Yes                 | Yes      | Yes      | Yes      |
| iOS               | Yes                 | Yes      | No       | No       |
| Android           | Yes                 | Yes      | No       | No       |
| On-device AI      | Built-in (`ai.*`)   | DIY      | DIY      | DIY      |

### The bar every feature is held to

**A capability should work on every platform an adopting app targets, and ask
the developer for as little as possible — ideally nothing beyond the standard
web API they would write anyway.**

Most people shipping to five platforms don't own five platforms to test on, so a
feature that quietly works on three of them isn't a bug they can report — it's a
gap they never find. Two things follow, and they shape what lands here:

- **Where a web API already exists, the job is to make it true everywhere**
  rather than to invent a parallel one. An API beside the standard one forces
  every app to carry a branch, and the branch breaks on the platform its author
  doesn't have.
- **Where no web API exists**, the plugin is adapted to each platform's own
  conventions rather than ported literally from whichever one was written first.

## Quickstart

Grab a release binary and scaffold a project:

```bash
# Pick the asset for your platform from
# https://github.com/tophatch/swift-pwa/releases/latest
# (macOS arm64 example):
curl -L https://github.com/tophatch/swift-pwa/releases/latest/download/swift-pwa-macos-arm64 \
    -o /usr/local/bin/swift-pwa
chmod +x /usr/local/bin/swift-pwa

swift-pwa init MyApp
cd MyApp
```

Other available assets: `swift-pwa-macos-x86_64`, `swift-pwa-linux-x86_64`, `swift-pwa-windows-x86_64.exe` (added to the release matrix in v0.3). See [docs/windows-setup.md](docs/windows-setup.md) for the Windows toolchain.

Once it's on your `PATH`, update in place anytime with **`swift-pwa self-update`** (macOS / Linux) — it resolves the latest release, verifies the download, and installs it with an atomic rename, which sidesteps a macOS code-signing-cache quirk that makes a plain `cp` overwrite crash with `Killed: 9`. Pin a version with `--version vX.Y.Z`.

Or build the CLI from source (works on every platform, including Windows on ARM64):

```bash
git clone https://github.com/tophatch/swift-pwa
swift run --package-path swift-pwa swift-pwa init MyApp
cd MyApp
```

You get a self-contained SwiftPM project:

```text
MyApp/
├── Package.swift                      # depends on SwiftPWA
├── pwa.json                           # source of truth — generates Info.plist / .desktop / bundle metadata
├── Sources/MyApp/App.swift            # @main entry point; creates a window pointing at web/
├── .github/workflows/release.yml      # push a tag → build every desktop platform in CI
└── web/
    └── index.html                     # your frontend's entry point
```

That `release.yml` means you can ship cross-platform from any machine: `git tag v1.0.0 && git push --tags` builds macOS, Linux, and Windows in GitHub Actions and attaches them to a Release — no local Swift / MSVC / GTK toolchains needed. (iOS / Android are included as opt-in stubs since they need signing / a cross-compile SDK.) Opt out with `init --no-ci-workflow`; add it to an existing project later with `swift-pwa generate-ci`.

`build` operates on this scaffold — it runs `swift build` against `Package.swift`, so `pwa.json` + `web/` on their own aren't buildable. Already have a web app? `init` adopts it automatically — run it from a directory that already has a `web/` or `pwa.json` and it adds only the native shell (`Package.swift` + `Sources/`), leaves your `web/` untouched, and merges any missing fields into an existing `pwa.json` rather than overwriting it:

```bash
cd my-existing-web-app   # has web/ (or a hand-written pwa.json) already
swift-pwa init MyApp     # detects the existing app and adopts it in place
```

Pass `--in-place` to force this for a frontend in a non-standard layout (e.g. a custom `dist/` with no `pwa.json` yet).

### Where the web source goes

Anything in `web/` is your PWA frontend — plain HTML/CSS/JS, or the build output of React/Vue/Svelte/whatever. The bundler copies the directory verbatim into the app and serves it through a custom `pwa://localhost/` scheme so relative URLs resolve cleanly without needing a local dev server.

To point at a different directory (e.g. `dist/` from a Vite build), edit the `web` section of `pwa.json`:

```json
"web": { "directory": "dist", "entry": "index.html" }
```

`web.entry` is served at the origin root as well as under its own name, on
every platform — so `location.replace('/')` ("go back to the top") lands on the
app whatever the entry is called. A directory path deeper in the bundle
(`/docs/`) serves its own `index.html` if there is one; a path with no trailing
slash never does.

### Configuring `pwa.json`

`pwa.json` is the single source of truth. `Info.plist`, `.desktop`, bundle identifiers, window dimensions, and icon assets are all generated from it.

```json
{
    "id": "com.example.myapp",
    "name": "My App",
    "version": "0.1.0",
    "description": "An optional one-liner.",
    "icon": "icon.png",
    "web": { "directory": "web", "entry": "index.html" },
    "window": {
        "title": "My App",
        "width": 1024,
        "height": 768,
        "resizable": true,
        "fullscreen": false,
        "background_color": "#F4F7F5",
        "remember_state": true
    },
    "macos": {
        "bundle_identifier": "com.example.myapp",
        "category": "public.app-category.productivity",
        "minimum_system_version": "15.0",
        "copyright": "© 2026 Acme Corp.",
        "last_window_closed": "reopen"
    },
    "ios": {
        "bundle_identifier": "com.example.myapp",
        "minimum_system_version": "18.0",
        "device_family": [1, 2]
    },
    "linux": {
        "desktop_categories": ["Utility"]
    },
    "external_urls": {
        "schemes": ["things"]
    }
}
```

Required keys: `id`, `name`, `version`, `web`, `window`. The `macos` / `ios` / `linux` sections are optional — omit any platform you don't ship to. `icon` should be a single 1024×1024 PNG — that one file becomes the app icon on every platform: macOS `.icns`, the iOS `AppIcon` (compiled via `actool`), the Android launcher icon (`res/mipmap/ic_launcher.png` + manifest wiring), the Linux AppImage icon, and the Windows portable `.exe` icon (embedded into the PE via `UpdateResource`). Each platform section takes an **`icon`** of its own that overrides it (`"macos": { "icon": "icon-macos.png" }`) — needed because macOS and iOS want opposite artwork: macOS composites nothing, so the rounded-square mask has to be drawn into the PNG with transparent padding around it, while iOS applies its own superellipse and wants full bleed. `category` on macOS is the `LSApplicationCategoryType` UTI shown in the App Store / Finder. `description` and `macos.copyright` populate the **About** panel (the description becomes the body text, the copyright shows under the version).

**Optional `web.spa_fallback`** — opt into single-page-app history routing. The app is served from a custom origin (`pwa://localhost/`, `https://swift-pwa.local/`) that only serves files that exist on disk, so a hard reload / deep-link of a nested history-mode route (e.g. `/settings` under a `BrowserRouter`) 404s. With `"web": { …, "spa_fallback": true }`, a request that names no file **and** looks like a client-side route (no file extension) is served `web.entry` instead — so the app loads and the router takes over. A missing asset (anything with an extension, like a JS chunk) still 404s honestly. Off by default; seeds the generated `App.swift`'s `WindowContent.bundled(spaFallback:)`. Works on all five platforms. (Hash routing — `createHashRouter` etc. — remains an alternative that needs no flag.)

**`name` is the human-facing label** — the `.app` filename, `CFBundleName` / `CFBundleDisplayName`, the `.desktop` `Name=` — and may contain spaces (`"My App"`). The built binary, by contrast, is named after the SwiftPM target in `Package.swift`, which **can't** contain spaces. You don't have to reconcile the two: the bundlers discover the real target name from the package itself (via `swift package describe`), so `"name": "My App"` just works even though the target is `MyApp`. The optional **`executable_name`** is an override for the rare case where discovery is ambiguous — chiefly a package with **more than one executable product**; set it to the target you want bundled. (`linux.executable_name` still overrides this for the Linux backend specifically.)

**`window` is build-time metadata, not the runtime config.** The generated `Sources/<name>/App.swift` builds the window from a `WindowConfig` literal, and *that* is what the running app uses. `init` seeds the literal from `pwa.json`'s `window` block, but editing `pwa.json`'s `window.*` afterwards has **no runtime effect** — change the window in `App.swift` (or keep the two in sync by hand). The fields here drive bundle metadata and the initial scaffold only.

**`window.remember_state`** persists the window's size — and, where the platform allows, position — across launches, restoring it next time (on by default for apps scaffolded with `init`). It maps to `WindowConfig.rememberState` in `App.swift`; geometry is saved to a `window-state.json` in the per-app data directory. **Desktop only:** macOS / GTK3 / Windows restore both size and position; GTK4 / Wayland restore size only (the compositor owns placement); iOS / Android windows are full-screen, so it's a no-op. A multi-window app sets a distinct `WindowConfig.stateKey` per window so their frames are tracked separately.

**`window.background_color`** is the colour the native surface is painted before the page's first paint — and, on iOS, the colour of the rubber-band overscroll area, so it stays on screen during every bounce. It takes a hex string, or a light/dark pair that **every** backend now resolves against the live system appearance and re-resolves when the user switches themes: `UIColor` / `NSColor` dynamic providers on Apple, `GtkSettings:gtk-application-prefer-dark-theme` on Linux (measured: WebKitGTK derives the page's own `prefers-color-scheme` from the same property), the `AppsUseLightTheme` theme setting on Windows, and a DayNight resource theme on Android. On iOS the pair also drives the launch screen, via a colour set in the compiled asset catalog.

```json
"window": { "background_color": { "light": "#F4F4F2", "dark": "#0C0D0E" } }
```

**Optional `macos.last_window_closed`** — what the app does when its last window closes: `reopen` (default — stay running and bring the window back when the app is next activated, the way Finder and Safari do), `keep-running` (stay running with no window, for a menu-bar app) or `quit` (terminate, like a single-window utility, and like Linux and Windows already behave). macOS-only, because it's the only platform here where an app outlives its windows. Like `window`, it seeds the generated `App.swift` (`ctx.lastWindowClosed`) at `init` time. See [docs/macos-setup.md](docs/macos-setup.md#what-happens-when-the-last-window-closes-macoslast_window_closed).

**Optional `external_urls`** — which URLs the app may hand to the operating system, and what happens when the page tries to leave the app's own origin. `http`, `https`, `mailto` and `tel` are always allowed; anything else has to be named, because opening a URL launches whatever app is registered for it and the page asking isn't always your own code (`bridge.js` runs in subframes, and a link in user-authored content is written by the user). Seeds `ctx.externalURLs` in the generated `App.swift` at `init` time.

```json
"external_urls": {
    "schemes": ["things", "obsidian"],
    "off_origin_navigation": "system"
}
```

`allow_any_scheme: true` opts out of the allowlist entirely, for an app whose URLs are typed by the person using it rather than written by its own code — there the list can only be a guess. It keeps every other refusal (`pwa:`, `file:`, `javascript:`, the app's own origin), and on backends that report which frame called (macOS and iOS today) it covers the app's own page while content it embeds keeps the allowlist. Where the backend can't report that — both GTK backends genuinely can't — it means any frame, so leave it off for an app that hosts other people's content. See [docs/javascript-api.md](docs/javascript-api.md#systemopenurl--hand-a-url-to-the-operating-system).

`off_origin_navigation` defaults to `system`: a main-frame navigation to another site opens in the system browser and the app stays put, because loading it in place strands the app — no address bar, no back button. Set it to `in-app` for an app that deliberately hosts other people's pages and has its own way back. Same-origin navigation, subframes, and `about:` / `blob:` / `data:` URLs are unaffected. See [docs/javascript-api.md](docs/javascript-api.md#systemopenurl--hand-a-url-to-the-operating-system).

**Optional `build.prebuild`** — a command run from the project root *before* `web/` is staged into the bundle, on every `swift-pwa build` (and so on every cloud release that calls it, no hand-maintained "regenerate before tagging" ritual). Use it for a codegen / asset step that produces part of `web/` — an esbuild / Tailwind pass, a sprite-atlas packer, a generated index. A non-zero exit aborts the build, so a half-generated `web/` never ships. It runs through the platform shell (`/bin/sh -c`, `cmd /c` on Windows); skip it for fast local iteration with `build --skip-prebuild`. If it needs a toolchain (Node, etc.), add a setup step to the generated workflow's jobs.

```json
"build": { "prebuild": "node scripts/build-index.mjs" }
```

**Optional `build.postbuild`** — the symmetric *after-bundling* hook: a command run once the platform artifact exists, with its absolute path in `SWIFT_PWA_ARTIFACT` (and the target in `SWIFT_PWA_TARGET`). Use it to patch the generated bundle without wrapping the whole `swift-pwa build` — e.g. a `PlistBuddy` tweak, extra signing, a checksum. Non-zero exit fails the build; `--skip-postbuild` bypasses it.

```json
"build": { "postbuild": "./scripts/sign-extra.sh \"$SWIFT_PWA_ARTIFACT\"" }
```

**Optional `agent.expose`** — the *ceiling* on what your app may ever offer an AI agent: a reviewable list of your own commands (`book.open`, not "click at 400,300"), each with a one-line description and MCP risk annotations. Off by default — an app that says nothing exposes nothing. It grants nothing on its own; the user still has to turn exposure on at runtime. `swift-pwa build` resolves the list against the app's live command catalog and **fails loud** on a name that doesn't exist, so a typo can't quietly expose nothing and a rename can't quietly un-expose. Run it on its own with `swift-pwa agent check` (`--json` prints the tools as an agent would see them). See [docs/agent-tools.md](docs/agent-tools.md).

```json
"agent": { "expose": [ { "command": "book.open", "description": "Open a book by id.", "read_only": true } ] }
```

**Optional `macos.info_plist` / `ios.info_plist`** — arbitrary keys merged into the generated `Info.plist` (after swift-pwa's own, so they override on collision). The escape hatch for anything the schema doesn't model: App Transport Security, usage strings, custom URL schemes. Use the exact Info.plist key names; nested objects/arrays work.

```json
"macos": { "info_plist": { "NSAppTransportSecurity": { "NSAllowsLocalNetworking": true } } }
```

**Optional `native_include_dirs` / `native_library_dirs`** (`android` / `linux` / `windows`) — the two halves of a native library your app vendors itself, anything the platform doesn't ship and swift-pwa doesn't resolve for you. Headers go on the compile's search path (`-Xcc -I`), which is what lets a C shim's `#include <sqlite3.h>` resolve and is the half the build reaches first; libraries go on the link step's search path *and* their shared libraries are staged into the artifact (`jniLibs/<abi>/`, the AppImage, next to the `.exe`) so the app doesn't link cleanly and then die at load. On Android **`<abi>` is substituted per ABI**, which is what makes a multi-ABI build with a vendored library expressible at all — the bundler links every ABI in one process, so a global search path can only carry one ABI's copy. The alternatives — a `-L` in `unsafeFlags`, or a global `CPATH` / `LIBRARY_PATH` — poison dependency resolution for anything depending on your package, and no longer reach the build under Swift 6.4 respectively. On Apple use a `.binaryTarget` xcframework instead. See [docs/android-setup.md](docs/android-setup.md#vendoring-a-native-library-androidnative_library_dirs).

```json
"android": {
  "native_include_dirs": ["Vendor/sqlite/include"],
  "native_library_dirs": ["Vendor/sqlite/<abi>"]
}
```

**Optional `build.serve`** — serve extra directories on the bundle origin under an app-chosen path prefix, so page JS references runtime-imported content (a downloaded "content pack" of images / video) with an origin-relative URL — `videoEl.src = "/packs/<id>/clip.webm"` — that works unchanged on every backend, streamed with HTTP range requests. `ctx.serveDirectory(_:at:)` is the imperative equivalent, on all five — including a folder the *user* points the app at, wherever it already lives — and Android needs a mount declared here only when it must answer a request made before `configure()` returns (its asset loader is built before any Swift runs). See [docs/swift-api.md](docs/swift-api.md#serving-extra-directories-content-packs).

```json
"build": { "serve": [ { "mount": "/packs", "from": "data/packs" } ] }
```

### Develop with live reload

```bash
swift-pwa dev                      # serves web/ with live reload, launches the app
```

`swift-pwa dev` serves your `web/` directory itself, injects a live-reload client, and refreshes the app whenever you save a file — no JS framework or external server needed (macOS / Linux / Windows). Already using a bundler with its own hot-reload (Vite, etc.)? Point at it instead: `swift-pwa dev --server http://localhost:5173`. (The generated `App.swift` loads the dev URL when `PWA_DEV_SERVER` is set, falling back to the bundled assets in a real build.)

**Start somewhere other than the front door.** `SWIFT_PWA_INITIAL_ROUTE=/doc.html?id=42` opens the app's first window at that path inside the bundle (query and fragment included), instead of `web.entry` — for reproducing a bug report, demoing mid-flow, or landing a test on the screen it's about. It applies to the first window only, and the declared entry stays the SPA-fallback document, so a router-only route still resolves. `swift-pwa drive --route <path>` sets it for you.

The built-in server binds a **fixed port** (`4321`) so the dev origin is stable across launches — that's what lets OPFS / localStorage / IndexedDB **persist between runs** (an OS-assigned port would mint a fresh origin each launch and wipe storage). Override with `--port <n>`, or `--port 0` for the old ephemeral behavior.

### Build and run

```bash
swift-pwa doctor                   # check this machine has the toolchains a build needs
swift run swift-pwa build          # --target defaults to the host (macos/linux/windows)
open ./build/macos/MyApp.app
```

`swift-pwa doctor [--target <platform>]` reports, with a copy-paste fix for each gap, whether the tools a target needs are installed (Xcode for iOS, `linuxdeploy` for AppImages, the Android NDK, etc.) — so a missing prerequisite is a friendly message up front rather than a cryptic mid-build failure. `swift-pwa build` also runs these required-tool checks as a quiet preflight: it stays silent on a healthy machine and, only if something's missing, prints one line pointing you at `doctor` before the compile starts.

`--target` defaults to the desktop platform you're building on, so you can omit it for a host build; pass it explicitly for cross-targets (`--target ios`, `--target android`) or to bundle for another desktop OS.

Each target writes to its **own directory** under `build/` (`build/macos`, `build/ios`, `build/ios-simulator`, `build/linux`, `build/windows`, `build/android`) — the two Apple targets both produce `<name>.app`, so a shared directory meant an iOS build silently overwrote a macOS one and the survivor failed to launch for reasons that pointed at signing. `--output <dir>` still puts the artifact exactly where you say, and a build refuses to overwrite a bundle made for a different platform. `--configuration debug` bundles a debug build (the app driver is compiled into debug only); on macOS, repeating `--arch` produces a **universal** binary (`--arch arm64 --arch x86_64`).

**One-command device loop — `swift-pwa deploy`.** Building an artifact is only half of testing on a device; `deploy` runs the whole last mile — `build` → package → install → launch — in one step. `swift-pwa deploy --target android` cross-compiles, assembles the APK, and `adb install`s + launches it on the connected device (`--device <serial|ip:port>` to choose one, with wireless `adb connect` handled for you); `--target ios --simulator` builds, boots, and installs on a simulator; `--target ios --team <TEAMID>` builds a signed app and installs it on a physical device via `devicectl` (add `--allow-provisioning-registration` and a free personal Apple team mints its own profile — no Xcode round-trip); `--target macos` opens the `.app`. `--no-build` reuses the last artifact for a fast re-install. See [docs/deploy.md](docs/deploy.md).

**Test it from the outside — `swift-pwa drive`.** `drive shot out.png` screenshots the webview, `drive eval "document.title"` runs JS in the page, and `drive click --selector "#save"` / `drag` / `type` / `scroll` deliver *trusted* events into the app — real hit testing, focus, default actions. The capture is the app's own pixels rather than the screen, and input goes into the app's own event queue rather than the system-wide one, so a run happens in a backgrounded or occluded window while you keep using your machine: no frontmost requirement, no screen-recording grant, nothing a CI runner can't do under Xvfb. `drive --background` goes further and keeps the *launch* off screen too — for a suite that starts one app per test file, where thirty-seven windows coming to the front is the whole problem. It works on macOS, Linux GTK3 and Windows, each by its own mechanism; a *hidden* window would render nothing at all, since every engine here throttles `requestAnimationFrame` for a window that isn't on screen, so the mode parks a real one instead. Compiled into debug builds only — so pass `--configuration debug` when you bundle something you intend to drive. `drive --simulator` runs the whole loop on the iOS Simulator (build → install → launch → drive → tear down), which is how an iPad layout gets checked without a redeploy per iteration. `swift-pwa mcp` serves the same verbs to an AI agent as MCP tools, screenshots included as image content, so it can change a stylesheet and *look* at the result. Guide: [testing your app](docs/tutorials/testing-your-app.md); reference: [docs/app-driver.md](docs/app-driver.md).

**Offer your app to an agent — `agent.expose`.** A shipped app can hand an AI agent its *own* verbs (`book.open({ id })`, not "click at 400,300"): typed, a finite list you chose, and stable across a redesign. Two gates, because they're two different people's decisions — you set the ceiling in `pwa.json` (off by default, and `swift-pwa build` resolves it against your app's real command catalog so a typo or a rename fails the build instead of silently changing what's offered), and your user opens the door at runtime from your own consent UI (off at launch, per session, revocable, with a tray indicator the app can't suppress). `swift-pwa mcp --agent` serves it to any MCP host — no HTTP server in your binary. Guide: [letting an agent use your app](docs/tutorials/letting-an-agent-use-your-app.md); reference: [docs/agent-tools.md](docs/agent-tools.md).

For codesigning, device deployment, and Linux GTK setup, see [Platform setup](#platform-setup).

## Feature matrix

`Yes` = first-class. `Partial` = works with documented caveats (footnoted; per-platform detail in the matching [docs/&lt;platform&gt;-setup.md](docs/)). `—` = not applicable.

| Capability                    | macOS                   | iOS                          | Linux GTK3                 | Linux GTK4              | Windows                  | Android                  |
| ----------------------------- | :---------------------: | :--------------------------: | :------------------------: | :---------------------: | :----------------------: | :----------------------: |
| Webview                       | WKWebView               | WKWebView                    | WebKitGTK 4.1              | WebKitGTK 6.0           | WebView2 (Edge)          | android.webkit.WebView   |
| Min OS / runtime              | macOS 15                | iOS 18                       | Ubuntu 22.04+ / Fedora 36+ | GTK 4.10+               | Win10 21H2+ + WebView2   | API 28 (Android 9)       |
| JS↔Swift bridge               | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| Multi-window                  | Yes                     | Partial¹                     | Yes                        | Yes                     | Yes                      | —⁷                       |
| DevTools (`Cmd/Ctrl+Alt+J`)   | Yes                     | —                            | Yes                        | Yes                     | Yes                      | Remote⁸                  |
| Per-Monitor V2 DPI            | —                       | —                            | —                          | —                       | Yes                      | —                        |
| `WindowPlugin`                | Yes                     | Yes                          | Yes                        | Partial²                | Yes                      | Partial⁷                 |
| `window.snapshot`³⁵           | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `AppPlugin` (`app.quit` …)    | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| User documents folder³⁴       | ~/Documents             | In-app                       | XDG                        | XDG                     | Documents                | /sdcard/Documents        |
| `ClipboardPlugin`             | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| Links out / JS dialogs²⁹      | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `EventsPlugin` (server push)  | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `DialogPlugin`                | Yes                     | Partial³                     | Yes                        | Yes⁴                    | Yes                      | Partial¹⁰                |
| `FsPlugin`                    | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| File associations²¹           |           Yes           |             Yes              |            Yes             |           Yes           |           Yes            |           Yes            |
| Deep links in³⁰               | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `ProcessPlugin` (subprocess)  | Yes                     | —¹²                          | Yes                        | Yes                     | Yes                      | —¹²                      |
| `NetPlugin` (`net.*` HTTP)    | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `SecretsPlugin` (`secrets.*`) | Keychain                | Keychain                     | libsecret¹³                | libsecret¹³             | DPAPI                    | Keystore                 |
| `AuthPlugin` (`auth.*`)³²     | Yes                     | Yes³²                        | Yes                        | Yes                     | Yes                      | Yes                      |
| `ImagePlugin` (`image.*`)²⁸   | ImageIO                 | ImageIO                      | stb + libheif²⁸            | stb + libheif²⁸         | WIC                      | BitmapFactory            |
| `AIPlugin` — text¹⁴           | Foundation Models       | Foundation Models            | llama.cpp                  | llama.cpp               | Phi Silica¹⁵             | Gemini Nano              |
| `AIPlugin` — images¹⁶         | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `AIPlugin` — audio²⁰          | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `navigator.audioSession`³¹    | Yes                     | Yes                          | Recorded³¹                 | Recorded³¹              | Recorded³¹               | Audio focus              |
| `navigator.mediaSession`³¹    | Yes                     | Yes                          | MPRIS                      | MPRIS                   | SMTC                     | MediaSession             |
| `VisionPlugin`¹⁷              | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `AIWorkflowPlugin`¹⁸          | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| `TrayPlugin`                  | Yes                     | —                            | Yes                        | Yes¹⁹                   | Yes                      | —                        |
| `NotificationsPlugin`         | Yes⁵                    | Yes⁵                         | Yes                        | Yes                     | Yes                      | Yes                      |
| Web permissions²⁵            | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| All-files access³³           | Granted                 | Unavailable                  | Granted                    | Granted                 | Granted                  | Settings                 |
| `GeoPlugin` (`geo.*`)²⁶      | CoreLocation            | CoreLocation                 | GeoClue 2                  | GeoClue 2               | WinRT Geolocator         | LocationManager          |
| `BLEPlugin` (`ble.*`)²⁷       | CoreBluetooth           | CoreBluetooth                | BlueZ                      | BlueZ                   | WinRT Bluetooth          | BluetoothGatt            |
| `BiometricAuthPlugin`         | Touch / Face ID         | Touch / Face / Optic ID      | —                          | —                       | Windows Hello            | Fingerprint / Face¹¹     |
| `UpdaterPlugin` (runtime)     | Yes⁶                    | Untested⁶                    | Yes⁶                       | Yes⁶                    | Yes⁶                     | Yes (PackageInstaller)   |
| `swift-pwa updater` CLI       | Yes                     | Yes                          | Yes                        | Yes                     | Yes                      | Yes                      |
| Bundler artifact              | `.app`                  | `.app` / `.ipa`              | `.AppImage`                | `.AppImage`             | Portable / MSIX          | Gradle project → APK/AAB |
| Code-signing pass-through     | `codesign`              | `codesign`                   | —                          | —                       | `signtool`               | Gradle `signingConfigs`⁹ |
| App driver (`drive`/`mcp`)²²  |           Yes           |          Partial²²           |            Yes             |        Partial²²        |           Yes            |           —²³            |
| Agent tools (`agent.*`)²⁴     |           Yes           |              —               |            Yes             |           Yes           |           Yes            |           —²⁴            |

1. iOS UIScene single scene polished, multi-scene scaffolded.
2. `Window.position()` / `setPosition` / `.didMove` are no-ops on GTK4 (Wayland refuses to give apps their own position).
3. iOS has no system *save panel*, so `dialog.saveFile` (which hands back a path for the app to write) is a no-op there. Use `dialog.exportFile` instead — it presents `UIDocumentPickerViewController` and does the write, giving iOS a real save/share UX (added v0.7.9; the same command works on every platform). A location the user picks outside the app container is security-scoped: the runtime holds that grant for the session, and an app that wants the folder back on a later launch stores the `bookmark` the pick returned (`dialog.resolveBookmark`). Detail: [docs/javascript-api.md](docs/javascript-api.md#dialog).
4. GTK4 dialogs require GTK 4.10+ (`GtkAlertDialog` / `GtkFileDialog`).
5. Apple notifications require a bundled, signed `.app` (`UNUserNotificationCenter` rejects unsigned processes).
6. **macOS**, **Linux** (AppImage), and **Windows** (portable) are verified end-to-end — a real check→download→Ed25519-verify→atomic-swap→relaunch cycle on each (macOS ad-hoc + codesigned; Linux including the cross-filesystem EXDEV copy-then-rename fallback; Windows portable `Move-Item` swap). Android's `PackageInstaller` path is exercised. **Windows MSIX** is compile-verified — its `Add-AppxPackage` install path is preview (full E2E needs a signed package + a trusted cert + sideloading). **iOS**'s `itms-services://` path needs an enterprise cert. The publishing CLI is fully tested. Full breakdown: [docs/auto-updates.md](docs/auto-updates.md).
7. Most `Window` shape APIs (`setSize`, `setPosition`, `minimize`, etc.) are no-ops — the platform owns those decisions; multi-window spawns a new Activity per `createWindow`. Detail: [docs/android-setup.md](docs/android-setup.md) §6.
8. Android `WebView` has no programmatic DevTools window; debug via `chrome://inspect` on a connected host. `webView.openDevTools()` logs an `adb`-friendly hint.
9. Driven by `pwa.json`'s `android.signing` (or `--sign` / `--android-key-alias` CLI overrides) with passwords from environment variables. Full wiring + CI pattern: [docs/android-setup.md](docs/android-setup.md) §7.
10. Android `dialog.openFile` / `saveFile` / `openDirectory` use the Storage Access Framework and return `content://` URIs rather than filesystem paths; `Fs` routes those URIs through `ContentResolver` transparently. A SAF grant dies with the task, so a URI an app means to reuse after a restart is kept as the `bookmark` the pick returned, backed by a persisted permission. Detail: [docs/android-setup.md](docs/android-setup.md) §6.1.
11. Android's `BiometricManager` doesn't distinguish fingerprint / face / iris — `BiometricKind` is `.unknown` when available. Gate JS on `available`, not `kind`. `allowDeviceCredential: true` on both `biometric.*` commands also accepts the account password / passcode / PIN, so a lock the app set can't become un-openable; Windows Hello already offers its PIN either way.
12. `ProcessPlugin` needs to spawn OS processes; the iOS / Android sandboxes forbid it, so `process.*` reports `E_UNIMPLEMENTED` there. Desktop only.
13. `SecretsPlugin` stores: Apple **Keychain**, Android **Keystore** (`EncryptedSharedPreferences`), Windows **DPAPI** (user scope), Linux **Secret Service** (libsecret → GNOME Keyring / KWallet). Two runtime needs: Windows DPAPI needs an interactive user session (a network/SSH logon lacks the master key); Linux needs a running Secret Service (a desktop keyring — headless servers have none, where calls return `E_SECRETS`). Registered without a store it falls back to `NoneSecretStore` (every call `E_SECRETS`). Detail: [docs/secrets.md](docs/secrets.md).
14. `AIPlugin` is opt-in (`ctx.use(AIPlugin(…))`). Text uses each platform's built-in model; portable **llama.cpp** (`ai.local_llama`) is also available on macOS / iOS / Linux / Windows (Metal on Apple, Vulkan GPU on Linux + Windows x64, CPU on Windows arm64) — not on Android. See [docs/ai-plugin.md](docs/ai-plugin.md).
15. Windows **Phi Silica** (`ai.phi_silica`) needs an MSIX build **and** a Microsoft Limited-Access-Feature token; the unpackaged fallback is llama.cpp. See [docs/ai-plugin.md](docs/ai-plugin.md).
16. `ai.generateImage` (text→image / img2img / inpaint): on-device via the shared **ONNX Runtime** tier (`ai.local_onnx_runtime` — Stable Diffusion + LaMa), optionally GPU-accelerated on Linux / Windows desktop (`ai.onnx_gpu` — DirectML / CUDA); plus cloud / LAN providers (Imagen, ComfyUI, any REST image API) over `net.*`. Real-weights verification is documented on macOS / desktop + Android. See [docs/remote-ai.md](docs/remote-ai.md).
17. On-device promptable segmentation (MobileSAM) on the same ONNX Runtime tier (`ai.local_onnx_runtime`); the `ai.onnx_gpu` desktop-GPU tier applies here too.
18. `AIWorkflowPlugin` imports and runs remote workflows (e.g. ComfyUI) with live per-step progress, over `net.*` (WebSocket progress via `URLSessionWebSocketTask`, or an OkHttp RPC on Android).
19. GTK4 dropped `GtkStatusIcon`, so the GTK4 tray speaks the StatusNotifierItem + `com.canonical.dbusmenu` D-Bus protocols directly over GDBus (no `libayatana-appindicator` dependency). It needs a panel that implements a StatusNotifierHost — Plasma, Sway/waybar, XFCE, etc. do; bare GNOME Shell needs the AppIndicator extension. Where none is present the icon is simply not shown (no crash). Detail: [docs/linux-setup.md](docs/linux-setup.md).
20. `ai.generateAudio` (text→speech / TTS): on-device via the shared **ONNX Runtime** tier (`ai.local_onnx_runtime`), backend **`SwiftPWAQwenTTS`** (Qwen3-TTS 0.6B, Apache-2.0), opt-in like the image backends. Fetch the ~2.5 GB pipeline with a checksum-pinned **`ai.ensureModel`** download tier (`QwenTTSBackend(cacheDirectory:source:)`, published on the `qwen-tts-vendor` release) or point it at a locally-staged model directory (`QwenTTSBackend(modelDirectory:)`). Verified against real weights on macOS (fixed-path + download tier) and **device-verified on Android** (the `CritterFacts` demo downloads the pipeline and synthesizes speech on-device). See [docs/ai-plugin.md](docs/ai-plugin.md).
21. An OS-launched file reaches the `app.openFile` JS channel on every platform. The *declaration* is generated from `pwa.json`: macOS / iOS via the `info_plist` passthrough (`CFBundleDocumentTypes`), Android via `android.document_types` (intent filters), Linux via `linux.document_types` (`.desktop` `MimeType=` + `Exec … %F`), Windows via `windows.document_types` (MSIX `<uap:FileTypeAssociation>`, or a `register-file-types.cmd` for the portable exe). Walkthrough: [docs/tutorials/opening-files-with-your-app.md](docs/tutorials/opening-files-with-your-app.md).
22. `swift-pwa drive` / `swift-pwa mcp` are **development** tools, compiled into debug builds only (a release binary doesn't contain the driver at all). *Screenshots* work on all four desktop backends and on iOS, both simulator and device — each backend's own renderer snapshot, not the screen. *Synthetic input* (`click` / `drag` / `type` / `scroll`) now works on all four desktop backends, but not the same way, which `drive info` reports as `input.delivery`. macOS, GTK3 and Windows deliver into the app's own event queue (`appQueue`) — no frontmost requirement, the real cursor never moves; Windows gets there through the DevTools protocol, since WebView2's `SendPointerInput` needs a composition controller swift-pwa doesn't create. **GTK4 is `displayServer`**: it removed public event synthesis outright, so input goes through XTEST, which means the window must hold input focus, the pointer really moves, and a native Wayland session reports no input at all (X11 and XWayland only) — fine under Xvfb, which is where CI runs. Two limits worth knowing: the clipboard can't be driven on Windows (a driven Ctrl+X runs the edit but nothing reaches the system clipboard — a real keystroke still works), and **iOS has no public event-synthesis API at all**, so dispatch DOM events through `eval` there. On iOS both the simulator (`drive --simulator`) and a **physical device** (`drive --target ios`) run the whole loop — build, install, launch, drive (`eval`, `shot`, `windows`, `--route`), tear down. A device needs a **USB cable**, because the control socket is on the device's own loopback and only usbmuxd's USB transport relays into it (`devicectl` has no port-forwarding verb at all), and the app must stay frontmost — iOS suspends a backgrounded app, and a verb sent to one waits rather than failing. Guide: [docs/tutorials/testing-your-app.md](docs/tutorials/testing-your-app.md); reference: [docs/app-driver.md](docs/app-driver.md).
23. Android apps have been programmatically drivable since `setWebContentsDebuggingEnabled(true)` put the page on a CDP socket — see [docs/android-on-device-testing.md](docs/android-on-device-testing.md). The driver doesn't replace it.
24. Desktop only, and unlike the driver this **ships in release builds**. Two gates: an `agent.expose` allowlist in `pwa.json` (off by default, resolved against the app's real command catalog at build time) and runtime consent from the user (off at launch, per session, revocable). While access is open the runtime shows a system-tray status item the app can't suppress — which is why iOS and Android are out, along with the relay being a desktop CLI. Device-verified on **macOS**; the other desktop backends compile and share the same Core implementation. Guide: [docs/tutorials/letting-an-agent-use-your-app.md](docs/tutorials/letting-an-agent-use-your-app.md).
25. Camera / microphone / location, declared once (`ctx.permissions.declare` plus `permissions.web` in `pwa.json`, cross-checked at build time) and answered at each backend's own permission seam — before 0.10 nothing answered them, so three platforms denied silently. Your page keeps using its own `getUserMedia`; only the permission is unified. Includes an app-level veto that sits **above** the OS prompt. Verified on real hardware on all five. Guide: [docs/tutorials/using-the-camera-and-location.md](docs/tutorials/using-the-camera-and-location.md); reference: [docs/permissions.md](docs/permissions.md).
26. Opt-in plugin (`geo.current` / `geo.watch`). Location gets a plugin rather than the web API because **macOS** WKWebView offers an embedder no way to grant `navigator.geolocation` — measured in one process, with location authorized, the plugin returns a fix while the web API still reports a user denial. On Linux it needs a running GeoClue **agent** (a desktop session has one; an SSH session doesn't). Fixes verified on all five platforms.
27. Opt-in plugin (`ble.scan` / `ble.connect`), central role only. Unlike the rest of the device surface there is **no web fallback**: Web Bluetooth has never shipped in WKWebView, and Android's embedded WebView doesn't expose it either — so this is the difference between the capability existing and not existing, and it's declared under `permissions.device` rather than `permissions.web`. A connection is a duplex bridge session; UUIDs are canonicalized to 128-bit lower-case in both directions, because each platform spells them differently and a page written against one silently matches nothing on the others. Scan + connect + subscribe + write + read verified on all five. See [docs/bluetooth.md](docs/bluetooth.md).
28. `image.*` decodes with the platform's own codec and re-encodes as PNG/JPEG, for images the webview itself cannot display — **HEIC renders in only one of the four engines** (Apple's), while ImageIO *and* Android's BitmapFactory both decode it. Opt-in (`SwiftPWAImage` + `ImagePlugin(PlatformImageTranscoder())`). Windows goes through **WIC**, and Linux through the vendored stb (PNG/JPEG) plus **libheif**, which is `dlopen`ed rather than linked — so HEIC/AVIF need no `libheif-dev` at build time and no bundled `.so`, and are simply absent on a machine without it. Both were measured on real boxes: WebView2 refuses a HEIC and renders the converted JPEG, and both Linux boxes decode HEIC and AVIF. Because the answer is per-*machine* on those two platforms (Windows needs the HEVC codec extension, libheif needs its codec plugins), `image.info` reports what is actually available — ask rather than assume. See [docs/javascript-api.md](docs/javascript-api.md).
29. An off-origin main-frame navigation opens in the system browser instead of loading in place (which strands the app — no address bar, no back button); `system.openURL` hands any declared URL to the OS; and `alert()` / `confirm()` / `prompt()` show a real dialog. One shared Core policy (`ctx.externalURLs`, seeded from `pwa.json`'s `external_urls`) decides which schemes may be handed out, because opening a URL launches whatever app claims it and `bridge.js` runs in subframes too — and a URL on the app's *own* origin is refused, which matters on Windows and Android where the bundle is served over `https`. **The dialogs needed implementing only on Apple**: `WKWebView` is the one engine here with no built-in JavaScript panel; WebKitGTK, WebView2 and Android's WebView all show their own (each measured). On Linux a link clicked *inside* a cross-origin iframe also opens externally, because WebKitGTK's navigation decision carries no frame information — see [docs/linux-setup.md](docs/linux-setup.md#links-out-of-the-app). Verified on real hardware on all five.
30. The receiving end of the same capability: a `myapp://…` link the OS routes to the app arrives on the `app.openURL` JS channel, emitted **retained** so a link that *launched* the app isn't lost before the page subscribes. One top-level `url_schemes` list covers all five platforms — a URL scheme is the same string everywhere, unlike a file type — and `swift-pwa build` turns it into Apple `CFBundleURLTypes`, an Android `ACTION_VIEW` + `BROWSABLE` intent-filter, a `.desktop` `x-scheme-handler/…` entry with `Exec … %U`, and an MSIX `windows.protocol` extension (or a `register-url-schemes.cmd` for the portable exe). It is a **separate list from `external_urls.schemes`**: what an app handles and what it may open are different permissions, and most apps want only one. Claiming `https` is refused at build time — that's universal-link / App-Link verification, which needs a file served from the domain. Walkthrough: [docs/tutorials/receiving-deep-links.md](docs/tutorials/receiving-deep-links.md).
31. **Standard web APIs, filled where an engine lacks them** — not a `swiftpwa.*` API beside them, so an adopting app writes `navigator.audioSession.type = 'playback'` once and never branches. All five engines were measured before anything was built ([docs/proposals/audio-plugin.md](docs/proposals/audio-plugin.md)), and the result retired a roadmap item: the web audio stack already delivers raw 128-frame PCM into an `AudioWorklet` at 2.7–10 ms everywhere, so what was missing was *policy*, not a native capture/playback plugin. `audioSession` drives real behaviour on Apple (the engine's own) and Android (mapped onto `AudioManager` audio focus, so `playback` stops other audio and `ambient` leaves it alone); on Linux and Windows it is recorded and reads back but changes nothing, because the playing stream belongs to the webview's *own process* and those platforms set audio policy per-stream by its creator — documented rather than faked, and the behaviours it exists to fix are measured not to happen there. `mediaSession` is the engine's own on four; Android's WebView doesn't expose it at all, so it is filled over a platform `MediaSession` + `Notification.MediaStyle`, artwork included. **`setSinkId` is deliberately *not* filled** where absent: it is per-*element* while anything a shell can reach is per-*process*, and `'setSinkId' in element` is how a page decides whether to show a device picker — so an inert fill would make apps offer a control that lies. An app that plays audio without declaring a type gets a console warning and a `swift-pwa doctor` note. See [docs/javascript-api.md](docs/javascript-api.md).
32. Opt-in plugin (`auth.authorize` / `auth.exchange`) — the one step of an OAuth 2.0 authorization-code flow an app couldn't do for itself: open the provider's consent page in the **system browser** and catch the redirect back. Not an in-page flow, because Google, GitHub and Microsoft all refuse to render consent inside an embedded webview (RFC 8252 §8.12), so the redirect has to cross a process boundary. Desktop catches it on a **loopback HTTP** listener on an OS-assigned `127.0.0.1` port — nothing to register, which matters most on a portable Windows `.exe`, where a custom scheme would cost the user a `register-url-schemes.cmd` run *before* they could ever finish signing in. Mobile catches a **custom scheme**: iOS through `ASWebAuthenticationSession` (the OS's own sign-in browser, with the cookie-sharing prompt and immediate cancellation), Android through `ACTION_VIEW` onto the `app.openURL` channel. **PKCE (`S256`) and `state` are always on and not configurable** — RFC 7636 is mandatory for native clients precisely because another local app can register the same scheme. `redirect: 'auto'` picks loopback on desktop and **refuses rather than guesses** on mobile, where the scheme is provider-specific (Google's is the reversed client ID) and `url_schemes` never reaches the running process. Registration is one line that compiles on all five. Verified end-to-end on **all five** against a real system browser and a stand-in provider running as its own process, so the PKCE challenge is checked by the far side of the protocol: `Scripts/verify-oauth.sh` / `.ps1` on macOS, both Linux backends and Windows, plus `verify-oauth-android.sh` on a cabled device (firing the real `ACTION_VIEW` Intent) and `verify-oauth-ios.sh`, the only run that exercises `ASWebAuthenticationSession` — and the one that asserts the callback never reaches the `app.openURL` channel. See [docs/auth.md](docs/auth.md).
33. `ctx.permissions.status(.allFiles)` / `.request(.allFiles)`, and `permissions.status` / `permissions.request` from JS — the runtime half of a declaration, for the one capability no web API asks for: reading the user's own files **by path** rather than through a picker. Three answers, because "no" splits in two: `granted` is usable now, `denied` is worth a button (`request` reaches a prompt or a Settings screen), and `unavailable` never becomes granted on this build, so the app needs a different design rather than a button. Linux, Windows and macOS answer `granted` — nothing stands between the app and a path it can already open, and macOS raises its own prompt on the first read of a protected folder. iOS answers `unavailable`: a document picker or a scoped bookmark is the design there. Android is the one that asks — from API 30 `MANAGE_EXTERNAL_STORAGE` is a *special* permission with **no dialog at all**, only a Settings screen the app hands the user to, and `request` resolves when they come back. Declaring it is a store-policy decision as much as a technical one (Play restricts it to apps whose core function needs it); an app that ships without the declaration reads `unavailable`, which is the answer to design the fallback around. See [docs/permissions.md](docs/permissions.md).
34. `app.documentsDir` / `ctx.documentsDirectory()` — the folder an app owns **that the user can see**, as against `dataDir` and `cacheDir`, which are its private containers and are deleted with it. `~/Documents/<App>` on macOS, the XDG documents dir on Linux (read from `user-dirs.dirs`, where the value actually lives, so a localised folder name is honoured), the known Documents folder on Windows (not `%USERPROFILE%\Documents`, which OneDrive redirects), `/sdcard/Documents/<App>` on Android, and the app's own `Documents` container on iOS. Created on first call, and a real path everywhere — so it mounts with `serveDirectory` and streams with ranges, which is what makes it the natural default library location. It reports **`survivesUninstall`**, which is `false` on iOS alone: the visible Documents folder there lives inside the app container and goes with the app, so an app that checks can offer an export instead of implying permanence. **On Android it needs no permission** — since Android 11 an app may create, list and read its own files in shared storage by path, which makes All-files access an upgrade rather than the price of entry; measured on a Fold7 with the permission denied. See [docs/android-setup.md](docs/android-setup.md) and [docs/ios-setup.md](docs/ios-setup.md).

35. `window.snapshot` — the webview's rendered pixels, handed to the *page* as a PNG (`{ pngBase64, width, height, bytes }`), with `window.canSnapshot` to ask first so an app can offer the feature rather than catch an error per call. It exists because the web has no API that rasterises a DOM subtree: the libraries filling that gap re-implement the renderer in JavaScript, which is slow and blind to shadow-root CSS and `@font-face` — and the engine already holds the pixels. Every desktop backend already had the capability for the driver's `screenshot` verb (`WKWebView.takeSnapshot`, `webkit_web_view_get_snapshot`, `ICoreWebView2.CapturePreview`); **Android gained one**, drawing the `WebView` into a `Bitmap` from the Kotlin bridge, because `View.draw` is UI-thread-only and the bridge is what owns the view. It is the *webview's* pixels rather than the screen's, so it works while the window is occluded or in the background and needs no screen-recording permission anywhere. `width` / `height` are **device** pixels — `devicePixelRatio` times the CSS size on a Retina or high-DPI display. Take the snapshot **before** mutating the DOM you want pictured: every backend flushes pending layout first, so one taken after the change shows the change, which is the opposite of what a transition wants. What it costs is almost entirely how well the picture compresses, so it was measured against three pages — a flat one (a floor no real page reaches), a wall of body text (the case it was asked for), and full `crypto.getRandomValues` noise (the ceiling) — timing the whole round trip from the page: snapshot, encode, bridge, decode to an `ImageBitmap`.

    | | flat | body text | noise |
    | --- | ---: | ---: | ---: |
    | macOS, 2048×1536 | 37 ms / 58 KiB | **62 ms / 542 KiB** | 426 ms / 10.5 MiB |
    | iOS Simulator, 1206×2622 | 32 ms / 72 KiB | **61 ms / 447 KiB** | 423 ms / 10.5 MiB |
    | Linux GTK3, 1024×768 | 28 ms / 4 KiB | **54 ms / 220 KiB** | 218 ms / 2.3 MiB |
    | Linux GTK4, 1024×768 | 36 ms / 5 KiB | **81 ms / 331 KiB** | 330 ms / 2.6 MiB |
    | Windows, 2022×1466 | 70 ms / 12 KiB | **239 ms / 528 KiB** | 2135 ms / 8.5 MiB |
    | Android (Fold7), 1968×2056 | 172 ms / 21 KiB | **406 ms / 989 KiB** | 2235 ms / 11.6 MiB |

    The engines split in two. On macOS, iOS and both Linux backends a full-window PNG of a page of text is **~60 ms** and a few hundred KiB — usable for a transition, and the number to design against. **Windows and Android are four to seven times slower** at 239 ms and 406 ms, nine tenths of it inside the call: a three-to-four-megapixel surface, PNG-encoded and (on Android) base64'd across the JNI boundary. A page curl can't start under the finger on those two, so the `rect` and JPEG options this shipped without have a measured case there and none yet on Apple or Linux.

    **Windows returns colour-managed pixels.** `CapturePreview` hands back the *display's* colour space with that display's ICC profile embedded in the PNG, so on a wide-gamut monitor a page's `#0000ff` reads back as `#2200ff` — the same colour, different numbers. It renders correctly; a page that samples the bytes and expects its own sRGB values back will not get them.

    Android also needed a different capture. `View.draw` into a software `Canvas` is the obvious spelling and it **silently misses every GPU layer**: a full-screen `<canvas>` of random noise came back as one flat colour while the DOM around it was captured perfectly. It now goes through `PixelCopy` against the window's composited surface, with `View.draw` kept only as the fallback for a window that isn't on screen — so a page using `<canvas>`, WebGL or video gets its real pixels. `Scripts/verify-window-snapshot.sh` (desktop) and `Scripts/verify-android-window-snapshot.sh` produce this table and check correctness by reading pixels back out of the returned image, which is the part that matters: a blank capture decodes, measures and reports a plausible size exactly like a real one. See [docs/javascript-api.md](docs/javascript-api.md#a-picture-of-your-own-content).

The full per-plugin command surface lives in [docs/javascript-api.md](docs/javascript-api.md) (JS side) and [docs/swift-api.md](docs/swift-api.md) (Swift side). Per-platform setup, codesigning, and the long tail of known limitations live in the [Platform setup](#platform-setup) docs.

## On-device & cloud AI

On-device and cloud AI is a first-class part of the framework, not a bring-your-own integration — all of it reachable from the web app through one `ai.*` JS API:

- **Text generation on every platform** — the built-in OS model (Apple Foundation Models, Android Gemini Nano, Windows Phi Silica) *or* portable llama.cpp (GPU-accelerated via Metal on Apple and Vulkan on Linux + Windows x64; CPU on Windows arm64), behind one flag.
- **On-device image models** — a shared ONNX Runtime tier powers promptable *segmentation*, *inpainting* / editing, and *text→image* generation (SD-Turbo plus the commercially-usable LCM_Dreamshaper, both matched to a diffusers reference), all through a purpose-agnostic `ai.generateImage`. An optional desktop GPU tier (Windows DirectML / Linux CUDA) accelerates them, with transparent CPU fallback.
- **Cloud and LAN image generation, no rebuild** — point a running app at any JSON image API from a descriptor, with presets for Imagen, Gemini image ("nano banana"), OpenAI, and Qwen. API keys live in the OS keychain (Keychain / Keystore / DPAPI / libsecret), never in JS.
- **Run imported AI workflows from the web app** — `ai.run` / `ai.describeInputs` import a ComfyUI graph (or drive Imagen / on-device models) and run it with live per-step progress, cancel, and job recovery — the graph and the connection travel in each call.

Tap-to-segment, tap-to-erase, prompt-to-image, and a live model switcher are all demoed in `Examples/CritterFacts`. Deep dives live in [docs/remote-ai.md](docs/remote-ai.md), [docs/ai-plugin.md](docs/ai-plugin.md), [docs/on-device-ai-performance.md](docs/on-device-ai-performance.md), and the [on-device AI tutorial](docs/tutorials/on-device-ai.md).

## API at a glance

```js
// JS — full reference: docs/javascript-api.md
await __SWIFT_PWA__.invoke('window.setTitle', { title: 'Hello' });
const unsub = __SWIFT_PWA__.subscribe('window.subscribe', {}, (e) => { /* ... */ });

// Server-push events (Swift → JS, all windows) and subprocesses (desktop):
const off = __SWIFT_PWA__.on('library:changed', (payload) => { /* ... */ });
__SWIFT_PWA__.subscribe('process.stream', { command: 'ffmpeg', args: [/* … */] }, (f) => { /* ... */ });

// An iPhone photo the webview can't render, converted by the platform codec:
const { path } = await __SWIFT_PWA__.invoke('image.transcode',
    { path: picked, format: 'jpeg', maxSide: 2048, outputPath: cached });

// Device memory — exact/uncapped RAM (beats navigator.deviceMemory, works on iOS):
const { availableBytes } = await __SWIFT_PWA__.invoke('system.memory');
__SWIFT_PWA__.on('system.memoryPressure', ({ level }) => shrinkCaches(level));
```

```swift
// Swift — full reference: docs/swift-api.md
import SwiftPWA

let runtime = try SwiftPWA.runtime()
try runtime.run { ctx in
    ctx.use(DialogPlugin(SystemDialog()))   // opt-in plugins
    ctx.use(FsPlugin(SystemFs()))
    _ = try ctx.createWindow(.init(
        title: "Hello",
        size: .init(width: 1024, height: 768),
        content: try .bundledWeb(entry: "index.html")   // finds web/ wherever this build put it
    ))
}
```

## Tutorials

Copy-paste-friendly, Swift-optional walkthroughs for common features live in [docs/tutorials/](docs/tutorials/):

- [Hello, World — your first app](docs/tutorials/hello-world.md) — from `init` to a running native app with live reload; understand every generated file. Start here.
- [Talking to the native side](docs/tutorials/talking-to-the-native-side.md) — the JS↔Swift bridge (`invoke` / `subscribe` / `on`) and how to register your own native command.
- [Wrapping an existing React / Vite app](docs/tutorials/wrapping-a-react-or-vite-app.md) — adopt a bundler-built app in place, point at your `dist/`, keep HMR, and handle SPA routing.
- [Saving and loading files (Export / Import)](docs/tutorials/saving-and-loading-files.md) — native Save / Open dialogs over `dialog.*` + `fs.*`, with an automatic browser fallback so one codebase runs everywhere.
- [Opening files with your app (file associations)](docs/tutorials/opening-files-with-your-app.md) — be the app the OS launches for a file type; receive it on the `app.openFile` channel.
- [Receiving deep links](docs/tutorials/receiving-deep-links.md) — be the app the OS opens for a `myapp://` link; receive it on the `app.openURL` channel.
- [On-device AI](docs/tutorials/on-device-ai.md) — wire up the `ai.*` API for local text and image generation, from `ai.info` and model download through streaming output.
- [Calling a cloud API with a stored key](docs/tutorials/calling-a-cloud-api.md) — secure key storage (`secrets.*`) + native CORS-free HTTP (`net.*`), keeping the key out of your web code.
- [Signing in with a cloud provider (OAuth)](docs/tutorials/signing-in-with-a-cloud-provider.md) — open the provider's consent page in the system browser and catch the redirect back (`auth.*`), with PKCE: loopback on desktop, your URL scheme on mobile.
- [Locking your app with biometrics](docs/tutorials/locking-with-biometrics.md) — Touch/Face ID, Windows Hello, Android fingerprint via `biometric.*`, with graceful fallback.
- [Making it feel native](docs/tutorials/making-it-feel-native.md) — window controls, native notifications, and a system-tray icon, with per-platform notes.
- [Multi-window apps](docs/tutorials/multi-window-apps.md) — open and target multiple windows and coordinate between them over `events.*`.
- [Running a command-line tool](docs/tutorials/running-a-command-line-tool.md) — spawn and drive a subprocess (`process.*`) with live output and automatic teardown (desktop-only).
- [Importing content packs](docs/tutorials/importing-content-packs.md) — import a large `.zip` of media at runtime and serve it to the page off disk, with native extraction and re-export.
- [Testing your app from the outside](docs/tutorials/testing-your-app.md) — screenshot the real webview, click a real button, type into a real field, from a script, from CI, or from an agent (`swift-pwa drive`).
- [Letting an agent use your app](docs/tutorials/letting-an-agent-use-your-app.md) — offer an AI agent your app's own commands, with a build-checked allowlist and a consent UI your users decide with.
- [Shipping your app (all platforms)](docs/tutorials/shipping-your-app.md) — build, sign, and distribute on macOS, iOS, Linux, Windows, and Android, plus one-tag cloud releases and an auto-update heads-up.
- [Auto-updates](docs/tutorials/auto-updates.md) — make your app update itself: publish a signed manifest, wire the runtime plugin, drive check/download/install from JS, plus background auto-check and a mandatory-update kill-switch.

## Bundling

```bash
swift run swift-pwa build --target macos                              # → MyApp.app
swift run swift-pwa build --target macos --sign "Developer ID Application: Acme"
swift run swift-pwa build --target ios --simulator                    # unsigned .app for sim
swift run swift-pwa build --target linux                              # → MyApp-x86_64.AppImage
swift run swift-pwa build --target windows                            # → portable folder bundle
swift run swift-pwa build --target windows --package-format msix --arch arm64 --sign <thumbprint>
swift run swift-pwa build --target windows --bootstrap-webview2       # bundle the Evergreen Bootstrapper
swift run swift-pwa build --target android                            # → MyApp-android/ Gradle project
swift run swift-pwa build --target android --cross-compile-android --android-abis arm64-v8a,x86_64
swift run swift-pwa deploy --target android --device 10.0.0.2:5555    # build → APK → install → launch
swift run swift-pwa deploy --target ios --simulator                  # build → boot sim → install → launch
```

`pwa.json` is the source of truth — `Info.plist`, `.desktop`, `AppxManifest.xml`, and icon assets all generate from it. Per-target setup (toolchain, codesign, device install) lives under [Platform setup](#platform-setup). If `pwa.json` declares a [`build.prebuild`](#configuring-pwajson) command, every `build` runs it first.

The `swift-pwa updater` subcommand publishes auto-update manifests (`keygen`, `sign`, `manifest`) — see [docs/auto-updates.md](docs/auto-updates.md). `swift-pwa codegen` generates a typed TypeScript client for the bridge from the `__bridge.describe` command catalog (typed `invoke` / `subscribe` / `session` call sites; `--check` guards drift in CI). `swift-pwa agent check` validates the [`agent.expose`](#configuring-pwajson) allowlist against the app's real command catalog — see [docs/agent-tools.md](docs/agent-tools.md). To update the CLI itself, run `swift-pwa self-update`.

## Roadmap

Shipped work lives in [`CHANGELOG.md`](CHANGELOG.md) — a per-release breakdown from the on-device AI tiers back through the Android backend and the CLI developer-experience passes. What's next, in priority order:

1. **Auto-updates — finish the platform matrix.** The desktop runtime updater is verified end-to-end (macOS, Linux AppImage, Windows portable), background auto-check + a mandatory-update kill-switch have shipped, and **delta (binary-patch) updates** now cut download size on all three desktop backends — Linux AppImage, Windows portable, and macOS (via a cached-tarball base) (see [`CHANGELOG.md`](CHANGELOG.md)). Remaining: **Windows MSIX** full E2E (compile-verified; `Add-AppxPackage` install needs a signed package + trusted cert + sideloading) and **iOS** (`itms-services://`, needs an enterprise cert), plus broader integration coverage. Context: [docs/auto-updates.md](docs/auto-updates.md).
2. **On-device AI: audio backend follow-ups.** The `ai.*` contract is complete and the **text**, **image**, and **audio** backends have all shipped — text on every OS (Apple Foundation Models / Android Gemini Nano / Windows Phi Silica + portable **llama.cpp**), on-device **image** generation + editing via the ONNX Runtime tier (Stable Diffusion text→image, LaMa inpainting), and on-device **text→speech** via `SwiftPWAQwenTTS` (Qwen3-TTS, with a checksum-pinned `ai.ensureModel` download tier, device-verified on Android — see `CHANGELOG.md`). Still open on audio: **arbitrary-reference voice cloning** (mapping the shipped `voiceCloning` / `referenceAudio` contract onto the Qwen Base model), and exercising **Windows Phi Silica** generation end-to-end once a Microsoft LAF token lands. Context: [docs/ai-plugin.md](docs/ai-plugin.md).
3. **Homebrew tap** — `brew install tophatch/tap/swift-pwa` as the idiomatic macOS / Linux install + upgrade story. `swift-pwa self-update` already covers the no-brew and Windows cases.

Per-platform "Known limitations" sections in each [docs/&lt;platform&gt;-setup.md](docs/) cover the long tail.

## Platform setup

Per-platform walkthroughs (toolchain, build, codesign, device install, known caveats):

- **macOS** — [docs/macos-setup.md](docs/macos-setup.md): Xcode 26+, `.app` bundling, Developer ID signing, notarization.
- **iOS** — [docs/ios-setup.md](docs/ios-setup.md): Simulator runtime install, `.app` install via `simctl`, and on-device install + launch via `swift-pwa deploy` (with free-team profile minting).
- **Linux** — [docs/linux-setup.md](docs/linux-setup.md): Ubuntu 24.04+ + Swift 6.0, GTK3 + WebKitGTK 4.1 by default or GTK4 + WebKitGTK 6.0 via `SWIFT_PWA_GTK4=1`, AppImage builds.
- **Windows** — [docs/windows-setup.md](docs/windows-setup.md): Swift 6 on Windows, Visual Studio Build Tools, the WebView2 SDK / static loader, and the portable `.exe` bundler.
- **Android** — [docs/android-setup.md](docs/android-setup.md): Swift 6.2.0 + swift-android-sdk 6.2, NDK r27d, JDK 17 + AGP 8.5, the `@_cdecl` entry-point boilerplate, and the Gradle scaffold the `swift-pwa build --target android` bundler emits. [docs/android-on-device-testing.md](docs/android-on-device-testing.md) covers driving the page from the host over `adb forward` + Chrome DevTools Protocol.

## Contributing

Contributions, bug reports, and feedback are all very welcome — swift-pwa is young, actively developed software, and real-world usage reports (what worked, what broke, what's missing) are some of the most useful things you can send. Open an [issue](https://github.com/tophatch/swift-pwa/issues) for a bug or an idea, or a PR for a fix or feature. See [`CHANGELOG.md`](CHANGELOG.md) for what shipped, what's in `Unreleased`, and the running list of release notes.

```bash
swift test                                     # unit + WebKit integration on macOS
SWIFT_PWA_LINUX_GUI=1 swift test               # GTK integration tests on Linux
```

[docs/contributing.md](docs/contributing.md) is the practical guide — the build/test loop, the **generated files you must regenerate** (e.g. run `Scripts/regenerate-bridge-js.sh` after editing `bridge.js`), and the gotchas that otherwise cost a CI round.

Before tagging a release, walk the manual cases in [docs/manual-test-cases.md](docs/manual-test-cases.md) — they cover the OS-level install machinery, on-device installer flows, and visual smoothness checks that the unit suite can't reach.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
