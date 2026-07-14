# Tutorials

Step-by-step, copy-paste-friendly guides for common things you'll want to add when wrapping a web app with swift-pwa. Written for people who are comfortable in HTML/CSS/JS but **don't need to know Swift** — each tutorial keeps the native (Swift) side to a few clearly-marked lines.

| Tutorial | What you'll build |
|---|---|
| [Hello, World — your first app](hello-world.md) | Go from nothing to a running native app: `init`, understand the generated files, iterate with live reload (`swift-pwa dev`), and build it. Start here. |
| [Talking to the native side](talking-to-the-native-side.md) | Learn the JS↔Swift bridge — `invoke` / `subscribe` / `on` — and register your **own** native command in a few lines of Swift. The concept everything else builds on. |
| [Wrapping an existing React / Vite app](wrapping-a-react-or-vite-app.md) | Already have a bundler-built web app? Adopt it in place, point swift-pwa at your `dist/`, keep your HMR dev loop, auto-rebuild on every native build, and fix the one routing gotcha. |
| [Saving and loading files (Export / Import)](saving-and-loading-files.md) | Native **Save** / **Open** dialogs that write and read a file on disk (e.g. game saves, documents, settings), with an automatic browser fallback so one codebase runs everywhere. |
| [Importing content packs (extract a zip, serve its media)](importing-content-packs.md) | Let users import a large `.zip` of media at runtime: extract it natively to disk (`fs.extractZip`, with zip-bomb / traversal guards) and serve its `<img>` / `<video>` from your app's origin (`ctx.serveDirectory`), range-streamed. |
| [On-device AI (text and images)](on-device-ai.md) | Add on-device AI to your app: use a model we package (`ai.local_llama` + a few lines of Swift), bring your own weights (a different GGUF, your own ONNX pipeline), write your own `AIBackend` (e.g. a cloud fallback), and bake a **LoRA** style into an on-device image model. |
| [Calling a cloud API with a stored key](calling-a-cloud-api.md) | Store an API key in the OS keychain (`secrets.*`) and call any REST API from the native side without CORS (`net.*`) — including how to keep the key out of your web code entirely. |
| [Making it feel native](making-it-feel-native.md) | Add the desktop touches: window controls (title / fullscreen / size / focus events), native notifications, and a system-tray icon with a menu — with per-platform notes so it degrades gracefully. |
| [Shipping your app (all platforms)](shipping-your-app.md) | Get your app into users' hands: build, sign, and distribute on macOS, iOS, Linux, Windows, and Android — plus one-tag cloud releases via GitHub Actions and a heads-up on auto-updates. |

More to come. For the full reference behind these guides, see the [JavaScript API](../javascript-api.md) and [Swift API](../swift-api.md) docs; for per-platform build setup, see the [`*-setup.md`](../) docs.
