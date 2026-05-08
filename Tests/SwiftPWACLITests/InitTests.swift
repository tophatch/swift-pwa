import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("swift-pwa init")
struct InitTests {
    private func tmpDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-init-\(UUID().uuidString)")
    }

    @Test("scaffolds into a fresh directory")
    func freshDir() async throws {
        let parent = tmpDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let target = parent.appendingPathComponent("MyApp")
        let cmd = try Init.parse(["MyApp", "--path", target.path])
        try await cmd.run()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: target.appendingPathComponent("pwa.json").path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Package.swift").path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Sources/MyApp/App.swift").path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("web/index.html").path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent(".gitignore").path))
    }

    @Test("scaffolds in-place into an existing directory with no conflicts")
    func inPlaceWithSiblingFiles() async throws {
        let target = tmpDir()
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Pre-existing unrelated files: should be left alone.
        try "hello".write(
            to: target.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let cmd = try Init.parse(["MyApp", "--path", target.path])
        try await cmd.run()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: target.appendingPathComponent("pwa.json").path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Package.swift").path))
        // Pre-existing files untouched.
        let readme = try String(contentsOf: target.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme == "hello")
        #expect(fm.fileExists(atPath: target.appendingPathComponent(".git").path))
    }

    @Test("refuses to clobber an existing scaffolded project")
    func refusesConflicts() async throws {
        let target = tmpDir()
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "{}".write(
            to: target.appendingPathComponent("pwa.json"),
            atomically: true,
            encoding: .utf8
        )

        let cmd = try Init.parse(["MyApp", "--path", target.path])
        do {
            try await cmd.run()
            Issue.record("expected init to refuse overwriting pwa.json")
        } catch {
            #expect(String(describing: error).contains("pwa.json"))
        }
        // Pre-existing pwa.json untouched.
        let original = try String(
            contentsOf: target.appendingPathComponent("pwa.json"),
            encoding: .utf8
        )
        #expect(original == "{}")
    }
}
