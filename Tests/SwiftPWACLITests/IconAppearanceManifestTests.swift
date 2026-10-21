import Foundation
@testable import SwiftPWACLISupport
import Testing

/// `icon` as one PNG or one per appearance, and `alternate_icons` (#314).
@Suite("App icon appearances and alternates in pwa.json")
struct IconAppearanceManifestTests {
    private func manifest(_ keys: String) throws -> PWAManifest {
        let json = """
        { "id": "com.example.hi", "name": "Hi", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Hi", "width": 1024, "height": 768, "resizable": true, "fullscreen": false }
          \(keys) }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PWAManifest.self, from: Data(json.utf8))
    }

    @Test("a plain path is the light art, with no appearances")
    func plainPath() throws {
        let m = try manifest(#", "icon": "icon.png""#)
        #expect(m.iconArt(for: .ios) == PWAManifest.IconArt(light: "icon.png"))
        #expect(m.iconArt(for: .ios)?.hasAppearances == false)
        #expect(m.icon(for: .android) == "icon.png")
    }

    @Test("an object carries each appearance, and icon(for:) stays the light path")
    func perAppearance() throws {
        let m = try manifest(#", "icon": { "light": "l.png", "dark": "d.png", "tinted": "t.png" }"#)
        let art = try #require(m.iconArt(for: .macos))
        #expect(art == PWAManifest.IconArt(light: "l.png", dark: "d.png", tinted: "t.png"))
        #expect(art.hasAppearances)
        #expect(art.paths == ["l.png", "d.png", "t.png"])
        #expect(m.icon(for: .macos) == "l.png")
    }

    @Test("dark and tinted are each optional")
    func partialAppearances() throws {
        let m = try manifest(#", "icon": { "light": "l.png", "tinted": "t.png" }"#)
        #expect(m.iconArt(for: .android) == PWAManifest.IconArt(light: "l.png", tinted: "t.png"))
    }

    /// A per-target override exists because that target wants different
    /// pictures; merging the top-level dark art into a pre-masked macOS icon
    /// would put full-bleed art beside a squircle.
    @Test("a per-target icon replaces the top-level one outright")
    func overrideReplaces() throws {
        let m = try manifest(#"""
        , "icon": { "light": "l.png", "dark": "d.png" }, "macos": { "icon": "mac.png" }
        """#)
        #expect(m.iconArt(for: .macos) == PWAManifest.IconArt(light: "mac.png"))
        #expect(m.iconArt(for: .ios)?.dark == "d.png")
    }

    @Test("the icon re-encodes in the shape it was written")
    func roundTrips() throws {
        let m = try manifest(#"""
        , "icon": "plain.png", "ios": { "icon": { "light": "l.png", "dark": "d.png" } },
          "alternate_icons": [ { "name": "sketch", "icon": { "light": "s.png", "tinted": "st.png" } } ]
        """#)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pwa-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try m.write(to: tmp)
        let written = try String(contentsOf: tmp, encoding: .utf8)
        #expect(written.contains(#""icon" : "plain.png""#))
        #expect(try PWAManifest.load(from: tmp) == m)
    }

    @Test("alternate_icons decodes with its names and art")
    func alternates() throws {
        let m = try manifest(#"""
        , "alternate_icons": [ { "name": "sketch", "icon": "s.png" }, { "name": "night_2", "icon": { "light": "n.png", "dark": "nd.png" } } ]
        """#)
        #expect(m.alternateIcons?.map(\.name) == ["sketch", "night_2"])
        #expect(m.alternateIcons?.last?.icon.dark == "nd.png")
    }

    @Test("an alternate name must be lowercase letters, digits and _, starting with a letter")
    func alternateNames() {
        for good in ["sketch", "night_2", "a"] {
            #expect(PWAManifest.AlternateIcon.problem(withName: good) == nil, "\(good)")
        }
        for bad in ["", "Sketch", "2night", "_x", "night-mode", "café", "a b"] {
            #expect(PWAManifest.AlternateIcon.problem(withName: bad) != nil, "\(bad)")
        }
    }

    @Test("the build rejects a bad or repeated alternate name up front")
    func buildValidation() throws {
        try Build
            .validateAlternateIcons(
                manifest: manifest(#", "alternate_icons": [ { "name": "sketch", "icon": "s.png" } ]"#)
            )
        #expect(throws: (any Error).self) {
            try Build
                .validateAlternateIcons(
                    manifest: manifest(#", "alternate_icons": [ { "name": "Sketch", "icon": "s.png" } ]"#)
                )
        }
        #expect(throws: (any Error).self) {
            try Build.validateAlternateIcons(manifest: manifest(#"""
            , "alternate_icons": [ { "name": "sketch", "icon": "s.png" }, { "name": "sketch", "icon": "t.png" } ]
            """#))
        }
    }
}
