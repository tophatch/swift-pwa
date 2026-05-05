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
/// associations, protocol handlers) ride on a v0.4 follow-up where
/// the manifest grows the corresponding fields.
enum AppxManifestGenerator {
    static func render(manifest: PWAManifest) -> String {
        // Identity.Name must be A-Z, a-z, 0-9, dot, hyphen — no
        // underscores, no spaces. We start from `manifest.id` (which
        // looks like reverse-DNS already) and strip anything outside
        // the allowed alphabet as a defense in depth.
        let identityName = manifest.id.filter { c in
            c.isLetter || c.isNumber || c == "." || c == "-"
        }
        let publisher = "CN=" + identityName

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
              ProcessorArchitecture="x64" />

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
            <rescap:Capability Name="runFullTrust" />
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
