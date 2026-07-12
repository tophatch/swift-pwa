import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Mocks

/// A `NetworkClient` that records the request it was handed and returns a
/// canned response / download stream — so the plugin's wiring (arg decode,
/// base64, defaults, error mapping) can be tested without a real network.
private final class MockNetworkClient: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastRequest: NetRequest?
    private var _lastDownload: NetDownloadRequest?
    private let response: NetResponse
    private let sendError: (any Error)?
    private let downloadEvents: [NetDownloadEvent]

    init(
        response: NetResponse = NetResponse(status: 200, headers: [:], body: Data()),
        sendError: (any Error)? = nil,
        downloadEvents: [NetDownloadEvent] = []
    ) {
        self.response = response
        self.sendError = sendError
        self.downloadEvents = downloadEvents
    }

    func send(_ request: NetRequest) async throws -> NetResponse {
        lock.withLock { _lastRequest = request }
        if let sendError { throw sendError }
        return response
    }

    func download(_ request: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error> {
        lock.withLock { _lastDownload = request }
        let events = downloadEvents
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    var lastRequest: NetRequest? {
        lock.withLock { _lastRequest }
    }
    var lastDownload: NetDownloadRequest? {
        lock.withLock { _lastDownload }
    }
}

// MARK: - Tests

@Suite("NetPlugin")
@MainActor
struct NetPluginTests {
    private func makeApp(_ client: any NetworkClient) -> MockAppContext {
        let app = MockAppContext()
        app.use(NetPlugin(client))
        return app
    }

    private func dispatch(
        _ command: String,
        _ payload: [String: Any],
        on app: MockAppContext
    ) async -> InvocationResult {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let inv = Invocation(id: 1, command: command, payload: data)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    private func decodeOK<T: Decodable>(_ result: InvocationResult, as _: T.Type) throws -> T {
        guard case let .ok(data) = result else {
            throw BridgeError(code: "TEST", message: "expected .ok, got \(result)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: net.request

    @Test("net.request builds the NetRequest from wire args and returns the response")
    func requestRoundTrip() async throws {
        let client = MockNetworkClient(response: NetResponse(
            status: 201,
            headers: ["Content-Type": "application/json"],
            body: Data("world".utf8)
        ))
        let app = makeApp(client)

        let result = await dispatch("net.request", [
            "method": "POST",
            "url": "https://example.com/v1/thing",
            "headers": ["X-Api-Key": "secret"],
            "bodyBase64": Data("hello".utf8).base64EncodedString(),
            "timeoutMs": 5000
        ], on: app)

        // Request the client actually saw.
        let sent = try #require(client.lastRequest)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://example.com/v1/thing")
        #expect(sent.headers["X-Api-Key"] == "secret")
        #expect(sent.body == Data("hello".utf8))
        #expect(sent.timeout == 5.0)

        // Response surfaced to JS.
        let response = try decodeOK(result, as: NetResponseResult.self)
        #expect(response.status == 201)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(Data(base64Encoded: response.bodyBase64) == Data("world".utf8))
    }

    @Test("net.request defaults: GET method, 60s timeout, no body")
    func requestDefaults() async throws {
        let client = MockNetworkClient()
        let app = makeApp(client)
        _ = await dispatch("net.request", ["url": "https://example.com"], on: app)
        let sent = try #require(client.lastRequest)
        #expect(sent.method == "GET")
        #expect(sent.timeout == 60)
        #expect(sent.body == nil)
        #expect(sent.headers.isEmpty)
    }

    @Test("net.request returns a non-2xx as a status, not an error")
    func requestNon2xxIsNotError() async throws {
        let client = MockNetworkClient(response: NetResponse(status: 404, headers: [:], body: Data()))
        let app = makeApp(client)
        let result = await dispatch("net.request", ["url": "https://example.com/missing"], on: app)
        let response = try decodeOK(result, as: NetResponseResult.self)
        #expect(response.status == 404)
    }

    @Test("net.request rejects an invalid url with E_NET")
    func requestInvalidURL() async {
        let app = makeApp(MockNetworkClient())
        let result = await dispatch("net.request", ["url": ""], on: app)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.net)
    }

    @Test("net.request rejects non-base64 body with E_NET")
    func requestBadBody() async {
        let app = makeApp(MockNetworkClient())
        let result = await dispatch(
            "net.request",
            ["url": "https://example.com", "bodyBase64": "not base64!!"],
            on: app
        )
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.net)
    }

    @Test("net.request surfaces a transport failure as E_NET")
    func requestTransportError() async {
        let client = MockNetworkClient(sendError: BridgeError(code: BridgeError.net, message: "boom"))
        let app = makeApp(client)
        let result = await dispatch("net.request", ["url": "https://example.com"], on: app)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.net)
    }

    // MARK: net.download

    @Test("net.download streams progress then a terminal done with the written path")
    func downloadStream() async throws {
        let client = MockNetworkClient(downloadEvents: [
            .progress(bytesDownloaded: 10, totalBytes: 100),
            .progress(bytesDownloaded: 100, totalBytes: 100),
            .done(path: "/tmp/out.bin")
        ])
        let app = makeApp(client)

        let result = await dispatch("net.download", [
            "url": "https://example.com/blob",
            "destPath": "/tmp/out.bin",
            "sha256": "abc123"
        ], on: app)
        guard case let .stream(stream) = result else { Issue.record("expected a stream"); return }

        var chunks: [NetDownloadChunk] = []
        for try await data in stream {
            try chunks.append(JSONDecoder().decode(NetDownloadChunk.self, from: data))
        }
        #expect(chunks.count == 3)
        #expect(chunks[0].type == "progress")
        #expect(chunks[0].bytesDownloaded == 10)
        #expect(chunks[2].type == "done")
        #expect(chunks[2].path == "/tmp/out.bin")

        // The client saw the destination + checksum.
        let requested = try #require(client.lastDownload)
        #expect(requested.destination.path == "/tmp/out.bin")
        #expect(requested.sha256 == "abc123")
    }

    @Test("net.download rejects an invalid url with an E_NET stream error")
    func downloadInvalidURL() async throws {
        let app = makeApp(MockNetworkClient())
        let result = await dispatch("net.download", ["url": "", "destPath": "/tmp/x"], on: app)
        guard case let .stream(stream) = result else { Issue.record("expected a stream"); return }
        await #expect(throws: (any Error).self) {
            for try await _ in stream {}
        }
    }
}

// MARK: - URLSessionNetworkClient (real transport, mocked HTTP)

/// Captures the outbound request and returns a canned HTTP response, so
/// `URLSessionNetworkClient.send` can be exercised over the real URLSession
/// stack without a network.
private final class NetEchoURLProtocol: URLProtocol {
    final class Captured: @unchecked Sendable {
        let lock = NSLock()
        var method: String?
        var headers: [String: String] = [:]
    }

    static let captured = Captured()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "netmock" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.captured.lock.withLock {
            Self.captured.method = request.httpMethod
            Self.captured.headers = request.allHTTPHeaderFields ?? [:]
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 207,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["X-Reply": "pong"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("hello-body".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("URLSessionNetworkClient")
struct URLSessionNetworkClientTests {
    @Test("send builds the URLRequest and parses status / headers / body")
    func sendRoundTrip() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetEchoURLProtocol.self]
        let client = URLSessionNetworkClient(configuration: config)

        let response = try await client.send(NetRequest(
            method: "POST",
            url: #require(URL(string: "netmock://host/path")),
            headers: ["X-Test": "1"]
        ))

        #expect(response.status == 207)
        #expect(response.body == Data("hello-body".utf8))
        // Header keys may be normalized by the platform — match case-insensitively.
        #expect(response.headers.first { $0.key.lowercased() == "x-reply" }?.value == "pong")

        NetEchoURLProtocol.captured.lock.withLock {
            #expect(NetEchoURLProtocol.captured.method == "POST")
            #expect(NetEchoURLProtocol.captured.headers.first { $0.key.lowercased() == "x-test" }?.value == "1")
        }
    }
}
