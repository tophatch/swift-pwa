import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("ExecutableNameResolver")
struct ExecutableNameResolverTests {
    private func manifest(name: String, executableName: String? = nil) -> PWAManifest {
        PWAManifest(
            id: "com.example.x",
            name: name,
            executableName: executableName,
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: name)
        )
    }

    @Test("an explicit executable_name wins without probing the package")
    func explicitOverrideWins() async {
        // projectRoot has no package at all — proving the explicit
        // override short-circuits before any `swift package describe`.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-resolver-\(UUID().uuidString)")
        let resolved = await ExecutableNameResolver.resolve(
            projectRoot: root,
            manifest: manifest(name: "Field Notes", executableName: "FieldNotes")
        )
        #expect(resolved == "FieldNotes")
    }

    @Test("falls back to binaryName when the package probe can't run")
    func fallbackWhenNoPackage() async throws {
        // An empty directory (no Package.swift) makes `swift package
        // describe` fail; the resolver should fall back to binaryName
        // (executable_name ?? name) rather than throw.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = await ExecutableNameResolver.resolve(
            projectRoot: root,
            manifest: manifest(name: "PlainName")
        )
        #expect(resolved == "PlainName")
    }
}
