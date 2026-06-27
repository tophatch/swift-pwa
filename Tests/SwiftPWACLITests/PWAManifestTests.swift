import Foundation
@testable import SwiftPWACLISupport
import Testing

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

    @Test("ai.local_llama decodes from snake_case and round-trips")
    func aiLocalLlama() throws {
        let json = #"""
        {
          "id": "com.example.hi", "name": "Hi", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Hi", "width": 1024, "height": 768, "resizable": true, "fullscreen": false },
          "ai": { "local_llama": true }
        }
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        #expect(m.ai?.localLlama == true)

        // Round-trips back to the snake_case key.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pwa-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try m.write(to: tmp)
        #expect(try String(contentsOf: tmp, encoding: .utf8).contains("local_llama"))
    }

    @Test("ai.gemini_nano decodes from snake_case and round-trips")
    func aiGeminiNano() throws {
        let json = #"""
        {
          "id": "com.example.hi", "name": "Hi", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Hi", "width": 1024, "height": 768, "resizable": true, "fullscreen": false },
          "ai": { "gemini_nano": true }
        }
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        #expect(m.ai?.geminiNano == true)
        #expect(m.ai?.localLlama == nil)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pwa-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try m.write(to: tmp)
        #expect(try String(contentsOf: tmp, encoding: .utf8).contains("gemini_nano"))
    }

    @Test("ai.phi_silica decodes from snake_case and round-trips")
    func aiPhiSilica() throws {
        let json = #"""
        {
          "id": "com.example.hi", "name": "Hi", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Hi", "width": 1024, "height": 768, "resizable": true, "fullscreen": false },
          "ai": { "phi_silica": true }
        }
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        #expect(m.ai?.phiSilica == true)
        #expect(m.ai?.geminiNano == nil)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pwa-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try m.write(to: tmp)
        #expect(try String(contentsOf: tmp, encoding: .utf8).contains("phi_silica"))
    }

    @Test("executable_name round-trips and drives binaryName; otherwise falls back to name")
    func executableNameRoundTrips() throws {
        var m = PWAManifest(
            id: "com.example.hi",
            name: "Field Notes",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "Field Notes")
        )
        // No executable_name yet → binaryName falls back to the display name.
        #expect(m.binaryName == "Field Notes")

        m.executableName = "FieldNotes"
        #expect(m.binaryName == "FieldNotes")

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pwa-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try m.write(to: tmp)
        let raw = try String(contentsOf: tmp, encoding: .utf8)
        #expect(raw.contains("executable_name"))
        let decoded = try PWAManifest.load(from: tmp)
        #expect(decoded.executableName == "FieldNotes")
        #expect(decoded.binaryName == "FieldNotes")
    }
}
