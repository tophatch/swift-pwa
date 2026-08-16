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
        // No AI capability unless ai.phi_silica is set.
        #expect(!xml.contains("systemAIModels"))
    }

    @Test("ai.phi_silica adds the systemAIModels restricted capability")
    func phiSilicaCapability() {
        var m = base()
        m.ai = .init(phiSilica: true)
        let xml = AppxManifestGenerator.render(manifest: m)
        // The Windows AI APIs need this restricted capability + package
        // identity; declaring it is what lets a packaged build reach Phi Silica.
        #expect(xml.contains("<rescap:Capability Name=\"systemAIModels\" />"))
        // Still rescap-namespaced and alongside runFullTrust.
        #expect(xml.contains("<rescap:Capability Name=\"runFullTrust\""))
        // The WinAppSDK runtime framework dependency — required for the AI WinRT
        // classes to activate (else CreateAsync fails "Class not registered").
        #expect(xml.contains("<PackageDependency Name=\"Microsoft.WindowsAppRuntime.2\""))
        #expect(xml.contains("Publisher=\"CN=Microsoft Corporation"))
        // Min-OS bumped to the AI-APIs floor (Windows 11 24H2 / build 26100),
        // with MaxVersionTested >= MinVersion.
        #expect(xml.contains("MinVersion=\"10.0.26100.0\""))
        #expect(xml.contains("MaxVersionTested=\"10.0.26100.0\""))
    }

    @Test("permissions.device.bluetooth adds the bluetooth device capability")
    func bluetoothCapability() {
        var m = base()
        m.permissions = .init(device: .init(names: ["bluetooth"]))
        let xml = AppxManifestGenerator.render(manifest: m)
        // A portable .exe reaches the radio with no declaration at all; a
        // packaged app is capability-gated, and without this the WinRT calls
        // fail instead of prompting.
        #expect(xml.contains("<DeviceCapability Name=\"bluetooth\" />"))
        // Not rescap-namespaced — `bluetooth` is a general device capability,
        // and `<rescap:DeviceCapability>` wouldn't validate.
        #expect(!xml.contains("rescap:DeviceCapability"))

        #expect(!AppxManifestGenerator.render(manifest: base()).contains("DeviceCapability"))
    }

    @Test("Without ai.phi_silica: no framework dependency, default min-OS")
    func noPhiSilicaDefaults() {
        let xml = AppxManifestGenerator.render(manifest: base())
        #expect(!xml.contains("PackageDependency"))
        #expect(!xml.contains("systemAIModels"))
        #expect(xml.contains("MinVersion=\"10.0.17763.0\""))
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

    // MARK: - Architecture

    @Test("Default architecture is x64")
    func defaultArchIsX64() {
        let xml = AppxManifestGenerator.render(manifest: base())
        #expect(xml.contains("ProcessorArchitecture=\"x64\""))
    }

    @Test("arm64 architecture emits ProcessorArchitecture=\"arm64\"")
    func archArm64() {
        let xml = AppxManifestGenerator.render(manifest: base(), arch: .arm64)
        #expect(xml.contains("ProcessorArchitecture=\"arm64\""))
        #expect(!xml.contains("ProcessorArchitecture=\"x64\""))
    }

    @Test("x86 architecture emits ProcessorArchitecture=\"x86\"")
    func archX86() {
        let xml = AppxManifestGenerator.render(manifest: base(), arch: .x86)
        #expect(xml.contains("ProcessorArchitecture=\"x86\""))
    }

    @Test("Architecture.parse accepts canonical and Swift-style spellings")
    func archParseAliases() throws {
        #expect(try AppxManifestGenerator.Architecture.parse("x64") == .x64)
        #expect(try AppxManifestGenerator.Architecture.parse("X64") == .x64)
        #expect(try AppxManifestGenerator.Architecture.parse("x86_64") == .x64)
        #expect(try AppxManifestGenerator.Architecture.parse("arm64") == .arm64)
        #expect(try AppxManifestGenerator.Architecture.parse("aarch64") == .arm64)
        #expect(try AppxManifestGenerator.Architecture.parse("x86") == .x86)
    }

    @Test("Architecture.parse rejects unknown values with a friendly message")
    func archParseRejectsUnknown() {
        do {
            _ = try AppxManifestGenerator.Architecture.parse("riscv64")
            Issue.record("expected throw")
        } catch {
            #expect("\(error)".contains("x64") || "\(error)".contains("arm64"))
        }
    }
}
