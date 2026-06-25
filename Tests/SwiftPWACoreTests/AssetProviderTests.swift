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

    @Test("reports the file size on the resolved asset")
    func reportsFileSize() throws {
        let dir = try tempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AssetProvider(root: dir)
        let resolved = try provider.resolve(#require(URL(string: "pwa://localhost/style.css")))
        #expect(resolved?.fileSize == Int64("body{}".utf8.count))
    }

    @Test("a mounted prefix serves from a second root, longest-prefix wins")
    func mountServesSecondRoot() throws {
        let bundle = try tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let packs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-packs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: packs.appendingPathComponent("p1"), withIntermediateDirectories: true
        )
        try Data("clip".utf8).write(to: packs.appendingPathComponent("p1/clip.webm"))
        defer { try? FileManager.default.removeItem(at: packs) }

        let provider = AssetProvider(root: bundle)
        provider.mount(packs, at: "/packs")

        let served = try provider.resolve(#require(URL(string: "pwa://localhost/packs/p1/clip.webm")))
        #expect(served?.fileURL.lastPathComponent == "clip.webm")
        #expect(served?.mimeType == "video/webm")
        // The bundle (/) mount still resolves.
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/index.html"))) != nil)
    }

    @Test("a mounted root keeps its own traversal guard")
    func mountTraversalGuarded() throws {
        let bundle = try tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let packs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-packs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packs) }

        let provider = AssetProvider(root: bundle)
        provider.mount(packs, at: "/packs")
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/packs/../../etc/passwd"))) == nil)
    }

    @Test("a provider with no bundle resolves nothing until setBundleRoot")
    func emptyInitThenSetBundleRoot() throws {
        let dir = try tempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Context-level provider starts bundle-less (a .remote-only app
        // never installs one).
        let provider = AssetProvider()
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/index.html"))) == nil)
        provider.setBundleRoot(dir)
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/index.html"))) != nil)
    }

    @Test("setBundleRoot replaces the bundle, keeping serveDirectory mounts")
    func setBundleRootReplaces() throws {
        let first = try tempBundle()
        let second = try tempBundle()
        defer { try? FileManager.default.removeItem(at: first) }
        defer { try? FileManager.default.removeItem(at: second) }
        let packs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-packs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: packs.appendingPathComponent("a.txt"))
        defer { try? FileManager.default.removeItem(at: packs) }

        let provider = AssetProvider()
        provider.setBundleRoot(first)
        provider.mount(packs, at: "/packs")
        provider.setBundleRoot(second)
        // New bundle resolves...
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/index.html")))?
            .fileURL.path.hasPrefix(second.path) == true)
        // ...and the runtime mount survived the bundle swap.
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/packs/a.txt"))) != nil)
    }

    @Test("mount at the root prefix is rejected (bundle is reserved)")
    func mountAtRootRejected() throws {
        let bundle = try tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let other = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("evil".utf8).write(to: other.appendingPathComponent("index.html"))
        defer { try? FileManager.default.removeItem(at: other) }

        let provider = AssetProvider(root: bundle)
        provider.mount(other, at: "/") // no-op: can't shadow the bundle
        let resolved = try provider.resolve(#require(URL(string: "pwa://localhost/index.html")))
        #expect(resolved?.fileURL.path.hasPrefix(bundle.path) == true)
    }

    @Test("isServedPrefix distinguishes served mounts from the bundle")
    func isServedPrefix() throws {
        let bundle = try tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let packs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-packs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packs) }

        let provider = AssetProvider(root: bundle)
        provider.mount(packs, at: "/packs")
        // Under a served prefix (even for a file that doesn't exist) → true.
        #expect(try provider.isServedPrefix(#require(URL(string: "pwa://localhost/packs/missing.webm"))))
        #expect(try provider.isServedPrefix(#require(URL(string: "pwa://localhost/packs"))))
        // Bundle paths and the root → false (native serving handles those).
        #expect(try !provider.isServedPrefix(#require(URL(string: "pwa://localhost/index.html"))))
        #expect(try !provider.isServedPrefix(#require(URL(string: "pwa://localhost/"))))
        // A near-miss prefix that isn't a path-segment boundary → false.
        #expect(try !provider.isServedPrefix(#require(URL(string: "pwa://localhost/packsextra/x"))))
        // Wrong origin → false.
        #expect(try !provider.isServedPrefix(#require(URL(string: "https://evil/packs/x"))))
    }

    @Test("unmount removes a prefix but never the bundle root")
    func unmount() throws {
        let bundle = try tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let packs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-packs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: packs.appendingPathComponent("a.txt"))
        defer { try? FileManager.default.removeItem(at: packs) }

        let provider = AssetProvider(root: bundle)
        provider.mount(packs, at: "/packs")
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/packs/a.txt"))) != nil)
        provider.unmount(at: "/packs")
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/packs/a.txt"))) == nil)
        // Bundle root survives an attempt to unmount it.
        provider.unmount(at: "/")
        #expect(try provider.resolve(#require(URL(string: "pwa://localhost/index.html"))) != nil)
    }
}
