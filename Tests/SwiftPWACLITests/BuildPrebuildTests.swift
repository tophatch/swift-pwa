import ArgumentParser
import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("build.prebuild")
struct BuildPrebuildTests {
    private func tmpDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-prebuild-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifest(prebuild: String?) -> PWAManifest {
        PWAManifest(
            id: "com.example.app", name: "App", version: "1.0.0",
            web: .init(directory: "web"), window: .init(title: "App"),
            build: prebuild.map { PWAManifest.BuildSection(prebuild: $0) }
        )
    }

    @Test("prebuild runs from the project root before bundling")
    func runsPrebuild() async throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Build.runPrebuild(
            manifest: manifest(prebuild: "echo hi > marker.txt"), projectRoot: root, skip: false
        )
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker.txt").path))
    }

    @Test("a non-zero prebuild aborts the build")
    func nonZeroAborts() async throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await Build.runPrebuild(manifest: manifest(prebuild: "exit 3"), projectRoot: root, skip: false)
        }
    }

    @Test("--skip-prebuild bypasses the command")
    func skipBypasses() async throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Build.runPrebuild(
            manifest: manifest(prebuild: "echo hi > marker.txt"), projectRoot: root, skip: true
        )
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker.txt").path))
    }

    @Test("no build section is a no-op")
    func noSectionNoOp() async throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Build.runPrebuild(manifest: manifest(prebuild: nil), projectRoot: root, skip: false)
    }

    @Test("build.prebuild round-trips through pwa.json")
    func manifestRoundTrip() throws {
        let json = #"{ "id": "com.x.y", "name": "Y", "version": "1.0.0", "#
            + #""web": { "directory": "web", "entry": "index.html" }, "#
            + #""window": { "title": "Y", "width": 1024, "height": 768, "resizable": true, "fullscreen": false }, "#
            + #""build": { "prebuild": "node scripts/gen.mjs" } }"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        #expect(m.build?.prebuild == "node scripts/gen.mjs")
    }
}
