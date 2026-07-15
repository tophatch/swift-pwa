import ArgumentParser
import Foundation
@testable import SwiftPWACLISupport
import SwiftPWACore
import Testing

@Suite("swift-pwa codegen command")
struct CodegenCommandTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codegen-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeCatalog(_ descriptors: [CommandDescriptor], to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(descriptors).write(to: url)
        return url
    }

    private let sample = [
        CommandDescriptor(
            name: "window.setTitle", kind: .unary,
            args: .object(name: "SetTitleArgs", fields: [.init(name: "title", schema: .string)]),
            result: .void
        )
    ]

    @Test("generates bridge.ts from a catalog file")
    func generates() async throws {
        let dir = try tempDir()
        let catalog = try writeCatalog(sample, to: dir)
        let out = dir.appendingPathComponent("bridge.ts")

        var cmd = try Codegen.parse(["--catalog", catalog.path, "-o", out.path])
        try await cmd.run()

        let ts = try String(contentsOf: out, encoding: .utf8)
        #expect(ts.contains("setTitle: (args: SetTitleArgs): Promise<void> => raw.invoke(\"window.setTitle\", args)"))
        #expect(ts.contains("export function createBridge(raw: RawBridge)"))
    }

    @Test("--check passes when the output is current, throws when stale")
    func checkDriftGuard() async throws {
        let dir = try tempDir()
        let catalog = try writeCatalog(sample, to: dir)
        let out = dir.appendingPathComponent("bridge.ts")

        // Generate, then --check should pass.
        try await Codegen.parse(["--catalog", catalog.path, "-o", out.path]).run()
        try await Codegen.parse(["--catalog", catalog.path, "-o", out.path, "--check"]).run()

        // Mutate the file → --check must throw.
        try (String(contentsOf: out, encoding: .utf8) + "// drift").write(to: out, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) {
            try await Codegen.parse(["--catalog", catalog.path, "-o", out.path, "--check"]).run()
        }
    }

    @Test("a malformed catalog is a clean validation error, not a crash")
    func malformedCatalog() async throws {
        let dir = try tempDir()
        let bad = dir.appendingPathComponent("catalog.json")
        try "not json".write(to: bad, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            try await Codegen.parse(["--catalog", bad.path, "-o", dir.appendingPathComponent("b.ts").path]).run()
        }
    }
}
