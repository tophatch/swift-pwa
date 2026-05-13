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

    @Test("normalises hyphenated names so the generated Swift compiles")
    func normalisesHyphenatedName() async throws {
        let parent = tmpDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let target = parent.appendingPathComponent("test-app")
        let cmd = try Init.parse(["test-app", "--path", target.path])
        try await cmd.run()

        let fm = FileManager.default
        // The on-disk identifier must be the camelCased form so
        // Package.swift / @main struct / `.build/release/<x>` all
        // agree. The original directory the user passed via --path is
        // left as-is (that's their choice).
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Sources/testApp/App.swift").path))
        #expect(!fm.fileExists(atPath: target.appendingPathComponent("Sources/test-app").path))

        let pkg = try String(contentsOf: target.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(pkg.contains("name: \"testApp\""))
        #expect(!pkg.contains("\"test-app\""))

        let appSwift = try String(
            contentsOf: target.appendingPathComponent("Sources/testApp/App.swift"),
            encoding: .utf8
        )
        #expect(appSwift.contains("struct testAppApp"))
        // The window title preserves the user's original string.
        #expect(appSwift.contains("title: \"test-app\""))

        // pwa.json's `name` is the bundler's binary-lookup key, so it
        // tracks the identifier; the human-facing display lives in
        // window.title.
        let manifestData = try Data(contentsOf: target.appendingPathComponent("pwa.json"))
        let manifest = try JSONDecoder().decode(PWAManifest.self, from: manifestData)
        #expect(manifest.name == "testApp")
        #expect(manifest.window.title == "test-app")
    }

    @Test("sanitizeIdentifier covers the common name shapes")
    func sanitizeIdentifierShapes() throws {
        #expect(try Init.sanitizeIdentifier("MyApp") == "MyApp")
        #expect(try Init.sanitizeIdentifier("test-app") == "testApp")
        #expect(try Init.sanitizeIdentifier("my cool app") == "myCoolApp")
        #expect(try Init.sanitizeIdentifier("hello_world") == "helloWorld")
        #expect(try Init.sanitizeIdentifier("3d-viewer") == "_3dViewer")
        #expect(throws: (any Error).self) { try Init.sanitizeIdentifier("---") }
    }

    @Test("App.swift template resolves the web bundle via resourceURL")
    func webBundleResolvesViaResourceURL() async throws {
        let parent = tmpDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let target = parent.appendingPathComponent("MyApp")
        let cmd = try Init.parse(["MyApp", "--path", target.path])
        try await cmd.run()

        let appSwift = try String(contentsOf: target.appendingPathComponent("Sources/MyApp/App.swift"), encoding: .utf8)
        // `resourceURL` gives the right path on both macOS
        // (`Contents/Resources/`) and iOS (bundle root); the old
        // `bundleURL.appendingPathComponent("web")` resolved to
        // `<App>.app/web` on macOS where the bundler doesn't put it.
        #expect(appSwift.contains("Bundle.main.resourceURL"))
        #expect(!appSwift.contains("Bundle.main.bundleURL.appendingPathComponent(\"web\")"))
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
