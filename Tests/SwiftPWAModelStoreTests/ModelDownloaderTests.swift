import Foundation
import SwiftPWACore
@testable import SwiftPWAModelStore
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// Independent SHA-256 hex (cross-checks the downloader's own hashing).
private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Thread-safe sink for the `@Sendable` progress callback.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTotal: Int64??
    func record(total: Int64?) { lock.lock(); lastTotal = total; lock.unlock() }
    var total: Int64?? {
        lock.lock(); defer { lock.unlock() }; return lastTotal
    }
}

// MARK: - Stateless mock transport

/// Serves a deterministic body derived from the URL (`mockmodel://<host>/<n>`
/// → `n` bytes, byte i = i % 251), honoring `Range` unless the host is
/// `noresume`. Stateless so parallel tests don't race.
final class MockURLProtocol: URLProtocol {
    static func body(_ n: Int) -> Data { Data((0 ..< n).map { UInt8($0 % 251) }) }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "mockmodel" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let n = Int(url.lastPathComponent) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let full = Self.body(n)
        let honorsRange = url.host != "noresume"

        if honorsRange,
           let header = request.value(forHTTPHeaderField: "Range"),
           let start = Self.rangeStart(header), start <= full.count
        {
            let slice = full.subdata(in: start ..< full.count)
            let resp = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "\(slice.count)",
                    "Content-Range": "bytes \(start)-\(full.count - 1)/\(full.count)"
                ]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: slice)
        } else {
            let resp = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(full.count)"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: full)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func rangeStart(_ header: String) -> Int? {
        // "bytes=<start>-"
        guard let eq = header.firstIndex(of: "="), let dash = header.firstIndex(of: "-") else { return nil }
        return Int(header[header.index(after: eq) ..< dash])
    }
}

@Suite("ModelDownloader")
struct ModelDownloaderTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The network download path is cross-platform: Apple streams via
    // URLSession.bytes(for:); Linux/Windows use a URLSessionDataDelegate. The
    // injected mock transport applies on every platform, so these run everywhere.
    @Test("downloads, verifies the checksum, and reports progress")
    func freshDownload() async throws {
        let dir = try tempDir()
        let body = MockURLProtocol.body(2500)
        let spec = try ModelSpec(
            url: #require(URL(string: "mockmodel://m/2500")),
            sha256: hash(body),
            fileName: "model.bin"
        )
        let downloader = ModelDownloader(directory: dir, session: MockURLProtocol.session())

        let recorder = ProgressRecorder()
        let url = try await downloader.ensure(spec) { _, total in recorder.record(total: total) }

        #expect(try Data(contentsOf: url) == body)
        #expect(recorder.total == .some(.some(2500)))
    }

    @Test("a checksum mismatch fails with E_AI_MODEL and leaves no file")
    func checksumMismatch() async throws {
        let dir = try tempDir()
        let spec = try ModelSpec(
            url: #require(URL(string: "mockmodel://m/1000")),
            sha256: String(repeating: "0", count: 64),
            fileName: "m.bin"
        )
        let downloader = ModelDownloader(directory: dir, session: MockURLProtocol.session())

        await #expect(throws: AIError.self) { _ = try await downloader.ensure(spec) }
        #expect(FileManager.default.fileExists(atPath: downloader.localURL(for: spec).path) == false)
        // partial cleaned up too
        #expect(FileManager.default
            .fileExists(atPath: downloader.localURL(for: spec).appendingPathExtension("part").path) == false)
    }

    @Test("a present, matching file is reused without hitting the network")
    func cacheHit() async throws {
        let dir = try tempDir()
        let cached = MockURLProtocol.body(800)
        let spec = try ModelSpec(
            url: #require(URL(string: "mockmodel://m/4096")),
            sha256: hash(cached),
            fileName: "c.bin"
        )
        let downloader = ModelDownloader(directory: dir, session: MockURLProtocol.session())
        // Pre-place the cached bytes. The URL would serve *different* bytes
        // (4096), so getting `cached` back proves no download happened.
        try cached.write(to: downloader.localURL(for: spec))

        let url = try await downloader.ensure(spec)
        #expect(try Data(contentsOf: url) == cached)
    }

    @Test("resumes from a partial .part via a Range request")
    func resume() async throws {
        let dir = try tempDir()
        let full = MockURLProtocol.body(3000)
        let spec = try ModelSpec(
            url: #require(URL(string: "mockmodel://m/3000")),
            sha256: hash(full),
            fileName: "r.bin"
        )
        let downloader = ModelDownloader(directory: dir, session: MockURLProtocol.session())
        // Seed a partial with the correct first 1200 bytes.
        try full.subdata(in: 0 ..< 1200).write(to: downloader.localURL(for: spec).appendingPathExtension("part"))

        let url = try await downloader.ensure(spec)
        #expect(try Data(contentsOf: url) == full)
    }

    @Test("restarts when the server ignores the Range header")
    func ignoredRange() async throws {
        let dir = try tempDir()
        let full = MockURLProtocol.body(2000)
        let spec = try ModelSpec(
            url: #require(URL(string: "mockmodel://noresume/2000")),
            sha256: hash(full),
            fileName: "n.bin"
        )
        let downloader = ModelDownloader(directory: dir, session: MockURLProtocol.session())
        // Seed a *wrong* partial; the server returns 200 (ignores Range), so
        // the downloader must discard it and still produce the correct file.
        try Data(repeating: 0xEE, count: 900)
            .write(to: downloader.localURL(for: spec).appendingPathExtension("part"))

        let url = try await downloader.ensure(spec)
        #expect(try Data(contentsOf: url) == full)
    }
}
