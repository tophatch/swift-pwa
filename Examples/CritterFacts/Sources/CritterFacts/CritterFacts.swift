import Foundation
import SwiftPWA
import SwiftPWAModelStore // ModelSpec

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
    #if os(Android)
        // Android's platform built-in: Gemini Nano via ML Kit GenAI (AICore).
        // Same `ai.*` contract as the llama path below — the page is identical.
        // No app-shipped weights: `ai.ensureModel` triggers AICore's on-demand
        // download. Enabled by `ai.gemini_nano: true` in pwa.json.
        ctx.use(AIPlugin(GeminiNanoBackend()))
    #elseif os(Windows) && canImport(SwiftPWAPhiSilica)
        // Windows' platform built-in: Phi Silica via the Windows AI APIs
        // (Windows App SDK). Preferred over llama on Windows when
        // `ai.phi_silica: true` — system-managed model, no app-shipped weights.
        // The Limited Access Feature unlock token (per package family name,
        // from Microsoft) is a secret, so it comes from the environment rather
        // than checked-in config. Requires an MSIX-packaged build to use.
        ctx.use(AIPlugin(PhiSilicaBackend(
            unlockToken: ProcessInfo.processInfo.environment["PHI_SILICA_LAF_TOKEN"]
        )))
    #elseif canImport(SwiftPWALlama)
        // A tiny (~400 MB), Apache-2.0 instruct model. It's *downloadable*: the
        // page calls `ai.ensureModel` before its first `ai.generate`, and
        // ModelDownloader fetches it once (resumable + checksum-pinned) into the
        // app's data directory, then reuses it. Swap the spec for any GGUF — a
        // bigger model just means a longer first-run download. On Apple it runs
        // Metal-accelerated; on Linux and Windows, Vulkan (GPU if present, else
        // CPU).
        let modelsDir = ctx.dataDirectory().appendingPathComponent("models", isDirectory: true)
        ctx.use(AIPlugin(LlamaBackend(model: factModelSpec, cacheDirectory: modelsDir)))
    #else
        print(
            "CritterFacts: built without the llama backend. Build with "
                + "`swift-pwa build` (ai.local_llama is set in pwa.json) or export "
                + "SWIFT_PWA_LLAMA=1 before `swift run` to enable on-device facts."
        )
    #endif

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
