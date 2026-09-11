import Foundation
@testable import SwiftPWACLISupport
import Testing

/// `url_schemes` — the inbound declaration — has to reach a different artifact
/// on every platform for a deep link to arrive at all, and every one of those
/// failures is silent (the link simply doesn't open the app). So each is
/// asserted here rather than trusted.
@Suite("url_schemes declaration")
struct URLSchemeDeclarationTests {
    private func manifest(
        schemes: [String]? = nil,
        linuxDocs: [PWAManifest.MimeDocumentType]? = nil,
        windowsDocs: [PWAManifest.ExtensionDocumentType]? = nil
    ) -> PWAManifest {
        var m = PWAManifest(
            id: "com.example.myapp",
            name: "My App",
            executableName: nil,
            version: "1.2.3",
            description: "An app.",
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "My App")
        )
        m.urlSchemes = schemes
        if let linuxDocs { m.linux = .init(desktopCategories: nil, executableName: nil, documentTypes: linuxDocs) }
        if let windowsDocs { m.windows = .init(documentTypes: windowsDocs) }
        return m
    }

    // MARK: - Normalization

    @Test("a scheme is accepted however it's written, and de-duplicated")
    func normalization() {
        #expect(URLSchemeSupport.normalized(["MyApp", "myapp:", "myapp://", " MyApp "]) == ["myapp"])
        #expect(URLSchemeSupport.normalized(["a-b.c+d"]) == ["a-b.c+d"])
        #expect(URLSchemeSupport.normalized(["9lives", "", "has space"]).isEmpty)
    }

    // MARK: - Apple

    @Test("no schemes → no CFBundleURLTypes (unchanged)")
    func appleNoSchemes() {
        let mac = InfoPlistGenerator.macOS(manifest: manifest(), executableName: "myapp")
        #expect(mac["CFBundleURLTypes"] == nil)
        let ios = InfoPlistGenerator.iOS(manifest: manifest(), executableName: "myapp")
        #expect(ios["CFBundleURLTypes"] == nil)
    }

    @Test("schemes → one CFBundleURLTypes entry listing them, on macOS and iOS alike")
    func appleWithSchemes() throws {
        for plist in [
            InfoPlistGenerator.macOS(manifest: manifest(schemes: ["MyApp", "myapp-beta"]), executableName: "myapp"),
            InfoPlistGenerator.iOS(manifest: manifest(schemes: ["MyApp", "myapp-beta"]), executableName: "myapp")
        ] {
            let types = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
            #expect(types.count == 1)
            #expect(types[0]["CFBundleURLSchemes"] as? [String] == ["myapp", "myapp-beta"])
            #expect(types[0]["CFBundleURLName"] as? String == "com.example.myapp")
            // Viewer, not Editor: receiving a link displays what it points at.
            #expect(types[0]["CFBundleTypeRole"] as? String == "Viewer")
        }
    }

    /// The passthrough is merged after, so an app that wants a hand-written
    /// registration (per-scheme names, a different role) still wins.
    @Test("an explicit info_plist CFBundleURLTypes overrides the generated one")
    func appleInfoPlistPassthroughWins() throws {
        var m = manifest(schemes: ["myapp"])
        m.macos = .init(bundleIdentifier: nil)
        m.macos?.infoPlist = ["CFBundleURLTypes": .array([.object(["CFBundleURLSchemes": .array([.string("other")])])])]
        let plist = InfoPlistGenerator.macOS(manifest: m, executableName: "myapp")
        let types = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        #expect(types[0]["CFBundleURLSchemes"] as? [String] == ["other"])
    }

    // MARK: - Linux .desktop

    @Test("schemes → an x-scheme-handler MIME entry per scheme, and %U")
    func desktopWithSchemes() {
        let entry = AppImageBundler.desktopEntry(
            manifest: manifest(schemes: ["myapp"]), exeName: "myapp"
        )
        #expect(entry.contains("Exec=myapp %U"))
        #expect(entry.contains("MimeType=x-scheme-handler/myapp;"))
    }

    /// A field code is singular, and `%U` is the general one — it accepts URLs
    /// *and* local paths, where `%F` would drop every deep link.
    @Test("schemes and document types together get %U, with both MIME kinds listed")
    func desktopWithBoth() {
        let entry = AppImageBundler.desktopEntry(
            manifest: manifest(schemes: ["myapp"], linuxDocs: [.init(mimeTypes: ["image/png"])]),
            exeName: "myapp"
        )
        #expect(entry.contains("Exec=myapp %U"))
        #expect(!entry.contains("%F"))
        #expect(entry.contains("MimeType=image/png;x-scheme-handler/myapp;"))
    }

    // MARK: - Windows MSIX

    @Test("no schemes → no protocol extension (unchanged)")
    func msixNoSchemes() {
        let xml = AppxManifestGenerator.render(manifest: manifest())
        #expect(!xml.contains("windows.protocol"))
        #expect(!xml.contains("<Extensions>"))
    }

    @Test("schemes → a uap:Protocol per scheme")
    func msixWithSchemes() {
        let xml = AppxManifestGenerator.render(manifest: manifest(schemes: ["myapp", "myapp-beta"]))
        #expect(xml.contains("<uap:Protocol Name=\"myapp\" />"))
        #expect(xml.contains("<uap:Protocol Name=\"myapp-beta\" />"))
    }

    /// There can only be one `<Extensions>` element, so the two generators
    /// have to join rather than each emitting a wrapper — an app declaring
    /// both would otherwise produce a manifest the MSIX schema rejects.
    @Test("protocols and file types share one Extensions block")
    func msixBothInOneExtensionsBlock() {
        let xml = AppxManifestGenerator.render(manifest: manifest(
            schemes: ["myapp"], windowsDocs: [.init(extensions: [".foo"], name: "My Docs")]
        ))
        #expect(xml.components(separatedBy: "<Extensions>").count == 2)
        #expect(xml.components(separatedBy: "</Extensions>").count == 2)
        #expect(xml.contains("windows.protocol"))
        #expect(xml.contains("windows.fileTypeAssociation"))
    }

    // MARK: - Windows portable registration

    @Test("no schemes → no registration script")
    func portableNoSchemes() {
        #expect(URLSchemeSupport.registrationScripts(schemes: [], exeName: "myapp.exe", appName: "My App") == nil)
    }

    @Test("the portable script writes a URL-handler class pointing at the exe's own folder")
    func portableScripts() throws {
        let scripts = try #require(URLSchemeSupport.registrationScripts(
            schemes: ["myapp"], exeName: "myapp.exe", appName: "My App"
        ))
        let register = scripts.register.joined(separator: "\n")
        #expect(register.contains("set \"EXE=%~dp0myapp.exe\""))
        #expect(register.contains(#"reg add "HKCU\Software\Classes\myapp" /ve /d "URL:My App" /f"#))
        // The presence of an (empty) `URL Protocol` value is what marks the
        // class as a URL handler — not a placeholder.
        #expect(register.contains(#"/v "URL Protocol" /d "" /f"#))
        #expect(register.contains(#"HKCU\Software\Classes\myapp\shell\open\command"#))
        #expect(register.contains("%%1"))
        #expect(scripts.unregister.joined(separator: "\n")
            .contains(#"reg delete "HKCU\Software\Classes\myapp" /f"#))
    }

    // MARK: - Android

    @Test("no schemes → no VIEW/BROWSABLE filter (unchanged)")
    func androidNoSchemes() {
        let xml = AndroidTemplates.androidManifestXml(packageId: "com.example.myapp", label: "My App", hasIcon: false)
        #expect(!xml.contains("BROWSABLE"))
        #expect(!xml.contains("android:scheme"))
    }

    /// BROWSABLE is the whole point: without it the filter matches an intent
    /// another app builds by hand but not a link tapped in a browser or mail
    /// client, which is where deep links come from.
    @Test("schemes → one VIEW filter with BROWSABLE and a data spec per scheme")
    func androidWithSchemes() {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.myapp", label: "My App", hasIcon: false,
            urlSchemes: ["myapp", "myapp-beta"]
        )
        #expect(xml.contains("<category android:name=\"android.intent.category.BROWSABLE\"/>"))
        #expect(xml.contains("<data android:scheme=\"myapp\"/>"))
        #expect(xml.contains("<data android:scheme=\"myapp-beta\"/>"))
    }

    // MARK: - Validation

    @Test("a scheme that isn't one is refused before anything is built")
    func rejectsMalformedScheme() {
        var m = manifest(schemes: ["myapp://open"])
        #expect(throws: (any Error).self) { try Build.validateExternalURLs(manifest: m) }
        m = manifest(schemes: ["9lives"])
        #expect(throws: (any Error).self) { try Build.validateExternalURLs(manifest: m) }
    }

    /// Claiming `https` would put the app in the system's browser chooser and
    /// claiming `mailto` shadows a handler the user already has — neither is
    /// what declaring a deep link means, and both are hard to notice after.
    @Test("a system-owned scheme is refused, and says what the app wanted instead")
    func rejectsReservedScheme() {
        for reserved in ["https", "file", "mailto", "pwa"] {
            #expect(throws: (any Error).self) {
                try Build.validateExternalURLs(manifest: manifest(schemes: [reserved]))
            }
        }
    }

    @Test("a well-formed declaration passes")
    func acceptsGoodScheme() throws {
        try Build.validateExternalURLs(manifest: manifest(schemes: ["myapp", "MyApp-Beta:"]))
    }
}
