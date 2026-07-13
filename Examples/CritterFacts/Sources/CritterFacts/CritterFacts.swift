import Foundation
import SwiftPWA
import SwiftPWAModelStore // ModelSpec
import SwiftPWARemoteAI // RemoteImageBackend + ComfyUIProvider (local + remote switcher)

/// The platform HTTP transport for the `net.*` plugin + the remote image
/// backends. On Android it must route through the Kotlin RPC bridge (swift
/// `URLSession` has no CA store there); everywhere else it's `URLSession`.
/// File-scope + **nonisolated** for the same Android reason as `sdSourceSize`
/// (no local funcs in the `@MainActor` `configure`).
private func makeNetworkClient() -> any NetworkClient {
    #if os(Android)
        AndroidNetworkClient()
    #else
        URLSessionNetworkClient()
    #endif
}

/// The OS secure store for the `secrets.*` plugin — Keychain on Apple,
/// Keystore-backed `EncryptedSharedPreferences` on Android. The Imagen arm
/// reads its API key from here at runtime. File-scope + nonisolated for the
/// same Android reason as `makeNetworkClient`.
private func makeSecretStore() -> any SecretStore {
    #if os(Android)
        AndroidSecretStore()
    #elseif canImport(Security)
        KeychainSecretStore()
    #elseif os(Windows)
        WindowsSecretStore()
    #elseif os(Linux)
        LinuxSecretStore() // Secret Service (libsecret); needs a running keyring
    #else
        NoneSecretStore()
    #endif
}

/// The key name the Imagen API key is stored under in the secure store. Shared
/// by the provider's `apiKey` closure and the availability check.
private let imagenAPIKeyName = "google-ai"

/// The ComfyUI instance the demo's "remote" switcher arm points at. **Adopters:
/// change this to your own instance** (or make it user-configurable). A LAN
/// appliance on plain `http://` also needs the host allow-listed via
/// `android.network.cleartext_domains` in `pwa.json` (already set for `*.local`).
/// No checkpoint is hard-coded — `CompositeAIBackend` discovers the instance's
/// installed checkpoints and lists each as its own `comfy:<ckpt>` model, so the
/// demo works against any box and the picker shows what's actually there.
private let demoComfyURL = URL(string: "http://comfyui.local:8188")!

// The llama backend is an env-gated product (see Package.swift). When the app
// is built with `ai.local_llama` (so SWIFT_PWA_LLAMA is set), the module is in
// the graph and we wire a real on-device backend; otherwise the window still
// opens and the page shows a "build with ai.local_llama" hint.
#if canImport(SwiftPWALlama)
    import SwiftPWALlama
#endif
#if canImport(SwiftPWAPhiSilica)
    import SwiftPWAPhiSilica
#endif
// The on-device segmentation backend (MobileSAMBackend, `ai.vision.*`) —
// env-gated the same way, via `ai.local_onnx_runtime` in pwa.json.
#if canImport(SwiftPWASegmentation)
    import SwiftPWASegmentation
#endif
// The on-device image-edit backend (LaMaBackend, `ai.generateImage`
// inpainting) — same `ai.local_onnx_runtime` gate. Composed with the text
// backend behind one `ai.*` surface (see CompositeAIBackend).
#if canImport(SwiftPWAImageEdit)
    import SwiftPWAImageEdit
#endif
// The on-device text→image backend (StableDiffusionBackend, `ai.generateImage`
// with a bare prompt) — same `ai.local_onnx_runtime` gate. Composed alongside
// LaMa behind the one `ai.*` surface (see CompositeAIBackend / web/generate.html).
#if canImport(SwiftPWAStableDiffusion)
    import SwiftPWAStableDiffusion

    /// Total download size of a Stable-Diffusion model source (sum of its
    /// files), for the picker's `AIModelInfo.availability`. A file-scope
    /// **nonisolated** helper on purpose — a nested function inside the
    /// `@MainActor` `configure` inherits its isolation, and its entry emits a
    /// dynamic executor check that traps on Android (where `configure` runs
    /// under `assumeIsolated` off the real main thread).
    private func sdSourceSize(_ source: StableDiffusionModelSource) -> Int64 {
        source.files.reduce(0) { $0 + $1.sizeBytes }
    }
