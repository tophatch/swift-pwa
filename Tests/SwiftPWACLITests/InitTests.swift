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

    @Test("scaffolds a release CI workflow by default; --no-ci-workflow skips it")
    func scaffoldsReleaseWorkflow() async throws {
        let parent = tmpDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fm = FileManager.default

        let withCI = parent.appendingPathComponent("WithCI")
        try await Init.parse(["WithCI", "--path", withCI.path]).run()
        let workflow = withCI.appendingPathComponent(".github/workflows/release.yml")
        #expect(fm.fileExists(atPath: workflow.path))
        let yml = try String(contentsOf: workflow, encoding: .utf8)
        // Pins the CLI to this release and covers the three desktop jobs.
        #expect(yml.contains("swift-pwa-macos-arm64"))
        #expect(yml.contains("v\(SwiftPWAVersion.current)"))
        #expect(yml.contains("--target windows"))
        #expect(yml.contains("softprops/action-gh-release"))
        // The CLI version lives in a single workflow-level env var that the
        // three download URLs reference — not hardcoded three times.
        #expect(yml.contains("SWIFT_PWA_CLI_VERSION: \"v\(SwiftPWAVersion.current)\""))
        #expect(yml.contains("$SWIFT_PWA_CLI_VERSION/swift-pwa-macos-arm64"))
        #expect(yml.contains("$env:SWIFT_PWA_CLI_VERSION/swift-pwa-windows-x86_64.exe"))

        let noCI = parent.appendingPathComponent("NoCI")
        try await Init.parse(["NoCI", "--path", noCI.path, "--no-ci-workflow"]).run()
        #expect(!fm.fileExists(atPath: noCI.appendingPathComponent(".github/workflows/release.yml").path))
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

    @Test("generated App.swift threads web.entry into the bundled window")
    func appSwiftThreadsWebEntry() {
        let custom = Templates.mainSwift(structName: "MyApp", window: .init(title: "X"), entry: "app.html")
        #expect(custom.contains("entry: \"app.html\""))
        // Default is index.html when entry is omitted.
        let def = Templates.mainSwift(structName: "MyApp", window: .init(title: "X"))
        #expect(def.contains("entry: \"index.html\""))
    }

    @Test("generated App.swift emits window.background_color only when set")
    func appSwiftThreadsBackgroundColor() {
        let withColor = Templates.mainSwift(
            structName: "MyApp", window: .init(title: "X", backgroundColor: .single("#F4F7F5"))
        )
        #expect(withColor.contains("backgroundColor: \"#F4F7F5\""))
        // A light/dark pair resolves to its dark value for the single-colour
        // runtime WindowConfig (a dark pre-paint flash beats a blinding one).
        let pair = Templates.mainSwift(
            structName: "MyApp", window: .init(
                title: "X",
                backgroundColor: .dayNight(light: "#F4F4F2", dark: "#0C0D0E")
            )
        )
        #expect(pair.contains("backgroundColor: \"#0C0D0E\""))
        #expect(!pair.contains("#F4F4F2"))
        // Omitted when nil, so WindowConfig keeps the platform default.
        let without = Templates.mainSwift(structName: "MyApp", window: .init(title: "X"))
        #expect(!without.contains("backgroundColor:"))
    }

    @Test("generated App.swift emits rememberState only when opted in")
    func appSwiftThreadsRememberState() {
        let on = Templates.mainSwift(
            structName: "MyApp", window: .init(title: "X", rememberState: true)
        )
        #expect(on.contains("rememberState: true"))
        // Omitted when nil/false, so WindowConfig keeps rememberState off.
        let off = Templates.mainSwift(
            structName: "MyApp", window: .init(title: "X", rememberState: false)
        )
        #expect(!off.contains("rememberState:"))
        let unset = Templates.mainSwift(structName: "MyApp", window: .init(title: "X"))
        #expect(!unset.contains("rememberState:"))
    }

    @Test("a freshly scaffolded manifest turns window state memory on")
    func freshManifestRemembersState() {
        let m = Init.freshManifest(identifier: "MyApp", displayName: "My App", id: "com.example.myapp")
        #expect(m.window.rememberState == true)
    }

    @Test("pwa.json window.remember_state decodes (snake_case)")
    func manifestDecodesRememberState() throws {
        let json = ##"{"id":"com.example.b","name":"B","version":"1.0.0","web":{"directory":"web","entry":"index.html"},"window":{"title":"B","width":1024,"height":768,"resizable":true,"fullscreen":false,"remember_state":true}}"##
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        #expect(m.window.rememberState == true)
    }

    @Test("pwa.json window.background_color decodes (snake_case)")
    func manifestDecodesBackgroundColor() throws {
        let json = ##"{"id":"com.example.b","name":"B","version":"1.0.0","web":{"directory":"web","entry":"index.html"},"window":{"title":"B","width":1024,"height":768,"resizable":true,"fullscreen":false,"background_color":"#101418"}}"##
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        #expect(m.window.backgroundColor == .single("#101418"))
    }

    @Test("init bakes the manifest web.entry into the generated App.swift")
    func initBakesWebEntry() async throws {
        let parent = tmpDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("EntryApp")
        // Pre-seed a pwa.json with a custom web.entry, then adopt in place.
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try #"{"id":"com.example.e","name":"EntryApp","version":"1.0.0","web":{"directory":"web","entry":"main.html"},"window":{"title":"EntryApp","width":1024,"height":768,"resizable":true,"fullscreen":false}}"#
            .write(to: target.appendingPathComponent("pwa.json"), atomically: true, encoding: .utf8)
        try await Init.parse(["EntryApp", "--path", target.path, "--in-place"]).run()
        let appSwift = try String(
            contentsOf: target.appendingPathComponent("Sources/EntryApp/App.swift"), encoding: .utf8
        )
        #expect(appSwift.contains("entry: \"main.html\""))
    }

    @Test("resolveRoot: --in-place scaffolds into the cwd even with no pwa.json/web present")
    func resolveRootInPlaceForcesCwd() {
        let cwd = URL(fileURLWithPath: "/repo")
        let none: (URL) -> Bool = { _ in false } // a bare repo: no pwa.json, no web/

        // The bug: without the flag, a bare repo nests under <name>/.
        #expect(
            Init.resolveRoot(name: "myapp", cwd: cwd, path: nil, inPlace: false, fileExists: none)
                == cwd.appendingPathComponent("myapp")
        )
        // The fix: --in-place forces the cwd, no nesting.
        #expect(
            Init.resolveRoot(name: "myapp", cwd: cwd, path: nil, inPlace: true, fileExists: none)
                == cwd
        )
    }

    @Test("resolveRoot: auto-detects an existing pwa.json or web/ → cwd; --path always wins")
    func resolveRootAutoDetectAndPath() {
        let cwd = URL(fileURLWithPath: "/repo")
        let hasPwaJson: (URL) -> Bool = { $0.lastPathComponent == "pwa.json" }
        let hasWeb: (URL) -> Bool = { $0.lastPathComponent == "web" }
        let none: (URL) -> Bool = { _ in false }

        // An existing frontend adopts in place without the flag.
        #expect(Init.resolveRoot(name: "x", cwd: cwd, path: nil, inPlace: false, fileExists: hasPwaJson) == cwd)
        #expect(Init.resolveRoot(name: "x", cwd: cwd, path: nil, inPlace: false, fileExists: hasWeb) == cwd)
        // Explicit --path is used verbatim and beats --in-place.
        #expect(
            Init.resolveRoot(name: "x", cwd: cwd, path: "/somewhere/else", inPlace: true, fileExists: none)
                == URL(fileURLWithPath: "/somewhere/else")
        )
    }

    @Test("App.swift template defers web-bundle resolution to the runtime")
    func webBundleResolvesViaResourceURL() async throws {
        let parent = tmpDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let target = parent.appendingPathComponent("MyApp")
        let cmd = try Init.parse(["MyApp", "--path", target.path])
        try await cmd.run()

        let appSwift = try String(contentsOf: target.appendingPathComponent("Sources/MyApp/App.swift"), encoding: .utf8)
        // Resolution belongs to the runtime, not to generated code frozen at
        // scaffold time — that's what let `swift-pwa drive` fail on every
        // scaffolded app while both in-tree examples worked.
        #expect(appSwift.contains("WindowContent.bundledWeb"))
        #expect(!appSwift.contains("Bundle.main.resourceURL"))
        // And it throws rather than trapping: a fatalError in generated code
        // can't be caught, logged, or recovered from by the app.
        #expect(!appSwift.contains("fatalError(\"swift-pwa: web bundle not found"))
    }

    @Test("stamps the generated App.swift with the CLI version so doctor can flag drift")
    func appSwiftCarriesVersionStamp() async throws {
        let parent = tmpDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let target = parent.appendingPathComponent("MyApp")
        try await Init.parse(["MyApp", "--path", target.path]).run()

        let appSwift = try String(contentsOf: target.appendingPathComponent("Sources/MyApp/App.swift"), encoding: .utf8)
        #expect(appSwift.contains("// swift-pwa-generated: v\(SwiftPWAVersion.current)"))
        #expect(Doctor.stampedVersion(in: appSwift) == SwiftPWAVersion.current)
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
