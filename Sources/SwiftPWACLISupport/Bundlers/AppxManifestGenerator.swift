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

        // The Windows AI APIs (Phi Silica, `ai.phi_silica`) are gated behind
        // the `systemAIModels` restricted capability AND package identity — an
        // unpackaged exe gets `AIFeatureReadyState.CapabilityMissing` /
        // E_ACCESSDENIED. Declaring it here is what lets a packaged (MSIX)
        // CritterFacts/adopter actually reach the model. Leading newline so it
        // nests under the fixed `runFullTrust` line.
        let phiSilicaCapability = manifest.ai?.phiSilica == true
            ? "\n            <rescap:Capability Name=\"systemAIModels\" />"
            : ""

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
                                MinVersion="10.0.17763.0"
                                MaxVersionTested="10.0.22621.0" />
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
                  Square44x44Logo="Square150x150Logo.png" />
            </Application>
          </Applications>

          <Capabilities>
            <rescap:Capability Name="runFullTrust" />\(phiSilicaCapability)
          </Capabilities>

        </Package>
        """
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
