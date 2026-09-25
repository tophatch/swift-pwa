@testable import SwiftPWACLISupport
import Testing

/// Guards the invariant that makes an ONNX Runtime bump *additive*: every
/// published asset name carries the runtime version, so a new version lands
/// beside its predecessor instead of replacing bytes that already-released
/// swift-pwa versions pin by checksum. Get this wrong — bump the checksum but
/// not the URL — and the failure is remote and total: `swift build` breaks for
/// every earlier tag at once, and nobody finds out from CI here.
///
/// The Windows **DirectML** artifact is deliberately absent: it pins its own
/// lagging runtime (1.24.4) with a separate header set, and its assets keep
/// plain names until that pin first moves.
@Suite("ONNX Runtime artifact pins")
struct OnnxRuntimeArtifactPinTests {
    @Test("every published asset name carries the runtime version")
    func assetNamesAreVersioned() {
        let urls = [
            OnnxRuntimeLinuxArtifact.url,
            OnnxRuntimeWindowsArtifact.x64.libURL,
            OnnxRuntimeWindowsArtifact.x64.dllURL,
            OnnxRuntimeWindowsArtifact.arm64.libURL,
            OnnxRuntimeWindowsArtifact.arm64.dllURL,
            OnnxRuntimeAndroidArtifact.urlTemplate,
            OnnxRuntimeLinuxGpuArtifact.runtimeURL,
            OnnxRuntimeLinuxGpuArtifact.providersSharedURL,
            OnnxRuntimeLinuxGpuArtifact.providersCudaURL
        ]
        for url in urls {
            let asset = String(url.split(separator: "/").last ?? "")
            #expect(
                asset.contains(OnnxRuntimeLinuxArtifact.version),
                "\(asset) doesn't name a version — a bump would overwrite the asset older releases pin"
            )
        }
    }

    /// #262: an arm64 host downloaded the x64 pair into the same cache and the
    /// link failed. The two must be distinct files, cached apart.
    @Test("the Windows architectures never share an asset, a checksum or a cache key")
    func windowsArchitecturesAreDistinct() {
        let x64 = OnnxRuntimeWindowsArtifact.x64, arm64 = OnnxRuntimeWindowsArtifact.arm64
        #expect(Set([x64.libAsset, x64.dllAsset, arm64.libAsset, arm64.dllAsset]).count == 4)
        #expect(Set([x64.libSha256, x64.dllSha256, arm64.libSha256, arm64.dllSha256]).count == 4)
        #expect(x64.vendorDir != arm64.vendorDir)
    }

    /// The CPU and CUDA desktop builds share one committed header set, and
    /// Android/Apple track the same upstream release, so these move together or
    /// the `ORT_API_VERSION` in those headers stops matching a runtime.
    @Test("the in-lockstep artifacts agree on the version")
    func versionsAgree() {
        #expect(OnnxRuntimeWindowsArtifact.version == OnnxRuntimeLinuxArtifact.version)
        #expect(OnnxRuntimeLinuxGpuArtifact.version == OnnxRuntimeLinuxArtifact.version)
        #expect(OnnxRuntimeAndroidArtifact.version == OnnxRuntimeLinuxArtifact.version)
    }
}
