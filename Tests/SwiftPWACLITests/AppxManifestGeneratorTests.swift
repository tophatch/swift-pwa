import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("AppxManifest renderer")
struct AppxManifestGeneratorTests {
    private func base() -> PWAManifest {
        PWAManifest(
            id: "com.example.hello",
            name: "Hello",
            version: "1.2.3",
            description: "A friendly greeting.",
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: "Hello"),
            macos: nil,
            ios: nil,
            linux: nil
        )
    }

    @Test("Minimal manifest renders the required AppX namespaces and identity")
    func minimal() {
        let xml = AppxManifestGenerator.render(manifest: base())
        // Schema namespaces required by makeappx for v10 manifests.
        #expect(xml.contains("appx/manifest/foundation/windows10"))
        #expect(xml.contains("appx/manifest/uap/windows10"))
        // Identity name + publisher derived from `id`.
        #expect(xml.contains("Name=\"com.example.hello\""))
        #expect(xml.contains("Publisher=\"CN=com.example.hello\""))
        // Application points at the EXE built by `swift build`.
        #expect(xml.contains("Executable=\"Hello.exe\""))
        #expect(xml.contains("EntryPoint=\"Windows.FullTrustApplication\""))
        #expect(xml.contains("<rescap:Capability Name=\"runFullTrust\""))
    }

    @Test("Three-component versions get padded to four for MSIX schema compliance")
    func versionPadding() {
        let xml = AppxManifestGenerator.render(manifest: base())
        // 1.2.3 → 1.2.3.0
        #expect(xml.contains("Version=\"1.2.3.0\""))
    }

    @Test("Four-component versions pass through verbatim")
    func versionPassthrough() {
        var m = base()
        m.version = "2.0.0.42"
        let xml = AppxManifestGenerator.render(manifest: m)
        #expect(xml.contains("Version=\"2.0.0.42\""))
    }

    @Test("Display name is XML-escaped")
    func escaping() {
        var m = base()
        m.name = "Tom & Jerry"
        m.description = "<script>alert(1)</script>"
        let xml = AppxManifestGenerator.render(manifest: m)
        #expect(xml.contains("Tom &amp; Jerry"))
        #expect(xml.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        // Raw form must not leak through.
        #expect(!xml.contains("<script>alert(1)</script>"))
    }
}
