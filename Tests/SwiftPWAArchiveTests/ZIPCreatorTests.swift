// Drives `ZIPExtractor.create` (the inverse of `extract`) directly. Like
// the extract tests, ZIPFoundation doesn't build on Windows, so compile
// these only where it's available.
#if canImport(ZIPFoundation)

    import Foundation
    @testable import SwiftPWAArchive
    import SwiftPWACore
    import Testing
    import ZIPFoundation

    @Suite("ZIPExtractor.create")
    struct ZIPCreatorTests {
        private func tmp() -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-zipc-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        /// Stage a source tree (relative path → contents) under a fresh dir.
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

        @Test("create then extract round-trips every file byte-for-byte", arguments: [ZipCompression.stored, .deflate])
        func roundTrip(_ compression: ZipCompression) async throws {
            let files = ["manifest.json": "{}", "media/clip.txt": "hello", "media/notes/readme.md": "# hi"]
            let (src, work) = try stage(files)
            defer { try? FileManager.default.removeItem(at: work) }

            let zip = work.appendingPathComponent("out.zip")
            let created = try await ZIPExtractor().create(zipAt: zip, from: src, compression: compression)
            #expect(FileManager.default.fileExists(atPath: zip.path))
            // Three files + the two intermediate directories (media, media/notes).
            #expect(created.entries == 5)
            #expect(created.uncompressedBytes == Int64(files.values.map(\.utf8.count).reduce(0, +)))

            // Now extract it back and compare contents.
            let dest = tmp(); defer { try? FileManager.default.removeItem(at: dest) }
            try await ZIPExtractor().extract(zipAt: zip, to: dest, limits: .default)
            for (rel, contents) in files {
                let out = dest.appendingPathComponent(rel)
                #expect(FileManager.default.fileExists(atPath: out.path))
                #expect((try? String(contentsOf: out, encoding: .utf8)) == contents)
            }
        }

        @Test("create reports progress monotonically and a matching total")
        func progress() async throws {
            let (src, work) = try stage(["a.txt": "a", "b.txt": "bb", "c/d.txt": "ddd"])
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("out.zip")

            final class Box: @unchecked Sendable { var ticks: [CreateProgress] = [] }
            let box = Box()
            let result = try await ZIPExtractor().create(
                zipAt: zip, from: src, compression: .stored,
                onProgress: { box.ticks.append($0) }
            )
            #expect(!box.ticks.isEmpty)
            #expect(box.ticks.map(\.entriesDone) == box.ticks.map(\.entriesDone).sorted())
            #expect(box.ticks.last?.entriesDone == result.entries)
            #expect(box.ticks.allSatisfy { $0.totalEntries == result.entries })
        }

        @Test("a missing or non-directory source throws notReadable")
        func sourceMustBeDirectory() async throws {
            let work = tmp(); defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("out.zip")
            await #expect(throws: ArchiveError.self) {
                try await ZIPExtractor().create(
                    zipAt: zip, from: work.appendingPathComponent("nope"), compression: .stored
                )
            }
        }

        @Test("a failed create leaves no file at the destination")
        func noPartialOnFailure() async {
            let work = tmp(); defer { try? FileManager.default.removeItem(at: work) }
            // Source doesn't exist → create throws before writing the destination.
            let zip = work.appendingPathComponent("out.zip")
            _ = try? await ZIPExtractor().create(
                zipAt: zip, from: work.appendingPathComponent("nope"), compression: .stored
            )
            #expect(!FileManager.default.fileExists(atPath: zip.path))
        }

        @Test("symlinks in the source are skipped, not stored")
        func skipsSymlinks() async throws {
            let (src, work) = try stage(["real.txt": "real"])
            defer { try? FileManager.default.removeItem(at: work) }
            // Add a symlink alongside the real file.
            let link = src.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: src.appendingPathComponent("real.txt")
            )
            let zip = work.appendingPathComponent("out.zip")
            try await ZIPExtractor().create(zipAt: zip, from: src, compression: .stored)

            let names = try await ZIPExtractor().list(zipAt: zip).map(\.path)
            #expect(names.contains("real.txt"))
            #expect(!names.contains("link.txt"))
        }
    }

#endif
