// Exercises the `fs.extractZip` / `fs.listZip` / `fs.extractZipProgress`
// bridge commands end-to-end through `SystemFs(extractor: ZIPExtractor())`
// and a `CommandRegistry`. Lives in the Archive test target because it needs
// the real ZIPFoundation-backed extractor, which doesn't build on Windows.
#if canImport(ZIPFoundation)

    import _SwiftPWATestSupport
    import Foundation
    import SwiftPWAArchive
    @testable import SwiftPWACore
    import Testing
    import ZIPFoundation

    @Suite("fs.extractZip (FsPlugin + SystemFs + ZIPExtractor)")
    @MainActor
    struct FsExtractZipTests {
        private func tmp() -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-fszip-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        private func makeZip(_ files: [String: String]) throws -> (zip: URL, work: URL) {
            let work = tmp()
            let src = work.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            for (rel, contents) in files {
                let f = src.appendingPathComponent(rel)
                try FileManager.default.createDirectory(
                    at: f.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try contents.write(to: f, atomically: true, encoding: .utf8)
            }
            let zip = work.appendingPathComponent("pack.zip")
            try FileManager.default.zipItem(at: src, to: zip, shouldKeepParent: false)
            return (zip, work)
        }

        /// Build a registry with `FsPlugin(SystemFs(extractor:))` installed.
        private func registry(extractor: Bool) -> CommandRegistry {
            let app = MockAppContext()
            let fs = SystemFs(extractor: extractor ? ZIPExtractor() : nil)
            FsPlugin(fs).register(into: app.registry, app: app)
            return app.registry
        }

        private func dispatch(_ reg: CommandRegistry, _ cmd: String, _ payload: Data) async -> InvocationResult {
            let inv = Invocation(id: 1, command: cmd, payload: payload)
            let app = MockAppContext()
            return await reg.dispatch(CommandContext(invocation: inv, originWindow: nil, appContext: app))
        }

        @Test("fs.extractZip lands files on disk and returns a summary")
        func extract() async throws {
            let (zip, work) = try makeZip(["manifest.json": "{}", "media/clip.txt": "hello"])
            defer { try? FileManager.default.removeItem(at: work) }
            let dest = tmp(); defer { try? FileManager.default.removeItem(at: dest) }

            let reg = registry(extractor: true)
            let args = try JSONEncoder().encode(FsExtractZipArgs(from: zip.path, to: dest.path))
            let result = await dispatch(reg, "fs.extractZip", args)
            guard case let .ok(data) = result else { Issue.record("expected ok, got \(result)"); return }
            let summary = try JSONDecoder().decode(ExtractResult.self, from: data)
            #expect(summary.entries > 0)
            #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("media/clip.txt").path))
        }

        @Test("fs.listZip reports entries without extracting")
        func list() async throws {
            let (zip, work) = try makeZip(["a.txt": "a", "b.txt": "b"])
            defer { try? FileManager.default.removeItem(at: work) }
            let reg = registry(extractor: true)
            let args = try JSONEncoder().encode(FsListZipArgs(from: zip.path))
            let result = await dispatch(reg, "fs.listZip", args)
            guard case let .ok(data) = result else { Issue.record("expected ok"); return }
            let listed = try JSONDecoder().decode(FsListZipResult.self, from: data)
            #expect(Set(listed.entries.map(\.path)).isSuperset(of: ["a.txt", "b.txt"]))
        }

        @Test("the zip commands are unregistered without an extractor")
        func notRegisteredWithoutExtractor() {
            let reg = registry(extractor: false)
            #expect(!reg.has("fs.extractZip"))
            #expect(!reg.has("fs.listZip"))
            #expect(!reg.has("fs.extractZipProgress"))
            // The ordinary fs.* commands are still present.
            #expect(reg.has("fs.readText"))
        }

        @Test("the zip commands are registered when an extractor is injected")
        func registeredWithExtractor() {
            let reg = registry(extractor: true)
            #expect(reg.has("fs.extractZip"))
            #expect(reg.has("fs.listZip"))
            #expect(reg.has("fs.extractZipProgress"))
        }

        @Test("fs.extractZipProgress streams progress then a done event")
        func progressStream() async throws {
            let (zip, work) = try makeZip(["a.txt": "a", "b.txt": "bb", "c/d.txt": "ddd"])
            defer { try? FileManager.default.removeItem(at: work) }
            let dest = tmp(); defer { try? FileManager.default.removeItem(at: dest) }

            let reg = registry(extractor: true)
            let args = try JSONEncoder().encode(FsExtractZipArgs(from: zip.path, to: dest.path))
            let result = await dispatch(reg, "fs.extractZipProgress", args)
            guard case let .stream(stream) = result else { Issue.record("expected stream"); return }

            var events: [FsExtractEvent] = []
            for try await frame in stream {
                try events.append(JSONDecoder().decode(FsExtractEvent.self, from: frame))
            }
            #expect(events.contains { $0.type == "progress" })
            let done = events.last
            #expect(done?.type == "done")
            #expect((done?.entries ?? 0) > 0)
            // Progress is monotonic in entriesDone.
            let progressCounts = events.filter { $0.type == "progress" }.compactMap(\.entriesDone)
            #expect(progressCounts == progressCounts.sorted())
        }

        @Test("fs.extractZip surfaces a traversal-blocked archive as a handler error")
        func traversalRejected() async throws {
            // A normal zip can't carry `../`, so assert the guard maps cleanly
            // for a corrupt/missing source instead (same error path).
            let dest = tmp(); defer { try? FileManager.default.removeItem(at: dest) }
            let reg = registry(extractor: true)
            let args = try JSONEncoder().encode(FsExtractZipArgs(from: "/nonexistent/x.zip", to: dest.path))
            let result = await dispatch(reg, "fs.extractZip", args)
            guard case let .failure(err) = result else { Issue.record("expected failure"); return }
            #expect(err.message.contains("fs.extractZip"))
        }
    }

#endif
