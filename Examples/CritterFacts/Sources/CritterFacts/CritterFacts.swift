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
        #if canImport(SwiftPWALlama)
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
    #if canImport(SwiftPWALlama)
        // A tiny (~400 MB), Apache-2.0 instruct model. It's *downloadable*: the
        // page calls `ai.ensureModel` before its first `ai.generate`, and
        // ModelDownloader fetches it once (resumable + checksum-pinned) into the
        // app's data directory, then reuses it. Swap the spec for any GGUF — a
        // bigger model just means a longer first-run download. On Apple it runs
        // Metal-accelerated; on Linux, Vulkan (GPU if present, else CPU).
        let modelsDir = ctx.dataDirectory().appendingPathComponent("models", isDirectory: true)
        ctx.use(AIPlugin(LlamaBackend(model: factModelSpec, cacheDirectory: modelsDir)))
    #else
        print(
            "CritterFacts: built without the llama backend. Build with "
                + "`swift-pwa build` (ai.local_llama is set in pwa.json) or export "
                + "SWIFT_PWA_LLAMA=1 before `swift run` to enable on-device facts."
        )
    #endif

    let content = WindowContent.bundled(directory: locateWebRoot())
    _ = try ctx.createWindow(WindowConfig(
        title: "Critter Facts",
        size: Size(width: 720, height: 720),
        content: content
    ))
}

/// Locates the bundled `web/` folder: the `.app` resource bundle when built by
/// `swift-pwa build`, else the SwiftPM resource bundle under plain `swift run`.
func locateWebRoot() -> URL {
    let fm = FileManager.default
    if let main = Bundle.main.resourceURL?.appendingPathComponent("web"),
       fm.fileExists(atPath: main.path) {
        return main
    }
    return Bundle.module.bundleURL.appendingPathComponent("web")
}
