// Exercises `fs.createZip` / `fs.createZipProgress` end-to-end through
// `SystemFs(extractor: ZIPExtractor())` and a `CommandRegistry`. Mirrors
// FsExtractZipTests. ZIPFoundation doesn't build on Windows, hence the gate.
#if canImport(ZIPFoundation)

    import _SwiftPWATestSupport
    import Foundation
    import SwiftPWAArchive
    @testable import SwiftPWACore
    import Testing
    import ZIPFoundation

    @Suite("fs.createZip (FsPlugin + SystemFs + ZIPExtractor)")
    @MainActor
    struct FsCreateZipTests {
        private func tmp() -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-fscreate-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        private func stage(_ files: [String: String]) throws -> (src: URL, work: URL) {
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
            return (src, work)
        }

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

        @Test("fs.createZip writes a zip and returns a summary")
        func create() async throws {
            let (src, work) = try stage(["manifest.json": "{}", "media/clip.txt": "hello"])
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("out.zip")

            let reg = registry(extractor: true)
            let args = try JSONEncoder().encode(FsCreateZipArgs(from: src.path, to: zip.path))
            let result = await dispatch(reg, "fs.createZip", args)
            guard case let .ok(data) = result else { Issue.record("expected ok, got \(result)"); return }
            let summary = try JSONDecoder().decode(CreateResult.self, from: data)
            #expect(summary.entries > 0)
            #expect(FileManager.default.fileExists(atPath: zip.path))
        }

        @Test("the create commands are unregistered without an extractor")
        func notRegisteredWithoutExtractor() {
            let reg = registry(extractor: false)
            #expect(!reg.has("fs.createZip"))
            #expect(!reg.has("fs.createZipProgress"))
        }

        @Test("the create commands are registered when an extractor is injected")
        func registeredWithExtractor() {
            let reg = registry(extractor: true)
            #expect(reg.has("fs.createZip"))
            #expect(reg.has("fs.createZipProgress"))
        }

        @Test("fs.createZipProgress streams progress then a done event")
        func progressStream() async throws {
            let (src, work) = try stage(["a.txt": "a", "b.txt": "bb", "c/d.txt": "ddd"])
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("out.zip")

            let reg = registry(extractor: true)
            let args = try JSONEncoder().encode(FsCreateZipArgs(from: src.path, to: zip.path, compression: "deflate"))
            let result = await dispatch(reg, "fs.createZipProgress", args)
            guard case let .stream(stream) = result else { Issue.record("expected stream"); return }

            var events: [FsCreateEvent] = []
            for try await frame in stream {
                try events.append(JSONDecoder().decode(FsCreateEvent.self, from: frame))
            }
            #expect(events.contains { $0.type == "progress" })
            #expect(events.last?.type == "done")
            #expect((events.last?.entries ?? 0) > 0)
            let counts = events.filter { $0.type == "progress" }.compactMap(\.entriesDone)
            #expect(counts == counts.sorted())
        }

        @Test("a created pack re-imports through fs.extractZip (full round-trip over the bridge)")
        func roundTripOverBridge() async throws {
            let files = ["pack.json": "{\"v\":1}", "img/a.txt": "aaa"]
            let (src, work) = try stage(files)
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("out.zip")
            let dest = tmp(); defer { try? FileManager.default.removeItem(at: dest) }

            let reg = registry(extractor: true)
            let createArgs = try JSONEncoder().encode(FsCreateZipArgs(from: src.path, to: zip.path))
            _ = await dispatch(reg, "fs.createZip", createArgs)
            let extractArgs = try JSONEncoder().encode(FsExtractZipArgs(from: zip.path, to: dest.path))
            _ = await dispatch(reg, "fs.extractZip", extractArgs)

            for (rel, contents) in files {
                let out = dest.appendingPathComponent(rel)
                #expect((try? String(contentsOf: out, encoding: .utf8)) == contents)
            }
        }

        @Test("fs.createZip surfaces a bad source as a handler error naming the op")
        func badSource() async throws {
            let work = tmp(); defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("out.zip")
            let reg = registry(extractor: true)
            let args = try JSONEncoder().encode(
                FsCreateZipArgs(from: work.appendingPathComponent("nope").path, to: zip.path)
            )
            let result = await dispatch(reg, "fs.createZip", args)
            guard case let .failure(err) = result else { Issue.record("expected failure"); return }
            #expect(err.message.contains("fs.createZip"))
        }
    }

#endif
