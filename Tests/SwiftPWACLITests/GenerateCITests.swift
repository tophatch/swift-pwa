import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("swift-pwa generate-ci")
struct GenerateCITests {
    private func tmpDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-genci-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("writes a parseable release workflow into .github/workflows/")
    func writesWorkflow() async throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try await GenerateCI.parse(["--path", root.path]).run()

        let workflow = root.appendingPathComponent(".github/workflows/release.yml")
        #expect(FileManager.default.fileExists(atPath: workflow.path))
        let yml = try String(contentsOf: workflow, encoding: .utf8)
        #expect(yml.contains("on:"))
        #expect(yml.contains("tags:"))
        #expect(yml.contains("swift-pwa-linux-x86_64"))
    }

    @Test("refuses to overwrite an existing workflow unless --force")
    func refusesWithoutForce() async throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = root.appendingPathComponent(".github/workflows/release.yml")
        try FileManager.default.createDirectory(
            at: workflow.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "# mine".write(to: workflow, atomically: true, encoding: .utf8)

        do {
            try await GenerateCI.parse(["--path", root.path]).run()
            Issue.record("expected generate-ci to refuse overwriting an existing workflow")
        } catch {
            #expect(String(describing: error).contains("--force"))
        }
        // Untouched without --force.
        #expect(try String(contentsOf: workflow, encoding: .utf8) == "# mine")

        // --force overwrites.
        try await GenerateCI.parse(["--path", root.path, "--force"]).run()
        #expect(try String(contentsOf: workflow, encoding: .utf8).contains("name: Release"))
    }
}
