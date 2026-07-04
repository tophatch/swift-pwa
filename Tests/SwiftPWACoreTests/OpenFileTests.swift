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
    private func decodePaths(_ data: Data) throws -> [String] {
        try JSONDecoder().decode([String: [String]].self, from: data)["paths"] ?? []
    }

    @Test("payload is a { paths: [...] } object")
    func payloadShape() throws {
        let data = OpenFile.payload(paths: ["/a/b.png", "/c/d.jpg"])
        #expect(try decodePaths(data) == ["/a/b.png", "/c/d.jpg"])
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
