import Foundation
@testable import SwiftPWACLISupport
import Testing

/// #214: `permissions.web` maps *web* capabilities onto Android permissions,
/// so a permission with no web counterpart — `MANAGE_EXTERNAL_STORAGE`, which
/// an app reading the user's own folders by path needs — could not be declared
/// at all. Hand-editing the generated `AndroidManifest.xml` doesn't survive the
/// next build, which regenerates it.
@Suite("android.permissions passthrough")
struct AndroidExtraPermissionTests {
    private func manifest(permissions: [String]?) -> PWAManifest {
        var m = PWAManifest(
            id: "com.example.app",
            name: "App",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: "App")
        )
        m.android = .init(permissions: permissions)
        return m
    }

    @Test("the key decodes from pwa.json")
    func decodes() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(PWAManifest.self, from: Data("""
        {
          "id": "com.example.app",
          "name": "App",
          "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "App", "width": 1024, "height": 768, "resizable": true, "fullscreen": false },
          "android": { "permissions": ["android.permission.MANAGE_EXTERNAL_STORAGE"] }
        }
        """.utf8))
        #expect(decoded.android?.permissions == ["android.permission.MANAGE_EXTERNAL_STORAGE"])
    }

    @Test("a declared permission reaches the generated manifest verbatim")
    func reachesTheManifest() {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false,
            extraPermissions: [
                "android.permission.MANAGE_EXTERNAL_STORAGE",
                // An OEM permission — the reason this isn't an allowlist.
                "com.example.oem.permission.SOMETHING"
            ]
        )
        #expect(xml.contains(#"<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>"#))
        #expect(xml.contains(#"<uses-permission android:name="com.example.oem.permission.SOMETHING"/>"#))
        #expect(xml.hasPrefix("<?xml"))
        #expect(xml.contains("</manifest>"))
    }

    @Test("an entry swift-pwa already declares is dropped, not doubled")
    func deduplicatesAgainstBuiltIns() {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false,
            extraPermissions: ["android.permission.INTERNET", "android.permission.INTERNET"]
        )
        let count = xml.components(separatedBy: #"android:name="android.permission.INTERNET""#).count - 1
        #expect(count == 1)
    }

    @Test("an entry the web-permission mapping already emitted is dropped too")
    func deduplicatesAgainstWebPermissions() {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false,
            webPermissions: ["camera"],
            extraPermissions: ["android.permission.CAMERA"]
        )
        let count = xml.components(separatedBy: #"android:name="android.permission.CAMERA""#).count - 1
        #expect(count == 1)
    }

    @Test("an app that declares none gains no extra lines")
    func absentChangesNothing() {
        let bare = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false
        )
        let withEmpty = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false, extraPermissions: []
        )
        #expect(bare == withEmpty)
        #expect(!bare.contains("android.permissions in pwa.json"))
    }

    /// The built-in list is duplicated by hand from the template's literal
    /// block, so it can drift — and drift here is invisible: a doubled
    /// `<uses-permission>` is legal, merges silently, and nobody notices.
    @Test("the built-in name list matches what the template actually emits")
    func builtInListMatchesTemplate() {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false
        )
        for name in AndroidTemplates.builtInPermissionNames {
            #expect(xml.contains(#"<uses-permission android:name="\#(name)"/>"#), "not emitted: \(name)")
        }
        let emitted = xml.split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("<uses-permission android:name=\"") else { return nil }
                return trimmed.dropFirst(31).prefix(while: { $0 != "\"" }).description
            }
        #expect(Set(emitted) == AndroidTemplates.builtInPermissionNames)
    }

    // MARK: - Validation

    @Test("a bare permission name is refused, naming the fully-qualified form")
    func refusesUnqualifiedName() {
        #expect(throws: (any Error).self) {
            try Build.validateAndroidPermissions(manifest: manifest(permissions: ["MANAGE_EXTERNAL_STORAGE"]))
        }
    }

    @Test("markup that would break the manifest is refused")
    func refusesMarkup() {
        for bad in ["android.permission.A\"/><uses-permission android:name=\"b", "a b.c", "", "no-dots"] {
            #expect(throws: (any Error).self, "accepted \(bad)") {
                try Build.validateAndroidPermissions(manifest: manifest(permissions: [bad]))
            }
        }
    }

    @Test("real permission names pass, including OEM ones")
    func acceptsRealNames() throws {
        try Build.validateAndroidPermissions(manifest: manifest(permissions: [
            "android.permission.MANAGE_EXTERNAL_STORAGE",
            "android.permission.SCHEDULE_EXACT_ALARM",
            "com.samsung.android.permission.SOMETHING"
        ]))
        try Build.validateAndroidPermissions(manifest: manifest(permissions: nil))
    }
}
