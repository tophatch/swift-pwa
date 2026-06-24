import Foundation
@testable import SwiftPWAArchive
import SwiftPWACore
import Testing
import ZIPFoundation

@Suite("ZIPExtractor")
struct ZIPExtractorTests {
    private func tmp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-zip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a zip from a freshly-staged tree of `files` (relative path → contents).
    private func makeZip(_ files: [String: String]) throws -> (zip: URL, workdir: URL) {
        let work = tmp()
        let src = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let f = src.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: f.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: f, atomically: true, encoding: .utf8)
        }
        let zip = work.appendingPathComponent("pack.zip")
        try FileManager.default.zipItem(at: src, to: zip, shouldKeepParent: false)
        return (zip, work)
    }

    @Test("round-trips files out of a zip onto disk")
    func roundTrip() throws {
        let (zip, work) = try makeZip(["manifest.json": "{}", "media/clip.txt": "hello"])
        defer { try? FileManager.default.removeItem(at: work) }
        let dest = tmp()
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try ZIPExtractor().extract(zipAt: zip, to: dest, limits: .default)
        #expect(result.entries > 0)
        let clip = dest.appendingPathComponent("media/clip.txt")
        #expect(FileManager.default.fileExists(atPath: clip.path))
        #expect((try? String(contentsOf: clip, encoding: .utf8)) == "hello")
    }

    @Test("list reports entries without extracting")
    func list() throws {
        let (zip, work) = try makeZip(["a.txt": "a", "b.txt": "b"])
        defer { try? FileManager.default.removeItem(at: work) }
        let entries = try ZIPExtractor().list(zipAt: zip)
        let names = Set(entries.map(\.path))
        #expect(names.contains("a.txt"))
        #expect(names.contains("b.txt"))
    }

    @Test("maxEntries trips the zip-bomb guard")
    func maxEntriesGuard() throws {
        let (zip, work) = try makeZip(["a.txt": "a", "b.txt": "b", "c.txt": "c"])
        defer { try? FileManager.default.removeItem(at: work) }
        let dest = tmp()
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(throws: ArchiveError.self) {
            try ZIPExtractor().extract(zipAt: zip, to: dest, limits: ExtractLimits(maxEntries: 1))
        }
    }

    @Test("maxUncompressedBytes trips the zip-bomb guard")
    func maxBytesGuard() throws {
        let (zip, work) = try makeZip(["big.txt": String(repeating: "x", count: 10000)])
        defer { try? FileManager.default.removeItem(at: work) }
        let dest = tmp()
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(throws: ArchiveError.self) {
            try ZIPExtractor().extract(zipAt: zip, to: dest, limits: ExtractLimits(maxUncompressedBytes: 100))
        }
    }

    @Test("a non-existent archive throws notReadable")
    func notReadable() {
        let dest = tmp()
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(throws: ArchiveError.self) {
            try ZIPExtractor().extract(
                zipAt: URL(fileURLWithPath: "/nonexistent/nope.zip"), to: dest, limits: .default
            )
        }
    }
}
