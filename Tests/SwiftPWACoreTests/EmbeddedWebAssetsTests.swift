import Foundation
@testable import SwiftPWACore
import Testing

@Suite("EmbeddedWebAssets overlay")
struct EmbeddedWebAssetsTests {
    private func writeStub(_ overlay: Data, leading: Int = 4096) throws -> URL {
        // Simulate an executable: leading "PE image" bytes + the appended overlay.
        let stub = Data(repeating: 0xAB, count: leading) + overlay
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedded-test-\(UUID().uuidString).bin")
        try stub.write(to: url)
        return url
    }

    @Test("round-trips an overlay appended to a stub executable")
    func roundTrip() throws {
        let files: [(path: String, data: Data)] = [
            ("index.html", Data("<h1>hi</h1>".utf8)),
            ("assets/app.js", Data("console.log(1)".utf8)),
            ("logo.png", Data([0x89, 0x50, 0x4E, 0x47]))
        ]
        let url = try writeStub(EmbeddedWebAssets.makeOverlay(files: files))
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try #require(EmbeddedWebAssets.read(fromExecutableAt: url))
        #expect(!parsed.isEmpty)
        #expect(parsed.data(for: "index.html") == Data("<h1>hi</h1>".utf8))
        #expect(parsed.data(for: "/index.html") == Data("<h1>hi</h1>".utf8)) // leading slash tolerated
        #expect(parsed.data(for: "assets/app.js") == Data("console.log(1)".utf8))
        #expect(parsed.data(for: "logo.png") == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(parsed.data(for: "missing.txt") == nil)
        #expect(parsed.mimeType(for: "index.html") == "text/html; charset=utf-8")
        #expect(parsed.mimeType(for: "assets/app.js") == "application/javascript; charset=utf-8")
    }

    @Test("query and fragment are stripped from request paths")
    func stripsQueryAndFragment() throws {
        let url = try writeStub(EmbeddedWebAssets.makeOverlay(files: [("app.js", Data("x".utf8))]))
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try #require(EmbeddedWebAssets.read(fromExecutableAt: url))
        #expect(parsed.data(for: "app.js?v=123") == Data("x".utf8))
        #expect(parsed.data(for: "app.js#frag") == Data("x".utf8))
    }

    @Test("returns nil for an executable with no overlay")
    func noOverlay() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-overlay-\(UUID().uuidString).bin")
        try Data(repeating: 0x00, count: 1000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EmbeddedWebAssets.read(fromExecutableAt: url) == nil)
    }

    @Test("returns nil for a file smaller than the footer")
    func tinyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EmbeddedWebAssets.read(fromExecutableAt: url) == nil)
    }
}
