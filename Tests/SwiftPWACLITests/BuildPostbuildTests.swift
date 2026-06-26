import ArgumentParser
import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("build.postbuild")
struct BuildPostbuildTests {
    private func tmpDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-postbuild-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifest(postbuild: String?) -> PWAManifest {
        PWAManifest(
            id: "com.example.app", name: "App", version: "1.0.0",
            web: .init(directory: "web"), window: .init(title: "App"),
            build: postbuild.map { PWAManifest.BuildSection(postbuild: $0) }
        )
    }

    @Test("postbuild runs after bundling with SWIFT_PWA_ARTIFACT / SWIFT_PWA_TARGET set")
    func runsPostbuild() async throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("App.app")
        try await Build.runPostbuild(
            manifest: manifest(postbuild: "echo \"$SWIFT_PWA_TARGET $SWIFT_PWA_ARTIFACT\" > out.txt"),
            projectRoot: root, target: .macos, artifact: artifact, skip: false
        )
        let out = try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out == "macos \(artifact.path)")
    }

    @Test("a non-zero postbuild fails the build")
    func nonZeroFails() async throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await Build.runPostbuild(
                manifest: manifest(postbuild: "exit 4"),
                projectRoot: root, target: .macos, artifact: root, skip: false
            )
        }
    }

    @Test("--skip-postbuild bypasses the command")
    func skipBypasses() async throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Build.runPostbuild(
            manifest: manifest(postbuild: "echo hi > marker.txt"),
            projectRoot: root, target: .macos, artifact: root, skip: true
        )
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker.txt").path))
    }

    @Test("no postbuild is a no-op")
    func noSectionNoOp() async throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Build.runPostbuild(
            manifest: manifest(postbuild: nil), projectRoot: root, target: .macos, artifact: root, skip: false
        )
    }

    @Test("build.postbuild round-trips through pwa.json")
    func manifestRoundTrip() throws {
        let m = manifest(postbuild: "./sign.sh \"$SWIFT_PWA_ARTIFACT\"")
        let url = tmpDir().appendingPathComponent("pwa.json")
        try m.write(to: url)
        let reloaded = try PWAManifest.load(from: url)
        #expect(reloaded.build?.postbuild == "./sign.sh \"$SWIFT_PWA_ARTIFACT\"")
    }
}
