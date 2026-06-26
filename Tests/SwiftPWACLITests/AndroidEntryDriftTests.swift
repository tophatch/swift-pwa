import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("AndroidEntryDrift")
struct AndroidEntryDriftTests {
    private func tmpProject(packageInCdecl: String, sourceDir: String = "MyApp") -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-drift-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Sources/\(sourceDir)")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let entry = """
        #if os(Android)
        @_cdecl("Java_\(packageInCdecl)_MainActivity_swiftPwaMain")
        public func swiftpwa_MyApp_android_main(_ env: OpaquePointer?, _ thiz: OpaquePointer?) {}
        #endif
        """
        try? entry.write(to: src.appendingPathComponent("AndroidEntry.swift"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("resolvePackageId mirrors the bundler defaults")
    func resolvePackageId() {
        // Explicit package id wins.
        var m = PWAManifest(
            id: "com.example.x",
            name: "X",
            version: "1.0.0",
            web: .init(directory: "web"),
            window: .init(title: "X"),
            android: .init(packageId: "com.acme.cool")
        )
        #expect(AndroidEntryDrift.resolvePackageId(m) == "com.acme.cool")
        // Dotted top-level id is used directly.
        m = PWAManifest(
            id: "com.example.x",
            name: "X",
            version: "1.0.0",
            web: .init(directory: "web"),
            window: .init(title: "X")
        )
        #expect(AndroidEntryDrift.resolvePackageId(m) == "com.example.x")
        // Non-dotted id is namespaced.
        m = PWAManifest(
            id: "plainid",
            name: "X",
            version: "1.0.0",
            web: .init(directory: "web"),
            window: .init(title: "X")
        )
        #expect(AndroidEntryDrift.resolvePackageId(m) == "dev.swiftpwa.plainid")
    }

    @Test("declaredPackage extracts the package from the @_cdecl symbol")
    func declaredPackage() {
        let src = "@_cdecl(\"Java_com_example_hello_MainActivity_swiftPwaMain\")"
        #expect(AndroidEntryDrift.declaredPackage(in: src) == "com_example_hello")
        #expect(AndroidEntryDrift.declaredPackage(in: "no cdecl here") == nil)
    }

    @Test("detect flags a stale @_cdecl after package_id changed")
    func detectsMismatch() throws {
        // The file still names the OLD package; the manifest now says new.
        let root = tmpProject(packageInCdecl: "com_example_old")
        defer { try? FileManager.default.removeItem(at: root) }
        let mismatch = try #require(AndroidEntryDrift.detect(projectRoot: root, packageId: "com.example.new"))
        #expect(mismatch.declared == "com_example_old")
        #expect(mismatch.expected == "com_example_new")
        #expect(mismatch.file == "Sources/MyApp/AndroidEntry.swift")
    }

    @Test("detect returns nil when the symbol matches the package id")
    func noFalsePositive() {
        let root = tmpProject(packageInCdecl: "com_example_hello")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AndroidEntryDrift.detect(projectRoot: root, packageId: "com.example.hello") == nil)
    }

    @Test("detect returns nil when there is no AndroidEntry.swift")
    func noEntryFile() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-drift-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/MyApp"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AndroidEntryDrift.detect(projectRoot: root, packageId: "com.example.hello") == nil)
    }
}
