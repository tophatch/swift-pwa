import ArgumentParser
import Foundation

/// Renders an `AppxManifest.xml` from a `PWAManifest`. The schema is
/// the MSIX/AppX manifest spec — a stripped-down version of what
/// Visual Studio's UAP project template generates.
///
/// We target the v10.0 (Windows 10/11) namespaces because earlier
/// versions either drop fields we care about (Description) or carry
/// schema mismatches against current `makeappx.exe`. The output is
/// the minimum that passes the manifest schema validator and produces
/// a sideloadable package; richer features (capabilities, file
/// associations, protocol handlers) ride on follow-up work that grows
/// the manifest with the corresponding fields.
enum AppxManifestGenerator {
    /// MSIX `<Identity ProcessorArchitecture="…">` values understood by
    /// `makeappx.exe`. We expose the same set the Windows SDK accepts
    /// (minus `neutral`, which is for resource-only packages and not
    /// what `swift-pwa build` emits).
    enum Architecture: String {
        case x64
        case x86
        case arm64

        /// Map a `swift-pwa build --arch <value>` argument to an
        /// `Architecture`. Throws on an unknown value so the CLI can
        /// surface a friendly error before reaching the bundler.
        static func parse(_ raw: String) throws -> Architecture {
            switch raw.lowercased() {
            case "x64", "x86_64": return .x64
            case "x86": return .x86
            case "arm64", "aarch64": return .arm64
            default:
                throw ValidationError(
                    "swift-pwa: --arch must be one of x64, x86, arm64 (got '\(raw)')"
                )
            }
        }
    }