#endif

#if canImport(SwiftPWALlama)
    /// The downloadable model (tiny, ~400 MB, Apache-2.0) — shared by the
    /// AIPlugin wiring and the headless smoke test.
    let factModelSpec = ModelSpec(
        url: URL(
            string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/"
                + "resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
        )!,
        sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
        fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf"
    )
#endif

@main
struct CritterFactsApp {
    static func main() async throws {
        #if os(Windows) && canImport(SwiftPWAPhiSilica)
            // Headless self-test for the Windows Phi Silica path: one generation
            // on the NPU, print it, exit — no WebView. The Windows analogue of
            // the llama smoke below; the way Phi Silica is verified on a
            // Copilot+ box without driving the WebView2 UI over a remote shell.
            if ProcessInfo.processInfo.environment["CRITTERFACTS_SMOKE"] != nil {
                await runPhiSmoke()
                return
            }
        #elseif canImport(SwiftPWALlama)
            // Headless self-test: build the backend, generate one fact, print it,
            // and exit — no WebView. Verifies the on-device path end to end
            // (including a packaged AppImage's bundled Vulkan loader) without
            // having to drive the UI:
            //   CRITTERFACTS_SMOKE=1 [SMOKE_MODEL=/path/to.gguf] ./CritterFacts…
            if ProcessInfo.processInfo.environment["CRITTERFACTS_SMOKE"] != nil {
                try await runSmoke()
                return
            }
        #endif
        let runtime = try SwiftPWA.runtime()
        try runtime.run(configure)
    }
}

