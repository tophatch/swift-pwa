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

    /// The emitted workflow is a *second copy* of our own release pipeline, and
    /// it drifted: v0.9.8 raised the Linux floor to 6.2 in `.swift-version`, our
    /// `ci.yml`/`release.yml` and the setup docs — but not here, so a project
    /// scaffolded by 0.9.8 shipped a workflow pinned to the one toolchain the
    /// release notes said renders nothing, and it would only fail in the cloud
    /// on a tag push. An adopter found it. Worse, the same file still pinned
    /// Windows to 6.1.2, whose Foundation silently truncates file writes.
    ///
    /// Both pins are toolchain *floors chosen because lower ones are broken*, so
    /// this asserts the template can't quietly fall behind the pins we ship.
    @Test("the emitted workflow's Swift pins track our own, and avoid known-bad toolchains")
    func emittedPinsTrackOurs() async throws {
        let root = try tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try await GenerateCI.parse(["--path", root.path]).run()
        let emitted = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8
        )

        // …/Tests/SwiftPWACLITests/<this>.swift → repo root.
        let ours = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        func pins(_ yaml: String) -> Set<String> {
            Set(
                yaml.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("swift-version:") }
                    .map { $0.dropFirst("swift-version:".count).trimmingCharacters(in: .whitespaces) }
            )
        }

        let emittedPins = pins(emitted)
        #expect(!emittedPins.isEmpty, "the emitted workflow pins no Swift version at all")

        // Every pin it hands an adopter must be one we actually ship with.
        let unknown = emittedPins.subtracting(pins(ours))
        #expect(
            unknown.isEmpty,
            """
            the generated workflow pins \(unknown.sorted().joined(separator: ", ")), which our own \
            release.yml doesn't use. Update Init.swift's template alongside .github/workflows — an \
            adopter's scaffolded pipeline is the copy nobody notices going stale.
            """
        )

        // Named explicitly, because a comment alone didn't stop it last time.
        for bad in ["\"6.0\"", "\"6.1\"", "swift-6.1.2-release"] {
            #expect(
                !emittedPins.contains(bad),
                "\(bad) is a known-broken toolchain (GTK4 renders nothing / Windows truncates writes)"
            )
        }
    }
}
