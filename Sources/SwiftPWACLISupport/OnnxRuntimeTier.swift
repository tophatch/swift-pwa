import Foundation

/// Whether this build ships the on-device ONNX Runtime tier — and why.
///
/// The tier is a **vendored native library** (`libonnxruntime.so` /
/// `onnxruntime.lib` / the Apple xcframework). Two things have to agree about
/// it: swift-pwa's own `Package.swift`, which only declares the ONNX targets
/// when `SWIFT_PWA_ONNXRUNTIME` is set in the environment, and the bundler,
/// which puts the library where the linker and the packaged app can find it.
///
/// They used to disagree. `ai.local_onnx_runtime` in `pwa.json` drove the
/// bundler alone, so an app whose `Package.swift` asked for `SwiftPWAQwenTTS`
/// — with the env var exported by hand, which is how the product resolves at
/// all — linked the tier and was never handed the library:
///
/// ```
/// ld.lld: error: unable to find library -lonnxruntime
/// lld-link: error: could not open 'onnxruntime.lib': no such file or directory
/// ```
///
/// Neither error names the one-line fix, and both read like a broken package
/// rather than a missing manifest key (#215; measured on Android and Windows).
///
/// So the package graph is the authority now: an app that depends on a product
/// from this tier *gets* the tier, and `ai.local_onnx_runtime` remains the
/// explicit opt-in for the case the graph can't show — an app reaching the
/// runtime through some other edge. The flag is no longer something an adopter
/// can forget.
enum OnnxRuntimeTier {
    /// Products whose presence in an app's `Package.swift` means the ONNX
    /// Runtime is linked into the app's binary. Every one of them is declared
    /// inside swift-pwa's `SWIFT_PWA_ONNXRUNTIME` block and reaches the
    /// vendored library directly (no JNI glue, no `dlopen`) — so naming any of
    /// them makes the library a hard requirement at link *and* at launch.
    static let products = [
        "SwiftPWAONNX",
        "SwiftPWASegmentation",
        "SwiftPWAImageEdit",
        "SwiftPWAStableDiffusion",
        "SwiftPWAQwenTTS"
    ]

    /// Why the tier is on for this build, or nil if it is off.
    enum Reason: Equatable {
        /// `pwa.json` declared it (`ai.local_onnx_runtime`, or `ai.onnx_gpu`
        /// which implies it).
        case manifest
        /// The app's `Package.swift` depends on the named tier product, so the
        /// linker needs the library whatever `pwa.json` says.
        case packageDependency(String)
    }

    static func reason(manifest: PWAManifest, projectRoot: URL) -> Reason? {
        if manifest.ai?.localOnnxRuntime == true || manifest.ai?.onnxGpu == true { return .manifest }
        let packageSwift = projectRoot.appendingPathComponent("Package.swift")
        guard let source = try? String(contentsOf: packageSwift, encoding: .utf8) else { return nil }
        return dependedProduct(inPackageSource: source).map { .packageDependency($0) }
    }

    static func isEnabled(manifest: PWAManifest, projectRoot: URL) -> Bool {
        reason(manifest: manifest, projectRoot: projectRoot) != nil
    }

    /// The first tier product named as a **quoted string** anywhere in a
    /// `Package.swift`, or nil.
    ///
    /// A text scan rather than `swift package describe`, because the graph this
    /// question is about can't be resolved until the answer is known:
    /// `SWIFT_PWA_ONNXRUNTIME` has to be set *before* the manifest evaluates or
    /// the products don't exist, and `describe` would fail with
    /// `product 'SwiftPWAQwenTTS' not found` — one of the two errors this
    /// prevents. A false positive costs a vendored download and a bigger
    /// artifact; a false negative costs a link failure, so the scan errs
    /// towards matching.
    static func dependedProduct(inPackageSource source: String) -> String? {
        products.first { source.contains("\"\($0)\"") }
    }
}
