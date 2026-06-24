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

        // `name` is the human-facing display string (preserved verbatim).
        // `init` does NOT write `executable_name` — the SwiftPM target is
        // `testApp` (asserted via Package.swift above) and the bundler
        // discovers that from the package, so the manifest stays clean.
        let manifest = try PWAManifest.load(from: target.appendingPathComponent("pwa.json"))
        #expect(manifest.name == "test-app")
        #expect(manifest.executableName == nil)
        #expect(manifest.window.title == "test-app")
    }

    @Test("an identifier-safe name leaves executable_name unset")
    func identifierSafeNameOmitsExecutableName() async throws {
        let parent = tmpDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let target = parent.appendingPathComponent("MyApp")
        try await Init.parse(["MyApp", "--path", target.path]).run()

        let manifest = try PWAManifest.load(from: target.appendingPathComponent("pwa.json"))
        // "MyApp" is already a valid identifier, so there's no redundant
        // executable_name — binaryName falls back to name.
        #expect(manifest.name == "MyApp")
        #expect(manifest.executableName == nil)
        #expect(manifest.binaryName == "MyApp")
    }

    @Test("--in-place adopts an existing web app: merges pwa.json, keeps web/, adds only the shell")
    func inPlaceAdoptsExistingApp() async throws {
        let target = tmpDir()
        defer { try? FileManager.default.removeItem(at: target) }
        let fm = FileManager.default
        try fm.createDirectory(at: target.appendingPathComponent("web"), withIntermediateDirectories: true)
        try "<!doctype html><h1>existing</h1>".write(
            to: target.appendingPathComponent("web/index.html"), atomically: true, encoding: .utf8
        )
        // Hand-written manifest with a custom window + a non-schema field.
        try """
        {
          "id": "com.acme.game",
          "name": "My Cool Game",
          "version": "2.1.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "My Cool Game", "width": 800, "height": 600, "resizable": false, "fullscreen": false },
          "customTeamField": "keep-me"
        }
        """.write(to: target.appendingPathComponent("pwa.json"), atomically: true, encoding: .utf8)

        try await Init.parse(["My Cool Game", "--path", target.path, "--in-place"]).run()

        // Native shell added.
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Package.swift").path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Sources/MyCoolGame/App.swift").path))

        // Existing frontend untouched.
        let web = try String(contentsOf: target.appendingPathComponent("web/index.html"), encoding: .utf8)
        #expect(web == "<!doctype html><h1>existing</h1>")

        // pwa.json merged, not overwritten: user values preserved, the
        // non-schema field survives, missing sections filled, and
        // missing sections filled, user values kept, no executable_name
        // pin (the bundler discovers the SwiftPM target from the package).
        let merged = try PWAManifest.load(from: target.appendingPathComponent("pwa.json"))
        #expect(merged.id == "com.acme.game")
        #expect(merged.name == "My Cool Game")
        #expect(merged.version == "2.1.0")
        #expect(merged.window.width == 800)
        #expect(merged.window.resizable == false)
        #expect(merged.executableName == nil)
        #expect(merged.android != nil) // section added by the merge
        let rawMerged = try String(contentsOf: target.appendingPathComponent("pwa.json"), encoding: .utf8)
        #expect(rawMerged.contains("customTeamField"))

        // App.swift reflects the *existing* window block (800×600, not the
        // 1024×768 default), proving the merge feeds the template.
        let appSwift = try String(
            contentsOf: target.appendingPathComponent("Sources/MyCoolGame/App.swift"), encoding: .utf8
        )
        #expect(appSwift.contains("Size(width: 800, height: 600)"))
        #expect(appSwift.contains("resizable: false"))
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

    @Test("auto-adopts in place when a pwa.json already exists (no flag needed)")
    func autoAdoptsOnExistingManifest() async throws {
        let target = tmpDir()
        defer { try? FileManager.default.removeItem(at: target) }
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try """
        { "id": "com.acme.app", "name": "Acme App", "version": "3.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Acme App", "width": 640, "height": 480, "resizable": true, "fullscreen": false } }
        """.write(to: target.appendingPathComponent("pwa.json"), atomically: true, encoding: .utf8)

        // No --in-place flag: the existing pwa.json should trigger adoption.
        try await Init.parse(["AcmeApp", "--path", target.path]).run()

        #expect(fm.fileExists(atPath: target.appendingPathComponent("Package.swift").path))
        // Existing manifest merged, not clobbered: user values kept, and
        // no executable_name written (resolved from the package instead).
        let merged = try PWAManifest.load(from: target.appendingPathComponent("pwa.json"))
        #expect(merged.id == "com.acme.app")
        #expect(merged.version == "3.0.0")
        #expect(merged.window.width == 640)
        #expect(merged.executableName == nil)
    }

    @Test("auto-adopts in place when only a web/ directory exists")
    func autoAdoptsOnExistingWebDir() async throws {
        let target = tmpDir()
        defer { try? FileManager.default.removeItem(at: target) }
        let fm = FileManager.default
        try fm.createDirectory(at: target.appendingPathComponent("web"), withIntermediateDirectories: true)
        try "<!doctype html><h1>mine</h1>".write(
            to: target.appendingPathComponent("web/index.html"), atomically: true, encoding: .utf8
        )

        try await Init.parse(["MyApp", "--path", target.path]).run()

        // Native shell added, a fresh pwa.json written, the frontend left alone.
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Package.swift").path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("pwa.json").path))
        let web = try String(contentsOf: target.appendingPathComponent("web/index.html"), encoding: .utf8)
        #expect(web == "<!doctype html><h1>mine</h1>")
    }

    @Test("refuses to clobber an already-adopted project (native shell present)")
    func refusesWhenAlreadyAdopted() async throws {
        let target = tmpDir()
        defer { try? FileManager.default.removeItem(at: target) }
        let fm = FileManager.default
        try fm.createDirectory(
            at: target.appendingPathComponent("Sources/MyApp"), withIntermediateDirectories: true
        )
        // A pre-existing native shell (App.swift) marks an adopted project;
        // re-running init must refuse rather than overwrite it.
        try "// existing".write(
            to: target.appendingPathComponent("Sources/MyApp/App.swift"), atomically: true, encoding: .utf8
        )

        let cmd = try Init.parse(["MyApp", "--path", target.path])
        do {
            try await cmd.run()
            Issue.record("expected init to refuse overwriting an existing App.swift")
        } catch {
            #expect(String(describing: error).contains("App.swift"))
        }
        // Pre-existing native shell untouched.
        let original = try String(
            contentsOf: target.appendingPathComponent("Sources/MyApp/App.swift"), encoding: .utf8
        )
        #expect(original == "// existing")
    }
}