#if os(Windows) && canImport(SwiftPWAPhiSilica)
    /// One headless Phi Silica generation: info → ensure → generate. Writes the
    /// outcome to the file named by `PHI_SMOKE_OUT` (and prints it) so it can be
    /// read back when launched as a packaged app (which has no console). Records
    /// the error rather than crashing, so a policy/availability failure is
    /// captured rather than lost.
    func runPhiSmoke() async {
        var lines: [String] = []
        do {
            let backend = PhiSilicaBackend(
                unlockToken: ProcessInfo.processInfo.environment["PHI_SILICA_LAF_TOKEN"]
            )
            let caps = await backend.info()
            lines.append("PHI_INFO available=\(caps.available) backend=\(caps.backend)")
            for try await _ in backend.ensureModel(AIEnsureModelRequest()) {} // no-op if Ready
            let result = try await backend.generate(AIGenerateRequest(
                system: "You are a witty zoologist. Reply with ONE short, surprising, true "
                    + "sentence. No preamble, no lists, no quotation marks.",
                prompt: "Tell me a fun fact about the octopus.",
                maxTokens: 60,
                temperature: 0.7
            ))
            lines.append("CRITTERFACTS_SMOKE_OK backend=\(result.backend)")
            lines.append("TEXT: \(result.text)")
        } catch {
            lines.append("CRITTERFACTS_SMOKE_ERR \(error)")
        }
        let out = lines.joined(separator: "\n") + "\n"
        print(out, terminator: "")
        if let path = ProcessInfo.processInfo.environment["PHI_SMOKE_OUT"], !path.isEmpty {
            try? Data(out.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
#endif

#if canImport(SwiftPWALlama)
    /// One headless generation. Uses `SMOKE_MODEL` (a local GGUF path) when set,
    /// else downloads `factModelSpec`. Prints the fact; a `CRITTERFACTS_SMOKE_OK`
    /// line on stderr is the success marker. Throws on failure (non-zero exit).
    func runSmoke() async throws {
        let backend: LlamaBackend
        if let path = ProcessInfo.processInfo.environment["SMOKE_MODEL"], !path.isEmpty {
            backend = LlamaBackend(modelPath: path)
        } else {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("critterfacts-smoke", isDirectory: true)
            backend = LlamaBackend(model: factModelSpec, cacheDirectory: dir)
            for try await _ in backend.ensureModel(AIEnsureModelRequest()) {} // drive download
        }
        let result = try await backend.generate(AIGenerateRequest(
            system: "You are a witty zoologist. Reply with ONE short, surprising, true "
                + "sentence. No preamble, no lists, no quotation marks.",
            prompt: "Tell me a fun fact about the octopus.",
            maxTokens: 60,
            temperature: 0.7
        ))
        FileHandle.standardError.write(Data("CRITTERFACTS_SMOKE_OK backend=\(result.backend)\n".utf8))
        print(result.text)
    }
#endif

/// Cross-platform configure closure. `@MainActor` to match the runtime's
/// `run(_:)` signature.
@MainActor
func configure(_ ctx: any AppContext) throws {
    // Build the text backend for this platform (nil if none is in the build).
    let textBackend = makeTextBackend(ctx)

    // Providers for the runtime workflow surface (`ai.run` / `ai.describeInputs`).
    // ComfyUI (a graph provider) is always present; the branches below add the
    // fixed-schema providers — Imagen (cloud) and the on-device image models —
    // so the *same* JS page (web/workflow.html) drives all of them from a picker.
    // Also register **Gemini image ("nano banana")** via the config-driven
    // `RESTImageProvider` + a preset descriptor: no per-API Swift code, and the
    // key never enters JS — the page sends `connection.secretRef: "google-ai"`
    // and the plugin resolves it server-side into the `x-goog-api-key` header.
    var workflowProviders: [any AIWorkflowProvider] = [
        ComfyUIWorkflowProvider(),
        RESTImageProvider(providerID: "gemini-image", spec: .geminiImage())
    ]

    #if canImport(SwiftPWAImageEdit)
        // Image editing is on (`ai.local_onnx_runtime`): compose the text
        // backend and LaMa inpainting behind the one `ai.*` surface — the demo
        // of "an adopter gives AIPlugin more than one purpose" (see
        // CompositeAIBackend). The big-lama ONNX (~200 MB, downloadable) is
        // fetched on first use from the `lama-vendor` release, like the text
        // model; the page calls `ai.ensureModel({ model: "inpaint" })` before
        // its first `ai.generateImage`. See web/erase.html.
        let lamaDir = ctx.dataDirectory().appendingPathComponent("lama", isDirectory: true)
        let lama = LaMaBackend(cacheDirectory: lamaDir)
        // Text→image (Stable Diffusion) rides the same composite when the SD
        // target is in the build — a bare prompt routes here, a prompt+image to
        // LaMa (see CompositeAIBackend). We offer **two** models the user picks
        // between at runtime (the demo of `AICapabilities.models` +
        // `request.model` + `MultiModelImageBackend`): **LCM_Dreamshaper**
        // (OpenRAIL-M, commercially usable — the default) and **SD-Turbo**
        // (non-commercial). Both are ~2–2.5 GB fp16, fetched on first use from
        // the `sd-vendor` release; the picker on web/generate.html reads the
        // model list from `ai.info`, filters by capability + licence, and passes
        // the chosen `model` id to `ai.ensureModel` / `ai.generateImage`.
        // Download sizes are derived from each source's files (no duplication).
        #if canImport(SwiftPWAStableDiffusion)
            let lcmDir = ctx.dataDirectory().appendingPathComponent("lcm-dreamshaper", isDirectory: true)
            let sdTurboDir = ctx.dataDirectory().appendingPathComponent("sd-turbo", isDirectory: true)
            let imageEntries: [MultiModelImageBackend.Entry] = [
                .init(
                    AIModelInfo(
                        id: "lcm-dreamshaper", label: "LCM Dreamshaper (commercial)",
                        capabilities: [.imageGeneration],
                        availability: .downloadable(bytes: sdSourceSize(.lcmDreamshaperFp16)),
                        offlineCapable: true, license: "OpenRAIL-M"
                    ),
                    StableDiffusionBackend(
                        cacheDirectory: lcmDir, source: .lcmDreamshaperFp16, spec: .lcmDreamshaperFp16
                    )
                ),
                .init(
                    AIModelInfo(
                        id: "sd-turbo", label: "SD-Turbo (non-commercial)",
                        capabilities: [.imageGeneration],
                        availability: .downloadable(bytes: sdSourceSize(.sdTurboFp16)),
                        offlineCapable: true, license: "Stability Non-Commercial"
                    ),
                    StableDiffusionBackend(
                        cacheDirectory: sdTurboDir, source: .sdTurboFp16, spec: .sdTurboFp16
                    )
                ),
            ]
            let imageModels = MultiModelImageBackend(imageEntries, default: "lcm-dreamshaper")

            // A **remote** arm: a local-network ComfyUI instance, proving "local
            // + remote in one dropdown." Its catalog isn't hard-coded — the
            // composite discovers the instance's installed checkpoints and lists
            // each as its own `comfy:<ckpt>` model (a ComfyUI is a *source* of
            // many models, not one). Uses the platform `NetworkClient` (the
            // Kotlin RPC on Android). See docs/remote-ai.md.
            let comfy = RemoteImageBackend(
                provider: ComfyUIProvider(baseURL: demoComfyURL),
                client: makeNetworkClient()
            )

            // A remote **cloud** arm: Google Imagen. The API key is NOT baked in
            // — it's read at runtime from the OS secure store via the `secrets.*`
            // plugin (Keychain on Apple, Keystore-backed EncryptedSharedPreferences
            // on Android). So Imagen advertises `needsSetup` until the user enters
            // a key (web/generate.html reveals a password field for it), then
            // flips to `ready`. This is the "require a key at runtime, store it
            // securely" pattern real cloud-backed apps need — see docs/secrets.md.
            let secretStore = makeSecretStore()
            ctx.use(SecretsPlugin(secretStore))
            let imagenProvider = ImagenProvider(apiKey: { try? await secretStore.get(imagenAPIKeyName) })
            let imagen = RemoteImageBackend(provider: imagenProvider, client: makeNetworkClient())
            ctx.use(AIPlugin(CompositeAIBackend(
                text: textBackend, image: lama, imageGen: imageModels, comfy: comfy,
                imagen: imagen,
                imagenKeyPresent: { (try? await secretStore.get(imagenAPIKeyName)) != nil }
            )))
            // Phase 2: expose the same backends through the runtime workflow
            // surface. Imagen conforms to `AIWorkflowProvider` directly (a
            // fixed-schema cloud provider); the on-device SD models ride the
            // generic `AIBackendWorkflowProvider` adapter (any `AIBackend` → a
            // fixed-schema provider). No graph, no rebuild — `ai.describeInputs`
            // returns their controls and `ai.run` streams progress → image.
            workflowProviders.append(imagenProvider)
            workflowProviders.append(AIBackendWorkflowProvider(providerID: "on-device", backend: imageModels))
            // Also expose the raw `net.*` plugin so the page can make native,
            // CORS-free HTTP calls (and so the remote arm's transport is
            // exercisable directly). Opt-in, so registered explicitly here.
            ctx.use(NetPlugin(makeNetworkClient()))
        #else
            ctx.use(AIPlugin(CompositeAIBackend(text: textBackend, image: lama)))
            // No SD in this build, but LaMa (pure inpaint, `imageEditing` only)
            // still demonstrates a fixed-schema on-device workflow provider.
            workflowProviders.append(AIBackendWorkflowProvider(providerID: "on-device", backend: lama))
        #endif
    #else
        if let textBackend {
            ctx.use(AIPlugin(textBackend))
        } else {
            print(
                "CritterFacts: built without an AI backend. Build with "
                    + "`swift-pwa build` (ai.local_llama / ai.local_onnx_runtime in pwa.json) "
                    + "or export SWIFT_PWA_LLAMA=1 before `swift run` to enable on-device AI."
            )
        }
    #endif

    // Runtime, JS-reachable workflow door (`ai.run` / `ai.describeInputs`), now
    // provider-agnostic (Phase 2): the picker on web/workflow.html chooses among
    // ComfyUI (import an API-format graph, introspect it, run with per-step
    // progress — endpoint + graph travel in each call, no rebuild per box),
    // Imagen (a fixed-schema cloud provider), and the on-device image models (via
    // the generic `AIBackendWorkflowProvider` adapter). Opt-in + additive
    // (separate from `AIPlugin`, shares the `ai.*` namespace like `VisionPlugin`);
    // needs only a `NetworkClient`, so it's wired unconditionally here. The
    // optional secret store lets a call carry a `secretRef` (resolved server-side
    // into `${secret}` headers) for a key-protected endpoint. See web/workflow.html
    // and docs/remote-ai.md ("Running an imported workflow from JS").
    ctx.use(AIWorkflowPlugin(
        providers: workflowProviders,
        client: makeNetworkClient(),
        secrets: makeSecretStore()
    ))

    // On-device segmentation demo (`ai.vision.*`) — MobileSAMBackend, a
    // *separate* plugin/namespace from the `ai.*` generative backend picked
    // above, so it's wired unconditionally rather than as another `#elseif`
    // branch. Uses the **downloadable-model tier**: the three MobileSAM ONNX
    // files (~60 MB, Apache-2.0) are fetched on first use from the
    // `mobilesam-vendor` release (resumable + checksum-pinned via the same
    // ModelDownloader the llama backend uses) into the app's data directory,
    // exactly like the llama GGUF above — the page calls `ai.vision.ensureModel`
    // once before its first `ai.vision.openSession` (see `web/mobilesam.js`).
    // Identical wiring on Apple and Android; on Android this also sidesteps
    // the "an APK asset isn't a file ONNX Runtime can open" problem — the
    // downloader writes straight to a real filesystem path, no materialization
    // step needed. Verified end-to-end against a real photo on a Galaxy Z
    // Fold7, and on macOS via a real network download + segment.
    #if canImport(SwiftPWASegmentation)
        let mobileSAMDir = ctx.dataDirectory().appendingPathComponent("mobilesam", isDirectory: true)
        ctx.use(VisionPlugin(MobileSAMBackend(cacheDirectory: mobileSAMDir)))
    #endif

    #if os(Android) && CRITTERFACTS_LAMA_SMOKE && canImport(SwiftPWAImageEdit)
        // Headless on-device verification of the Android image-edit path
        // (LaMaBackend + the BitmapFactory-over-RPC ImageCodec). Gated behind a
        // compile flag (SWIFT_PWA_CF_LAMA_SMOKE at build time) so it's absent
        // from normal builds. Runs one inpaint against a tiny embedded test
        // image + mask and logs the outcome to logcat (the WebView's console
        // isn't forwarded there, but swiftPWALog is) — the Android analogue of
        // the desktop runSmoke. Spawned detached with a short delay so the JNI
        // RPC bridge (MainActivity.rpcCall) is up before the codec RPC fires.
        let lamaSmokeDir = ctx.dataDirectory().appendingPathComponent("lama", isDirectory: true)
        let lamaSmokeOut = ctx.dataDirectory().appendingPathComponent("erased", isDirectory: true).path
        // Prefer real files pushed into the app's data dir (image.jpg/mask.png
        // under a `cf_smoke/` folder) so the smoke can exercise a full-size
        // photo — the 24-megapixel case that the tiny embedded fallback can't.
        let smokeFiles = ctx.dataDirectory().appendingPathComponent("cf_smoke", isDirectory: true)
        let smokeImagePath = smokeFiles.appendingPathComponent("image.jpg").path
        let smokeMaskPath = smokeFiles.appendingPathComponent("mask.png").path
        Task.detached {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let backend = LaMaBackend(cacheDirectory: lamaSmokeDir)
                swiftPWALog("CF_LAMA_SMOKE: ensuring big-lama…")
                for try await _ in backend.ensureModel(AIEnsureModelRequest(model: "inpaint")) {}
                let haveFiles = FileManager.default.fileExists(atPath: smokeImagePath)
                    && FileManager.default.fileExists(atPath: smokeMaskPath)
                let image: AIImage = haveFiles ? .file(smokeImagePath) : .inline(cfSmokeImageBase64)
                let mask: AIImage = haveFiles ? .file(smokeMaskPath) : .inline(cfSmokeMaskBase64)
                swiftPWALog("CF_LAMA_SMOKE: model ready; running inpaint (files=\(haveFiles))…")
                let result = try await backend.generateImage(AIGenerateImageRequest(
                    outputDirectory: lamaSmokeOut, image: image, mask: mask
                ))
                swiftPWALog("CF_LAMA_SMOKE_OK backend=\(result.backend) path=\(result.images.first?.path ?? "nil")")
            } catch {
                swiftPWALog("CF_LAMA_SMOKE_ERR \(error)")
            }
        }
    #endif

    // Android serves bundled web assets through the WebViewAssetLoader virtual
    // host (the adapter ignores the directory path); desktop resolves the
    // real `web/` from the resource bundle.
    #if os(Android)
        let content = WindowContent.bundled(directory: URL(fileURLWithPath: "/android_asset/web"))
    #else
        let content = WindowContent.bundled(directory: locateWebRoot())
    #endif
    _ = try ctx.createWindow(WindowConfig(
        title: "Critter Facts",
        size: Size(width: 720, height: 720),
        content: content
    ))
}

/// The platform's text `AIBackend` (`ai.generate` / streaming / JSON), or `nil`
/// when none is in this build. Split out so both the composed (image-edit on)
/// and plain wiring in `configure` share it.
@MainActor
func makeTextBackend(_ ctx: any AppContext) -> (any AIBackend)? {
    #if os(Android)
        // Android's platform built-in: Gemini Nano via ML Kit GenAI (AICore).
        // No app-shipped weights: `ai.ensureModel` triggers AICore's on-demand
        // download. Enabled by `ai.gemini_nano: true` in pwa.json.
        return GeminiNanoBackend()
    #elseif os(Windows) && canImport(SwiftPWAPhiSilica)
        // Windows' platform built-in: Phi Silica via the Windows AI APIs. The
        // Limited Access Feature unlock token (a secret) comes from the
        // environment. Requires an MSIX-packaged build to use.
        return PhiSilicaBackend(unlockToken: ProcessInfo.processInfo.environment["PHI_SILICA_LAF_TOKEN"])
    #elseif canImport(SwiftPWALlama)
        // A tiny (~400 MB), Apache-2.0 instruct model. Downloadable: the page
        // calls `ai.ensureModel` before its first `ai.generate`, and
        // ModelDownloader fetches it once (resumable + checksum-pinned). Metal
        // on Apple; Vulkan (GPU if present, else CPU) on Linux/Windows.
        let modelsDir = ctx.dataDirectory().appendingPathComponent("models", isDirectory: true)
        return LlamaBackend(model: factModelSpec, cacheDirectory: modelsDir)
    #else
        _ = ctx
        return nil
    #endif
}

/// Locates the bundled `web/` folder: the `.app` resource bundle when built by
/// `swift-pwa build`, else the SwiftPM resource bundle under plain `swift run`.
func locateWebRoot() -> URL {
    // Single-file build (Windows `--single-file`): web/ is embedded in the exe
    // and served from memory, so the backend ignores this path — return a
    // placeholder without touching the (absent) resource bundle.
    if EmbeddedWebAssets.isPresent { return URL(fileURLWithPath: ".") }
    let fm = FileManager.default
    if let main = Bundle.main.resourceURL?.appendingPathComponent("web"),
       fm.fileExists(atPath: main.path) {
        return main
    }
    return Bundle.module.bundleURL.appendingPathComponent("web")
}
