import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - Mock

/// A transcoder that records what it was handed and returns a canned result, so
/// ``ImagePlugin``'s wiring (arg decode, format parsing, error mapping) can be
/// tested without a platform codec.
private final class MockTranscoder: ImageTranscoder, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: ImageTranscodeRequest?
    private let failure: ImageTranscodeError?
    private let caps: ImageCodecCapabilities

    init(
        failure: ImageTranscodeError? = nil,
        caps: ImageCodecCapabilities = ImageCodecCapabilities(
            decode: ["png", "heic"], encode: ["png", "jpeg"]
        )
    ) {
        self.failure = failure
        self.caps = caps
    }

    var received: ImageTranscodeRequest? {
        lock.withLock { _received }
    }

    func capabilities() async -> ImageCodecCapabilities { caps }

    func transcode(_ request: ImageTranscodeRequest) async throws -> ImageTranscodeResult {
        lock.withLock { _received = request }
        if let failure { throw failure }
        return ImageTranscodeResult(path: request.outputPath, width: 4, height: 2, bytes: 99)
    }
}

// MARK: - Tests

@Suite("ImagePlugin")
@MainActor
struct ImagePluginTests {
    private func makeApp(_ transcoder: any ImageTranscoder) -> MockAppContext {
        let app = MockAppContext()
        app.use(ImagePlugin(transcoder))
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

    private func error(_ result: InvocationResult) throws -> BridgeError {
        guard case let .failure(error) = result else {
            throw BridgeError(code: "TEST", message: "expected .failure, got \(result)")
        }
        return error
    }

    @Test("image.info reports the transcoder's capabilities")
    func infoReportsCapabilities() async throws {
        let app = makeApp(MockTranscoder())
        let result = await dispatch("image.info", [:], on: app)
        let caps = try decodeOK(result, as: ImageCodecCapabilities.self)
        #expect(caps.decode == ["png", "heic"])
        #expect(caps.encode == ["png", "jpeg"])
    }

    @Test("image.transcode passes the request through and returns the result")
    func transcodePassesThrough() async throws {
        let transcoder = MockTranscoder()
        let app = makeApp(transcoder)
        let result = await dispatch("image.transcode", [
            "path": "/photos/IMG_0001.HEIC",
            "format": "jpeg",
            "maxSide": 2048,
            "quality": 0.7,
            "outputPath": "/cache/IMG_0001.jpg"
        ], on: app)

        let out = try decodeOK(result, as: ImageTranscodeResult.self)
        #expect(out.path == "/cache/IMG_0001.jpg")
        #expect(out.width == 4)
        #expect(out.bytes == 99)

        let sent = transcoder.received
        #expect(sent?.path == "/photos/IMG_0001.HEIC")
        #expect(sent?.format == .jpeg)
        #expect(sent?.maxSide == 2048)
        #expect(sent?.quality == 0.7)
    }

    @Test("format defaults to png when omitted")
    func formatDefaultsToPNG() async {
        let transcoder = MockTranscoder()
        let app = makeApp(transcoder)
        _ = await dispatch("image.transcode", ["dataBase64": "AAAA"], on: app)
        #expect(transcoder.received?.format == .png)
    }

    @Test("an unknown format is refused with the valid ones named")
    func unknownFormatIsRefused() async throws {
        let app = makeApp(MockTranscoder())
        let result = await dispatch("image.transcode", [
            "dataBase64": "AAAA", "format": "tiff"
        ], on: app)
        let err = try error(result)
        #expect(err.code == BridgeError.imageUnsupported)
        #expect(err.message.contains("png"))
        #expect(err.message.contains("jpeg"))
    }

    /// The split matters: `E_IMAGE_UNSUPPORTED` is a question `image.info` could
    /// have answered first, `E_IMAGE` is not.
    @Test("an unsupported source maps to E_IMAGE_UNSUPPORTED, a failure to E_IMAGE")
    func errorCodesAreDistinct() async throws {
        let unsupported = makeApp(MockTranscoder(failure: .unsupportedSource("heic")))
        let result = await dispatch("image.transcode", ["path": "/x.heic"], on: unsupported)
        #expect(try error(result).code == BridgeError.imageUnsupported)

        let broken = makeApp(MockTranscoder(failure: .failed("disk full")))
        let result2 = await dispatch("image.transcode", ["path": "/x.png"], on: broken)
        let err = try error(result2)
        #expect(err.code == BridgeError.image)
        #expect(err.message.contains("disk full"))
    }

    @Test("registered with no transcoder, the contract exists and fails loudly")
    func defaultTranscoderRefuses() async throws {
        let app = MockAppContext()
        app.use(ImagePlugin())

        let info = await dispatch("image.info", [:], on: app)
        let caps = try decodeOK(info, as: ImageCodecCapabilities.self)
        #expect(caps.decode.isEmpty)
        #expect(caps.encode.isEmpty)

        let result = await dispatch("image.transcode", ["dataBase64": "AAAA"], on: app)
        let err = try error(result)
        #expect(err.code == BridgeError.image)
        // The message has to name the fix — this is the failure an adopter hits
        // when they register the plugin but forget the product.
        #expect(err.message.contains("PlatformImageTranscoder"))
    }
}
