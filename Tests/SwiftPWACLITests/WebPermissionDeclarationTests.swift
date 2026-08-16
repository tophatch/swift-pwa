import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("pwa.json permissions.web")
struct WebPermissionDeclarationTests {
    private func decode(_ json: String) throws -> PWAManifest.PermissionsSection {
        try JSONDecoder().decode(
            PWAManifest.PermissionsSection.self, from: Data(json.utf8)
        )
    }

    @Test("the list shorthand decodes")
    func listForm() throws {
        let section = try decode(#"{"web": ["microphone", "geolocation"]}"#)
        #expect(section.web?.names == ["microphone", "geolocation"])
        #expect(section.web?.detail(for: "microphone") == nil)
    }

    @Test("the object form decodes, carrying Apple's mandatory purpose string")
    func objectForm() throws {
        let section = try decode("""
        {"web": {
            "microphone": {"reason": "Record a voice note."},
            "geolocation": {"reason": "Show jobs near you."}
        }}
        """)
        // Sorted, because a JSON object has no order and the artifact it
        // generates should not change between builds.
        #expect(section.web?.names == ["geolocation", "microphone"])
        #expect(section.web?.detail(for: "microphone")?.reason == "Record a voice note.")
    }

    @Test("an absent permissions block stays absent")
    func absent() throws {
        let manifest = try JSONDecoder().decode(PWAManifest.self, from: Data("""
        {"id": "com.example.app", "name": "App", "version": "1.0.0",
         "web": {"directory": "web", "entry": "index.html"},
         "window": {"title": "App", "width": 1024, "height": 768,
                    "resizable": true, "fullscreen": false}}
        """.utf8))
        #expect(manifest.permissions == nil)
    }

    // MARK: - What it generates

    @Test("declared permissions reach the Android manifest, location as both precisions")
    func androidManifestEmission() {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false,
            webPermissions: ["microphone", "camera", "geolocation"]
        )
        #expect(xml.contains(#"<uses-permission android:name="android.permission.RECORD_AUDIO"/>"#))
        #expect(xml.contains(#"<uses-permission android:name="android.permission.CAMERA"/>"#))
        // Fine alone never offers the user the coarse-only choice.
        #expect(xml.contains(#"<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>"#))
        #expect(xml.contains(#"<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>"#))
    }

    @Test("an app that declares nothing gains no permission lines")
    func androidManifestUnchanged() {
        // An undeclared permission in the manifest is a Play Store review
        // question and a scarier install screen, so silence is the default.
        let bare = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false
        )
        #expect(!bare.contains("RECORD_AUDIO"))
        #expect(!bare.contains("android.permission.CAMERA"))
        #expect(!bare.contains("ACCESS_FINE_LOCATION"))
    }

    @Test("notifications adds nothing — POST_NOTIFICATIONS is already unconditional")
    func notificationsIsNotDuplicated() {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false,
            webPermissions: ["notifications"]
        )
        let occurrences = xml.components(separatedBy: "POST_NOTIFICATIONS").count - 1
        // Once in the comment, once in the element — but not a second element.
        #expect(xml.components(separatedBy: #"android:name="android.permission.POST_NOTIFICATIONS""#).count - 1 == 1)
        #expect(occurrences >= 1)
    }

    @Test("the generated manifest is still well-formed XML with permissions in it")
    func stillParses() {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.app", label: "App", hasIcon: false,
            webPermissions: ["camera"]
        )
        // Cheap structural check rather than a parser dependency: the block is
        // spliced by string interpolation, so a botched splice shows up as a
        // stray line outside <manifest> or a broken element.
        #expect(xml.hasPrefix("<?xml"))
        #expect(xml.contains("</manifest>"))
        let cameraLine = xml.split(separator: "\n").first { $0.contains("android.permission.CAMERA") }
        #expect(cameraLine?.trimmingCharacters(in: .whitespaces)
            == #"<uses-permission android:name="android.permission.CAMERA"/>"#)
    }
}
