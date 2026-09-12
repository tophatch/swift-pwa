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
            OnnxRuntimeWindowsArtifact.libURL,
            OnnxRuntimeWindowsArtifact.dllURL,
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
