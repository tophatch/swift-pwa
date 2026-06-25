import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// Exercises the `AppContext.serveDirectory(_:at:)` / `unserveDirectory(at:)`
/// extension, which forwards to the context's shared `assetProvider`. The
/// extension is what page JS-facing content packs ultimately rely on, so we
/// assert the mount it installs is resolvable through the same provider every
/// backend hands to its scheme handler.
@Suite("AppContext.serveDirectory")
@MainActor
struct ServeDirectoryTests {
    private func tempDir(file: String, contents: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: dir.appendingPathComponent(file))
        return dir
    }

    @Test("serveDirectory mounts a directory resolvable on the shared provider")
    func servesMount() throws {
        let packs = try tempDir(file: "clip.webm", contents: "video-bytes")
        defer { try? FileManager.default.removeItem(at: packs) }
        let app = MockAppContext()

        app.serveDirectory(packs, at: "/packs")

        let resolved = try app.assetProvider.resolve(#require(URL(string: "pwa://localhost/packs/clip.webm")))
        #expect(resolved?.fileURL.lastPathComponent == "clip.webm")
        #expect(resolved?.mimeType == "video/webm")
    }

    @Test("unserveDirectory removes a mount")
    func unserves() throws {
        let packs = try tempDir(file: "a.txt", contents: "x")
        defer { try? FileManager.default.removeItem(at: packs) }
        let app = MockAppContext()

        app.serveDirectory(packs, at: "/packs")
        #expect(try app.assetProvider.resolve(#require(URL(string: "pwa://localhost/packs/a.txt"))) != nil)
        app.unserveDirectory(at: "/packs")
        #expect(try app.assetProvider.resolve(#require(URL(string: "pwa://localhost/packs/a.txt"))) == nil)
    }

    @Test("a pack added after a bundle root is set is served immediately")
    func runtimeAddAfterBundle() throws {
        let bundle = try tempDir(file: "index.html", contents: "<html></html>")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let packs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: packs.appendingPathComponent("p1"), withIntermediateDirectories: true
        )
        try Data("v".utf8).write(to: packs.appendingPathComponent("p1/clip.webm"))
        defer { try? FileManager.default.removeItem(at: packs) }

        let app = MockAppContext()
        // Bundle installed first (mirrors a window being created)...
        app.assetProvider.setBundleRoot(bundle)
        // ...then a pack mounted at runtime resolves without re-registering.
        app.serveDirectory(packs, at: "/packs")

        #expect(try app.assetProvider.resolve(#require(URL(string: "pwa://localhost/index.html"))) != nil)
        #expect(try app.assetProvider.resolve(#require(URL(string: "pwa://localhost/packs/p1/clip.webm"))) != nil)
    }
}
