import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("swift-pwa build preflight")
struct BuildPreflightTests {
    private func tmpDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    @Test("missing Package.swift fails with guidance toward init")
    func missingPackageSwift() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try Build.preflight(manifest: manifest(name: "App"), projectRoot: root)
            Issue.record("expected preflight to reject a directory with no Package.swift")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("Package.swift"))
            #expect(message.contains("swift-pwa init"))
        }
    }

    @Test("a name with whitespace is fine on its own (the package probe resolves the real target)")
    func whitespaceNameAllowed() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// pkg".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // No executable_name: a spaced display name must NOT be rejected —
        // the bundler discovers the SwiftPM target name from the package.
        try Build.preflight(manifest: manifest(name: "Field Notes"), projectRoot: root)
    }

    @Test("an explicit executable_name with whitespace is rejected up front")
    func whitespaceExecutableNameRejected() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// pkg".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        do {
            // executable_name must name a SwiftPM target — whitespace can't.
            try Build.preflight(
                manifest: manifest(name: "Field Notes", executableName: "Field Notes"),
                projectRoot: root
            )
            Issue.record("expected preflight to reject a whitespace executable_name")
        } catch {
            #expect(String(describing: error).contains("executable_name"))
        }
    }

    @Test("whitespace display name passes when executable_name is identifier-safe")
    func whitespaceNameWithExecutableNamePasses() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// pkg".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Build.preflight(
            manifest: manifest(name: "Field Notes", executableName: "FieldNotes"),
            projectRoot: root
        )
    }
}
