import ArgumentParser
@testable import SwiftPWACLISupport
import Testing

@Suite("swift-pwa self-update")
struct SelfUpdateTests {
    @Test("an explicit --version is normalised to a leading v")
    func normalisesExplicitVersion() async throws {
        let withV = try await SelfUpdate.resolveTag(requested: "v1.2.3")
        let withoutV = try await SelfUpdate.resolveTag(requested: "1.2.3")
        #expect(withV == "v1.2.3")
        #expect(withoutV == "v1.2.3")
    }

    @Test("picks a published asset for the test host")
    func hostAssetForTestHost() {
        // The suite only runs on macOS / Linux x86_64 in CI; both publish
        // an asset, so this must be non-nil wherever the test executes.
        let asset = SelfUpdate.hostAsset()
        #expect(asset != nil)
        #if os(macOS)
            #expect(asset?.hasPrefix("swift-pwa-macos-") == true)
        #elseif os(Linux)
            #expect(asset == "swift-pwa-linux-x86_64")
        #endif
    }

    @Test("resolves this binary's own path on POSIX hosts")
    func resolvesExecutablePath() {
        #if !os(Windows)
            let path = SelfUpdate.executablePath()
            #expect(path != nil)
            #expect(path?.hasPrefix("/") == true)
        #endif
    }

    @Test("Windows guidance names the asset and repo")
    func windowsGuidanceIsActionable() {
        let text = SelfUpdate.windowsGuidance(current: "0.6.1")
        #expect(text.contains("swift-pwa-windows-x86_64.exe"))
        #expect(text.contains("tophatch/swift-pwa"))
    }
}
