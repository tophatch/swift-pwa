import Foundation
@testable import SwiftPWACore
import Testing

/// Thread-safe payload collector (a bus sink can't capture a mutable local
/// under strict concurrency).
private final class PayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []
    var sink: @Sendable (Data) -> Void {
        { [self] d in lock.withLock { items.append(d) } }
    }
    var payloads: [Data] {
        lock.withLock { items }
    }
}

@Suite("OpenFile (app.openFile delivery)")
struct OpenFileTests {
    private struct Decoded: Decodable {
        let paths: [String]
        let names: [String]
        let mimeTypes: [String?]
    }

    private func decode(_ data: Data) throws -> Decoded {
        try JSONDecoder().decode(Decoded.self, from: data)
    }

    private func decodePaths(_ data: Data) throws -> [String] {
        try decode(data).paths
    }

    @Test("a desktop open names each file by its last component and declares no type")
    func payloadShape() throws {
        let decoded = try decode(OpenFile.payload(paths: ["/a/b.png", "/c/My Notes.md"]))
        #expect(decoded.paths == ["/a/b.png", "/c/My Notes.md"])
        #expect(decoded.names == ["b.png", "My Notes.md"])
        #expect(decoded.mimeTypes == [nil, nil])
    }

    @Test("names and types a platform supplies are kept, nulls in their slots")
    func payloadSuppliedMetadata() throws {
        let data = OpenFile.payload(
            paths: ["content://media/external/file/189", "content://p/2"],
            names: ["Chapter_0001.pdf", "notes.md"],
            mimeTypes: ["application/pdf", nil]
        )
        #expect(String(decoding: data, as: UTF8.self).contains(",null]"))
        let decoded = try decode(data)
        #expect(decoded.names == ["Chapter_0001.pdf", "notes.md"])
        #expect(decoded.mimeTypes == ["application/pdf", nil])
    }

    @Test("metadata that doesn't line up with the paths is replaced, not misaligned")
    func payloadMisalignedMetadata() throws {
        let decoded = try decode(OpenFile.payload(
            paths: ["/x/one.pdf", "/x/two.pdf"], names: ["only-one"], mimeTypes: ["application/pdf"]
        ))
        #expect(decoded.names == ["one.pdf", "two.pdf"])
        #expect(decoded.mimeTypes == [nil, nil])
    }

    @Test("a file: URL is named by its decoded last component")
    func displayNameOfFileURL() {
        #expect(OpenFile.displayName(of: "file:///home/me/My%20Book.epub") == "My Book.epub")
    }

    @Test("launchFilePaths keeps existing files, drops argv[0], flags, and non-files")
    func launchFilePathsFilters() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("open-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("doc.png")
        try Data("x".utf8).write(to: real)

        let args = ["/usr/bin/myapp", real.path, "--flag", dir.appendingPathComponent("missing.png").path]
        // argv[0] is dropped, the flag and the non-existent path are dropped,
        // only the real file survives.
        #expect(OpenFile.launchFilePaths(args) == [real.path])
    }

    @Test("emit publishes retained, so a late subscriber (cold-launch WebView) still gets the file")
    func emitRetainsForLateSubscriber() throws {
        let bus = EventBus()
        OpenFile.emit(["/tmp/launched.png"], on: bus)
        // Subscribe *after* the emit — the retained payload replays immediately.
        let box = PayloadBox()
        _ = bus.subscribe(OpenFile.channel, box.sink)
        #expect(box.payloads.count == 1)
        #expect(try decodePaths(box.payloads[0]) == ["/tmp/launched.png"])
    }

    @Test("emit is a no-op for an empty path list")
    func emitEmptyNoop() {
        let bus = EventBus()
        OpenFile.emit([], on: bus)
        let box = PayloadBox()
        _ = bus.subscribe(OpenFile.channel, box.sink)
        #expect(box.payloads.isEmpty)
    }
}
