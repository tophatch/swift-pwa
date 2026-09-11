import Foundation
@testable import SwiftPWACore
import Testing

/// Thread-safe payload collector (a bus sink can't capture a mutable local
/// under strict concurrency).
private final class URLPayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []
    var sink: @Sendable (Data) -> Void {
        { [self] d in lock.withLock { items.append(d) } }
    }
    var payloads: [Data] {
        lock.withLock { items }
    }
}

private struct DecodedOpenURL: Decodable {
    let urls: [String]
    let url: String?
}

@Suite("OpenURL (app.openURL delivery)")
struct OpenURLTests {
    private func decode(_ data: Data) throws -> DecodedOpenURL {
        try JSONDecoder().decode(DecodedOpenURL.self, from: data)
    }

    @Test("payload carries the list and the first entry, so a router can destructure { url }")
    func payloadShape() throws {
        let decoded = try decode(OpenURL.payload(urls: ["myapp://a", "myapp://b"]))
        #expect(decoded.urls == ["myapp://a", "myapp://b"])
        #expect(decoded.url == "myapp://a")
    }

    @Test("emit publishes retained, so a late subscriber (cold-launch WebView) still gets the link")
    func emitRetainsForLateSubscriber() throws {
        let bus = EventBus()
        OpenURL.emit(["myapp://launched"], on: bus)
        let box = URLPayloadBox()
        _ = bus.subscribe(OpenURL.channel, box.sink)
        #expect(box.payloads.count == 1)
        #expect(try decode(box.payloads[0]).url == "myapp://launched")
    }

    /// The reason the payload batches instead of emitting once per URL:
    /// retention keeps only the channel's latest value, so two retained emits
    /// would replay only the second to a page that subscribes after launch.
    @Test("several URLs in one OS event all survive to a late subscriber")
    func batchSurvivesRetention() throws {
        let bus = EventBus()
        OpenURL.emit(["myapp://a", "myapp://b"], on: bus)
        let box = URLPayloadBox()
        _ = bus.subscribe(OpenURL.channel, box.sink)
        #expect(try decode(box.payloads[0]).urls == ["myapp://a", "myapp://b"])
    }

    @Test("emit is a no-op for an empty URL list")
    func emitEmptyNoop() {
        let bus = EventBus()
        OpenURL.emit([], on: bus)
        let box = URLPayloadBox()
        _ = bus.subscribe(OpenURL.channel, box.sink)
        #expect(box.payloads.isEmpty)
    }

    @Test("launchURLs keeps deep links and drops argv[0], flags, and file paths")
    func launchURLsFilters() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("openurl-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("doc.png")
        try Data("x".utf8).write(to: real)

        let args = [
            "/usr/bin/myapp", // argv[0], always dropped
            "myapp://open/thing", // the deep link
            "--flag", // a flag, not a URL
            real.path, // a document — OpenFile's, not ours
            "plain-text" // no scheme at all
        ]
        #expect(OpenURL.launchURLs(args) == ["myapp://open/thing"])
    }

    /// A Windows drive letter parses as a one-character URL scheme, so the
    /// argv scan would otherwise hand `C:\Users\…\doc.png` to a deep-link
    /// router as a `c:` URL.
    @Test("a Windows drive path is not a deep link")
    func windowsDrivePathIsNotAURL() {
        #expect(OpenURL.launchURLs(["app.exe", #"C:\Users\ben\doc.png"#]).isEmpty)
    }

    /// `file:` is a document, and ``OpenFile/launchFilePaths(_:)`` claims it —
    /// both channels reading the same argument would deliver one open twice.
    @Test("a file: URL belongs to app.openFile, not app.openURL")
    func fileURLIsNotADeepLink() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("openurl-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("doc with space.png")
        try Data("x".utf8).write(to: real)
        let fileURL = real.absoluteString

        #expect(OpenURL.launchURLs(["app", fileURL]).isEmpty)
        // The `%U` field code hands local files over as URIs, so the file
        // channel has to accept this form — percent-decoded back to a path.
        #expect(OpenFile.launchFilePaths(["app", fileURL]) == [real.path])
    }
}
