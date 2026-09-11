import Foundation
@testable import SwiftPWACLISupport
import Testing

/// macOS and iOS want opposite artwork from one project — a pre-masked
/// squircle with padding vs. full bleed — so the icon has to be resolvable
/// per target.
@Suite("Per-platform app icon")
struct PerPlatformIconTests {
    private func manifest(_ platformKeys: String) throws -> PWAManifest {
        let json = """
        { "id": "com.example.hi", "name": "Hi", "version": "1.0.0",
          "icon": "icon.png",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Hi", "width": 1024, "height": 768, "resizable": true, "fullscreen": false }
          \(platformKeys) }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PWAManifest.self, from: Data(json.utf8))
    }

    @Test("every target falls back to the top-level icon")
    func fallsBackToTopLevel() throws {
        let m = try manifest("")
        for target in BuildTarget.allCases {
            #expect(m.icon(for: target) == "icon.png")
        }
    }

    @Test("a platform section's icon wins for that target only")
    func platformOverrideIsScoped() throws {
        let m = try manifest(#", "macos": { "icon": "icon-macos.png" }"#)
        #expect(m.icon(for: .macos) == "icon-macos.png")
        #expect(m.icon(for: .ios) == "icon.png")
        #expect(m.icon(for: .linux) == "icon.png")
        #expect(m.icon(for: .windows) == "icon.png")
        #expect(m.icon(for: .android) == "icon.png")
    }

    @Test("each platform section carries its own key")
    func allFiveSectionsAccepted() throws {
        let m = try manifest("""
        , "macos": { "icon": "m.png" }, "ios": { "icon": "i.png" },
          "linux": { "icon": "l.png" }, "windows": { "icon": "w.png" },
          "android": { "icon": "a.png" }
        """)
        #expect(m.icon(for: .macos) == "m.png")
        #expect(m.icon(for: .ios) == "i.png")
        #expect(m.icon(for: .linux) == "l.png")
        #expect(m.icon(for: .windows) == "w.png")
        #expect(m.icon(for: .android) == "a.png")
    }

    /// An override with no top-level `icon` at all has to work — that's the
    /// shape of a project that only ever ships per-platform art.
    @Test("an override stands on its own with no top-level icon")
    func overrideWithoutTopLevel() throws {
        let json = """
        { "id": "com.example.hi", "name": "Hi", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Hi", "width": 1024, "height": 768, "resizable": true, "fullscreen": false },
          "ios": { "icon": "i.png" } }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        #expect(m.icon(for: .ios) == "i.png")
        #expect(m.icon(for: .macos) == nil)
    }

    @Test("the key survives a manifest round-trip")
    func roundTrips() throws {
        let m = try manifest(#", "ios": { "icon": "icon-ios.png" }"#)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pwa-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try m.write(to: tmp)
        #expect(try PWAManifest.load(from: tmp).icon(for: .ios) == "icon-ios.png")
    }
}
