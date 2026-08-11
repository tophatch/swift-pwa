import Foundation
@testable import SwiftPWACLISupport
import Testing

/// Staging the SwiftPM resource bundles a build leaves beside the binary. Before
/// 0.9.10 no desktop bundler staged any, so a bundled app read them out of the
/// build machine's `.build/` — fine there, a hard crash anywhere else.
@Suite("resource bundle staging")
struct ResourceBundleStagingTests {
    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-bundles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("finds .bundle (Apple) and .resources (Linux/Windows), ignoring everything else")
    func findsBothNamings() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["MyApp_MyApp.bundle", "Dep_Dep.resources", "MyApp", "MyApp.dSYM", "libfoo.so"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        #expect(ResourceBundles.found(in: dir).map(\.lastPathComponent) == [
            "Dep_Dep.resources", "MyApp_MyApp.bundle"
        ])
    }

    @Test("stages them, and a restage replaces the earlier copy")
    func stagesAndReplaces() throws {
        let source = try tmpDir()
        let destination = try tmpDir()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let bundle = source.appendingPathComponent("MyApp_MyApp.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "one".write(to: bundle.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let staged = try ResourceBundles.stage(ResourceBundles.found(in: source), into: destination)
        #expect(staged == ["MyApp_MyApp.bundle"])

        try "two".write(to: bundle.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try ResourceBundles.stage(ResourceBundles.found(in: source), into: destination)
        let landed = try String(
            contentsOf: destination.appendingPathComponent("MyApp_MyApp.bundle/data.txt"), encoding: .utf8
        )
        #expect(landed == "two")
    }

    @Test("staging nothing is a no-op, and doesn't create the destination")
    func emptyIsNoOp() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-bundles-absent-\(UUID().uuidString)")
        #expect(try ResourceBundles.stage([], into: destination).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
