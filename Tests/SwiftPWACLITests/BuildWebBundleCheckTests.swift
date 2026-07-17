import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("swift-pwa build web-bundle check")
struct BuildWebBundleCheckTests {
    private func tmpDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-webcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifest(directory: String = "web", entry: String = "index.html", prebuild: String? = nil)
        -> PWAManifest
    {
        var m = PWAManifest(
            id: "com.example.x",
            name: "App",
            executableName: nil,
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: directory, entry: entry),
            window: .init(title: "App")
        )
        if let prebuild { m.build = .init(prebuild: prebuild) }
        return m
    }

    /// Write a minimal, valid `web/` bundle (a directory + its entry file).
    private func writeWeb(in root: URL, directory: String = "web", entry: String = "index.html") throws {
        let webDir = root.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        try "<html></html>".write(
            to: webDir.appendingPathComponent(entry), atomically: true, encoding: .utf8
        )
    }

    @Test("a valid web bundle passes")
    func validBundlePasses() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeWeb(in: root)
        try Build.checkWebBundle(manifest: manifest(), projectRoot: root, prebuildRan: false)
    }

    @Test("a missing web.directory fails loud")
    func missingDirectoryFails() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try Build.checkWebBundle(manifest: manifest(directory: "dist"), projectRoot: root, prebuildRan: false)
            Issue.record("expected a missing web.directory to fail the build")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("web bundle not found"))
            #expect(message.contains("dist"))
            // No prebuild → the hint should nudge toward building first.
            #expect(message.contains("npm run build"))
        }
    }

    @Test("an empty web.directory fails loud")
    func emptyDirectoryFails() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("web"), withIntermediateDirectories: true
        )
        // A lone dotfile doesn't count as a bundle.
        try "".write(to: root.appendingPathComponent("web/.gitkeep"), atomically: true, encoding: .utf8)
        do {
            try Build.checkWebBundle(manifest: manifest(), projectRoot: root, prebuildRan: false)
            Issue.record("expected an empty web.directory to fail the build")
        } catch {
            #expect(String(describing: error).contains("web bundle is empty"))
        }
    }

    @Test("a web.directory that is a file (not a dir) fails loud")
    func notADirectoryFails() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "not a dir".write(to: root.appendingPathComponent("web"), atomically: true, encoding: .utf8)
        do {
            try Build.checkWebBundle(manifest: manifest(), projectRoot: root, prebuildRan: false)
            Issue.record("expected a file at web.directory to fail the build")
        } catch {
            #expect(String(describing: error).contains("not a directory"))
        }
    }

    @Test("a bundle missing its entry file fails loud")
    func missingEntryFails() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let webDir = root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        // Assets present, but not the declared entry file.
        try "body{}".write(to: webDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        do {
            try Build.checkWebBundle(manifest: manifest(entry: "index.html"), projectRoot: root, prebuildRan: false)
            Issue.record("expected a missing entry file to fail the build")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("web entry file not found"))
            #expect(message.contains("index.html"))
        }
    }

    @Test("a custom entry name is honored")
    func customEntryHonored() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeWeb(in: root, entry: "app.html")
        try Build.checkWebBundle(manifest: manifest(entry: "app.html"), projectRoot: root, prebuildRan: false)
    }

    @Test("when a prebuild ran, the hint points at the prebuild command")
    func prebuildHint() throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try Build.checkWebBundle(
                manifest: manifest(prebuild: "npm run build"), projectRoot: root, prebuildRan: true
            )
            Issue.record("expected a missing bundle to fail even with a prebuild")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("ran but didn't produce it"))
            // The no-prebuild nudge should NOT appear when a prebuild ran.
            #expect(!message.contains("Build your web assets into it first"))
        }
    }
}
