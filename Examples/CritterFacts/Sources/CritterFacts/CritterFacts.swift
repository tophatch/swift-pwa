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

@main
struct CritterFactsApp {
    static func main() async throws {
        let runtime = try SwiftPWA.runtime()
        try runtime.run(configure)
    }
}

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
        let spec = ModelSpec(
            url: URL(
                string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/"
                    + "resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
            )!,
            sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
            fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf"
        )
        ctx.use(AIPlugin(LlamaBackend(model: spec, cacheDirectory: modelsDir)))
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
