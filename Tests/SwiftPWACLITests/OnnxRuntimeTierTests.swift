import Foundation
@testable import SwiftPWACLISupport
import Testing

/// #215: an app whose `Package.swift` depends on an ONNX-tier product links
/// the vendored ONNX Runtime, but the bundler only staged the library when
/// `pwa.json` said `ai.local_onnx_runtime`. The two disagreeing produced
/// `unable to find library -lonnxruntime` (Android) and
/// `could not open 'onnxruntime.lib'` (Windows) — errors that name no fix.
///
/// The package graph is the authority now. These cover the derivation, because
/// the failure it prevents only reproduces with a real NDK/linker and so can't
/// be a test.
@Suite("ONNX Runtime tier derivation")
struct OnnxRuntimeTierTests {
    private func manifest(localOnnx: Bool? = nil, onnxGpu: Bool? = nil) -> PWAManifest {
        var m = PWAManifest(
            id: "com.example.app",
            name: "App",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: "App")
        )
        if localOnnx != nil || onnxGpu != nil {
            m.ai = .init(localOnnxRuntime: localOnnx, onnxGpu: onnxGpu)
        }
        return m
    }

    private func withProject(packageSwift: String?, _ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onnx-tier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if let packageSwift {
            try packageSwift.write(
                to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
            )
        }
        try body(dir)
    }

    @Test("a package depending on a tier product enables the tier with no manifest key")
    func packageDependencyEnablesTier() throws {
        // The shape an adopter writes: the TTS product, and an `ai` section
        // that says nothing about the runtime.
        let pkg = """
        // swift-tools-version:6.0
        import PackageDescription
        let package = Package(
            name: "Reader",
            dependencies: [.package(url: "https://github.com/x/swift-pwa", from: "0.10.7")],
            targets: [.executableTarget(name: "Reader", dependencies: [
                .product(name: "SwiftPWA", package: "swift-pwa"),
                .product(name: "SwiftPWAQwenTTS", package: "swift-pwa")
            ])]
        )
        """
        let plain = manifest()
        try withProject(packageSwift: pkg) { root in
            #expect(
                OnnxRuntimeTier.reason(manifest: plain, projectRoot: root)
                    == .packageDependency("SwiftPWAQwenTTS")
            )
            #expect(OnnxRuntimeTier.isEnabled(manifest: plain, projectRoot: root))
        }
    }

    @Test("every tier product is recognised")
    func everyTierProductIsRecognised() {
        for product in OnnxRuntimeTier.products {
            let source = ".product(name: \"\(product)\", package: \"swift-pwa\")"
            #expect(OnnxRuntimeTier.dependedProduct(inPackageSource: source) == product)
        }
    }

    @Test("an app that names no tier product leaves the tier off")
    func plainAppLeavesTierOff() throws {
        let pkg = """
        // swift-tools-version:6.0
        import PackageDescription
        let package = Package(
            name: "Plain",
            targets: [.executableTarget(name: "Plain", dependencies: [
                .product(name: "SwiftPWA", package: "swift-pwa")
            ])]
        )
        """
        let plain = manifest()
        try withProject(packageSwift: pkg) { root in
            #expect(OnnxRuntimeTier.reason(manifest: plain, projectRoot: root) == nil)
        }
    }

    @Test("the manifest key still enables the tier on its own")
    func manifestKeyStillWins() throws {
        let declared = manifest(localOnnx: true)
        // `ai.onnx_gpu` implies the tier — an app can set the GPU flag alone.
        let gpuOnly = manifest(onnxGpu: true)
        let declinedExplicitly = manifest(localOnnx: false)
        try withProject(packageSwift: nil) { root in
            #expect(OnnxRuntimeTier.reason(manifest: declared, projectRoot: root) == .manifest)
            #expect(OnnxRuntimeTier.reason(manifest: gpuOnly, projectRoot: root) == .manifest)
            #expect(OnnxRuntimeTier.reason(manifest: declinedExplicitly, projectRoot: root) == nil)
        }
    }

    @Test("a missing Package.swift is not an error, just no derivation")
    func missingPackageSwiftIsNotAnError() throws {
        let plain = manifest()
        try withProject(packageSwift: nil) { root in
            #expect(OnnxRuntimeTier.reason(manifest: plain, projectRoot: root) == nil)
        }
    }

    /// The names are matched as quoted literals against a real manifest, so a
    /// renamed product would silently stop being recognised. swift-pwa's own
    /// `Package.swift` declares every one of them; keep the list honest
    /// against it.
    @Test("the product list matches what swift-pwa actually declares")
    func productListMatchesPackageManifest() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        for product in OnnxRuntimeTier.products {
            #expect(
                source.contains(".library(name: \"\(product)\", targets: [\"\(product)\"])"),
                "swift-pwa no longer declares a product named \(product)"
            )
        }
    }
}
