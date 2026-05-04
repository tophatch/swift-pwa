import Foundation
import Testing
@testable import swift_pwa_cli

@Suite("PWAManifest round-trip")
struct PWAManifestTests {
    @Test("encodes and decodes via snake_case")
    func roundTrip() throws {
        let original = PWAManifest(
            id: "com.example.hi",
            name: "Hi",
            version: "1.2.3",
            description: nil,
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: "Hi"),
            macos: .init(bundleIdentifier: "com.example.hi", category: nil, minimumSystemVersion: "15.0"),
            ios: .init(bundleIdentifier: "com.example.hi", minimumSystemVersion: "18.0"),
            linux: .init(desktopCategories: ["Utility"], executableName: "hi")
        )
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pwa-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try original.write(to: tmp)
        let raw = try String(contentsOf: tmp, encoding: .utf8)
        // Sanity: snake_case key for minimumSystemVersion.
        #expect(raw.contains("minimum_system_version"))
        let decoded = try PWAManifest.load(from: tmp)
        #expect(decoded == original)
    }
}
