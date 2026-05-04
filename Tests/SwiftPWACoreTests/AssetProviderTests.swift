import Foundation
@testable import SwiftPWACore
import Testing

@Suite("AssetProvider")
struct AssetProviderTests {
    private func tempBundle() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-asset-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<html>hi</html>".utf8)
            .write(to: dir.appendingPathComponent("index.html"))
        try Data("body{}".utf8).write(to: dir.appendingPathComponent("style.css"))
        return dir
    }

    @Test("resolves index.html for the bare host")
    func resolvesIndex() throws {
        let dir = try tempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AssetProvider(root: dir)
        let resolved = try provider.resolve(#require(URL(string: "pwa://localhost/")))
        #expect(resolved?.fileURL.lastPathComponent == "index.html")
        #expect(resolved?.mimeType == "text/html; charset=utf-8")
    }

    @Test("resolves explicit path")
    func resolvesExplicit() throws {
        let dir = try tempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AssetProvider(root: dir)
        let resolved = try provider.resolve(#require(URL(string: "pwa://localhost/style.css")))
        #expect(resolved?.mimeType == "text/css; charset=utf-8")
    }

    @Test("rejects path traversal")
    func rejectsTraversal() throws {
        let dir = try tempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AssetProvider(root: dir)
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/../etc/passwd"))) == nil)
    }

    @Test("rejects wrong scheme and host")
    func rejectsBadOrigin() throws {
        let dir = try tempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AssetProvider(root: dir)
        #expect(try provider.resolve(#require(URL(string: "https://localhost/index.html"))) == nil)
        #expect(try provider.resolve(#require(URL(string: "pwa://evil/index.html"))) == nil)
    }

    @Test("returns nil for missing files")
    func missing() throws {
        let dir = try tempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AssetProvider(root: dir)
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/missing.html"))) == nil)
    }
}