    static func render(manifest: PWAManifest, arch: Architecture = .x64) -> String {
        // Identity.Name must be A-Z, a-z, 0-9, dot, hyphen — no
        // underscores, no spaces. We start from `manifest.id` (which
        // looks like reverse-DNS already) and strip anything outside
        // the allowed alphabet as a defense in depth.
        let identityName = manifest.id.filter { c in
            c.isLetter || c.isNumber || c == "." || c == "-"
        }
        let publisher = "CN=" + identityName

        // The Windows AI APIs (Phi Silica, `ai.phi_silica`) need three things in
        // the manifest, all verified on a Copilot+ NPU: (1) the `systemAIModels`
        // restricted capability, (2) a dependency on the Windows App SDK runtime
        // framework package (so the AI WinRT classes are registered for
        // activation — without it `CreateAsync`/`GetReadyState` fail with
        // `Class not registered`), and (3) a min-OS of 10.0.26100.0 (the floor
        // for the AI APIs). Plus package identity itself (unpackaged → the OS
        // reports `CapabilityMissing` / `E_ACCESSDENIED`) and, at runtime, a LAF
        // unlock token (`PhiSilicaBackend(unlockToken:)`). The framework name +
        // version pin the Windows App SDK 2.x runtime; bump alongside the SDK
        // the `CPhiSilica` shim builds against.
        let phiSilica = manifest.ai?.phiSilica == true
        let phiSilicaCapability = phiSilica
            ? "\n            <rescap:Capability Name=\"systemAIModels\" />"
            : ""
        let phiSilicaFrameworkDependency = phiSilica
            ? "\n            <PackageDependency Name=\"Microsoft.WindowsAppRuntime.2\""
            + " MinVersion=\"2.0.1.0\""
            + " Publisher=\"CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US\" />"
            : ""
        // The Windows AI APIs require Windows 11 24H2 (build 26100)+.
        // MaxVersionTested must be >= MinVersion, so bump it in lockstep.
        let targetMinVersion = phiSilica ? "10.0.26100.0" : "10.0.17763.0"
        let targetMaxVersion = phiSilica ? "10.0.26100.0" : "10.0.22621.0"

        // MSIX versions are Major.Minor.Build.Revision. The PWA
        // manifest's `version` is SemVer-shaped (Major.Minor.Patch).
        // Pad with `.0` if the user supplied three components; pass
        // through verbatim if they already used four.
        let version: String = {
            let parts = manifest.version.split(separator: ".")
            return parts.count == 4 ? manifest.version : manifest.version + ".0"
        }()

        let displayName = xmlEscape(manifest.name)
        let description = xmlEscape(manifest.description ?? manifest.name)
        let executable = manifest.name + ".exe"

        // `permissions.device.bluetooth` → the `bluetooth` device capability.
        // A portable .exe needs nothing (an unpackaged Win32 app reaches the
        // radio directly), but a packaged app is capability-gated: without this
        // the WinRT calls fail rather than prompting, so the MSIX is the one
        // Windows artifact the declaration has to reach.
        let bluetoothCapability = (manifest.permissions?.device?.names ?? []).contains("bluetooth")
            ? "\n            <DeviceCapability Name=\"bluetooth\" />"
            : ""

        // File-type associations (windows.document_types) → a
        // `windows.fileTypeAssociation` extension per declared group, so the OS
        // associates the app with those extensions on install. Empty when none
        // are declared, keeping the manifest byte-for-byte as before.
        let fileTypeExtensions = fileTypeAssociationsXML(manifest.windows?.documentTypes ?? [])

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <Package
            xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
            xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
            xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
            IgnorableNamespaces="uap rescap">

          <Identity
              Name="\(identityName)"
              Publisher="\(publisher)"
              Version="\(version)"
              ProcessorArchitecture="\(arch.rawValue)" />

          <Properties>
            <DisplayName>\(displayName)</DisplayName>
            <PublisherDisplayName>\(displayName)</PublisherDisplayName>
            <Description>\(description)</Description>
            <Logo>Square150x150Logo.png</Logo>
          </Properties>

          <Dependencies>
            <TargetDeviceFamily Name="Windows.Desktop"
                                MinVersion="\(targetMinVersion)"
                                MaxVersionTested="\(targetMaxVersion)" />\(phiSilicaFrameworkDependency)
          </Dependencies>

          <Resources>
            <Resource Language="en-us" />
          </Resources>

          <Applications>
            <Application Id="App" Executable="\(executable)" EntryPoint="Windows.FullTrustApplication">
              <uap:VisualElements
                  DisplayName="\(displayName)"
                  Description="\(description)"
                  BackgroundColor="transparent"
                  Square150x150Logo="Square150x150Logo.png"
                  Square44x44Logo="Square150x150Logo.png" />\(fileTypeExtensions)
            </Application>
          </Applications>

          <Capabilities>
            <rescap:Capability Name="runFullTrust" />\(phiSilicaCapability)\(bluetoothCapability)
          </Capabilities>

        </Package>
        """
    }

    /// Render the `<Extensions>` block of `windows.fileTypeAssociation`
    /// entries, or "" when none are declared. One `<uap:FileTypeAssociation>`
    /// per document-type group; its `Name` (the association identifier) must be
    /// lowercase and `[a-z0-9.-_]`, so it's sanitized / auto-numbered.
    static func fileTypeAssociationsXML(_ docTypes: [PWAManifest.ExtensionDocumentType]) -> String {
        // Normalize + drop entries with no usable extension.
        let groups: [(name: String, exts: [String])] = docTypes.enumerated().compactMap { index, dt in
            let exts = FileAssociationSupport.normalizedExtensions(dt.extensions)
            guard !exts.isEmpty else { return nil }
            let name = FileAssociationSupport.associationName(dt.name, fallbackIndex: index)
            return (name, exts)
        }
        guard !groups.isEmpty else { return "" }

        let associations = groups.map { group in
            let fileTypes = group.exts
                .map { "              <uap:FileType>\($0)</uap:FileType>" }
                .joined(separator: "\n")
            return """
                  <uap:Extension Category="windows.fileTypeAssociation">
                    <uap:FileTypeAssociation Name="\(group.name)">
                      <uap:SupportedFileTypes>
            \(fileTypes)
                      </uap:SupportedFileTypes>
                    </uap:FileTypeAssociation>
                  </uap:Extension>
            """
        }.joined(separator: "\n")

        return "\n          <Extensions>\n\(associations)\n          </Extensions>"
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
