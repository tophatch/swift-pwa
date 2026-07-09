import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - Test backends

/// A working backend: "encodes" by minting a session id and echoing the
/// image's declared size (fixed for the test double), and "decodes" by
/// returning one canned mask per call, incrementing an observable counter.
private final class CannedSegmentationBackend: SegmentationBackend, @unchecked Sendable {
    private(set) var openCalls = 0
    private(set) var segmentCalls = 0
    private(set) var closedSessionIDs: [String] = []
    private var nextID = 0

    func info() async -> VisionCapabilities {
        VisionCapabilities(
            available: true, backend: VisionBackendID.mobileSAMONNX, model: "mobile-sam",
            pointPrompts: true, boxPrompts: true, multimask: true, sessionCaching: true
        )
    }

    func openSession(_ request: OpenSessionRequest) async throws -> VisionSession {
        openCalls += 1
        nextID += 1
        _ = request.image
        return VisionSession(sessionID: "s\(nextID)", width: 100, height: 200)
    }

    func segment(_ request: SegmentRequest) async throws -> SegmentResult {
        segmentCalls += 1
        guard request.sessionID.hasPrefix("s") else {
            throw VisionError.session("unknown session \(request.sessionID)")
        }
        return SegmentResult(masks: [VisionMask(bounds: [1, 2, 3, 4], rle: [0, 4], score: 0.9)])
    }

    func closeSession(_ sessionID: String) async {
        closedSessionIDs.append(sessionID)
    }
}

/// Reports automatic mask generation support, overriding the default
/// `segmentAll`/`segmentAllStream` so an override wins over the default.
private struct AutoMaskBackend: SegmentationBackend {
    func info() async -> VisionCapabilities {
        VisionCapabilities(available: true, backend: "amg", autoMask: true)
    }

    func openSession(_: OpenSessionRequest) async throws -> VisionSession {
        VisionSession(sessionID: "s1", width: 10, height: 10)
    }

    func segment(_: SegmentRequest) async throws -> SegmentResult {
        SegmentResult(masks: [])
    }

    func closeSession(_: String) async {}

    func segmentAll(_: SegmentAllRequest) async throws -> SegmentResult {
        SegmentResult(masks: [VisionMask(bounds: [0, 0, 5, 5], rle: [25], score: 1.0)])
    }

    func segmentAllStream(_: SegmentAllRequest) -> AsyncThrowingStream<VisionProgress, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(done: 1, total: 2))
            continuation.yield(.progress(done: 2, total: 2))
            continuation.yield(.done(masks: [VisionMask(bounds: [0, 0, 1, 1], rle: [1], score: 1.0)]))
            continuation.finish()
        }
    }
}

@Suite("VisionPlugin")
@MainActor
struct VisionPluginTests {
    private func app(_ backend: any SegmentationBackend) -> MockAppContext {
        let app = MockAppContext()
        app.use(VisionPlugin(backend))
        return app
    }

    private func dispatch(_ app: MockAppContext, _ command: String, _ payload: String) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data(payload.utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    private func collect(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> [Data] {
        var out: [Data] = []
        for try await chunk in stream { out.append(chunk) }
        return out
    }

    // MARK: - NoneBackend (the default-install contract)

    @Test("ai.vision.info reports available:false with NoneSegmentationBackend")
    func infoNone() async throws {
        let result = await dispatch(app(NoneSegmentationBackend()), "ai.vision.info", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let caps = try JSONDecoder().decode(VisionCapabilities.self, from: data)
        #expect(caps.available == false)
        #expect(caps.backend == VisionBackendID.none)
    }

    @Test("VisionPlugin() defaults to NoneSegmentationBackend")
    func defaultInit() async throws {
        let app = MockAppContext()
        app.use(VisionPlugin())
        let result = await dispatch(app, "ai.vision.info", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(VisionCapabilities.self, from: data).available == false)
    }

    @Test("ai.vision.openSession on NoneBackend maps to E_VISION_UNAVAILABLE")
    func openSessionNone() async {
        let payload = #"{"image":{"path":"/layer.png"}}"#
        let result = await dispatch(app(NoneSegmentationBackend()), "ai.vision.openSession", payload)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == VisionError.unavailableCode)
    }

    @Test("ai.vision.segment on NoneBackend maps to E_VISION_UNAVAILABLE")
    func segmentNone() async {
        let payload = #"{"sessionId":"s1","points":[{"x":1,"y":2,"label":1}]}"#
        let result = await dispatch(app(NoneSegmentationBackend()), "ai.vision.segment", payload)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == VisionError.unavailableCode)
    }

    @Test("ai.vision.closeSession on NoneBackend is a harmless no-op")
    func closeSessionNone() async {
        let result = await dispatch(app(NoneSegmentationBackend()), "ai.vision.closeSession", #"{"sessionId":"s1"}"#)
        guard case .ok = result else { Issue.record("expected ok"); return }
    }

    @Test("ai.vision.segmentAll is reserved by default — reports E_UNIMPLEMENTED")
    func segmentAllReserved() async {
        let result = await dispatch(app(NoneSegmentationBackend()), "ai.vision.segmentAll", #"{"sessionId":"s1"}"#)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.unimplemented)
    }

    @Test("ai.vision.segmentAllStream is reserved by default — reports E_UNIMPLEMENTED")
    func segmentAllStreamReserved() async throws {
        let result = await dispatch(
            app(NoneSegmentationBackend()),
            "ai.vision.segmentAllStream",
            #"{"sessionId":"s1"}"#
        )
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        do {
            for try await _ in stream {}
            Issue.record("expected the reserved stream to throw")
        } catch let err as BridgeError {
            #expect(err.code == BridgeError.unimplemented)
        }
    }

    @Test("ai.vision.ensureModel is reserved by default — reports E_UNIMPLEMENTED")
    func ensureModelReserved() async throws {
        let result = await dispatch(app(NoneSegmentationBackend()), "ai.vision.ensureModel", "{}")
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        do {
            for try await _ in stream {}
            Issue.record("expected the reserved stream to throw")
        } catch let err as BridgeError {
            #expect(err.code == BridgeError.unimplemented)
        }
    }

    @Test("ai.vision.benchmark is reserved by default — reports E_UNIMPLEMENTED")
    func benchmarkReserved() async {
        let result = await dispatch(app(NoneSegmentationBackend()), "ai.vision.benchmark", "{}")
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.unimplemented)
    }

    // MARK: - A working backend (encode/decode session split)

    @Test("ai.vision.info reports the working backend's capabilities")
    func infoWorking() async throws {
        let result = await dispatch(app(CannedSegmentationBackend()), "ai.vision.info", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let caps = try JSONDecoder().decode(VisionCapabilities.self, from: data)
        #expect(caps.available == true)
        #expect(caps.backend == VisionBackendID.mobileSAMONNX)
        #expect(caps.pointPrompts == true)
        #expect(caps.boxPrompts == true)
        #expect(caps.sessionCaching == true)
    }

    @Test("ai.vision.openSession mints a session with echoed dimensions")
    func openSessionOK() async throws {
        let backend = CannedSegmentationBackend()
        let payload = #"{"image":{"path":"/layer-cache.png"}}"#
        let result = await dispatch(app(backend), "ai.vision.openSession", payload)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let session = try JSONDecoder().decode(VisionSession.self, from: data)
        #expect(session.sessionID == "s1")
        #expect(session.width == 100)
        #expect(session.height == 200)
        #expect(backend.openCalls == 1)
    }

    @Test("ai.vision.segment threads point + box prompts and returns masks")
    func segmentOK() async throws {
        let backend = CannedSegmentationBackend()
        let payload = #"""
        {"sessionId":"s1","points":[{"x":120,"y":84,"label":1}],"box":[0,0,50,50],"multimask":true}
        """#
        let result = await dispatch(app(backend), "ai.vision.segment", payload)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(SegmentResult.self, from: data)
        #expect(out.masks.count == 1)
        #expect(out.masks.first?.bounds == [1, 2, 3, 4])
        #expect(out.masks.first?.score == 0.9)
        #expect(backend.segmentCalls == 1)
    }

    @Test("ai.vision.segment against an unknown session maps to E_VISION_SESSION")
    func segmentUnknownSession() async {
        let payload = #"{"sessionId":"missing"}"#
        let result = await dispatch(app(CannedSegmentationBackend()), "ai.vision.segment", payload)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == VisionError.sessionCode)
    }

    @Test("ai.vision.closeSession releases the session")
    func closeSessionOK() async {
        let backend = CannedSegmentationBackend()
        let result = await dispatch(app(backend), "ai.vision.closeSession", #"{"sessionId":"s1"}"#)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(backend.closedSessionIDs == ["s1"])
    }

    // MARK: - Automatic mask generation override

    @Test("a backend's segmentAll override wins over the default")
    func segmentAllOverride() async throws {
        let result = await dispatch(app(AutoMaskBackend()), "ai.vision.segmentAll", #"{"sessionId":"s1"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(SegmentResult.self, from: data)
        #expect(out.masks.count == 1)
        #expect(out.masks.first?.score == 1.0)
    }

    @Test("a backend's segmentAllStream override emits progress then done")
    func segmentAllStreamOverride() async throws {
        let result = await dispatch(app(AutoMaskBackend()), "ai.vision.segmentAllStream", #"{"sessionId":"s1"}"#)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        let events = try await collect(stream).map { try JSONDecoder().decode(VisionProgress.self, from: $0) }
        #expect(events.map(\.type) == ["progress", "progress", "done"])
        #expect(events.first?.done == 1)
        #expect(events.last?.masks?.count == 1)
    }

    @Test("default segmentAllStream (no override) wraps segmentAll in a single done")
    func defaultSegmentAllStreamWrapsUnsupported() async throws {
        let result = await dispatch(
            app(CannedSegmentationBackend()), "ai.vision.segmentAllStream", #"{"sessionId":"s1"}"#
        )
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        do {
            for try await _ in stream {}
            Issue.record("expected the default-unsupported stream to throw")
        } catch let err as BridgeError {
            #expect(err.code == BridgeError.unimplemented)
        }
    }
}

// MARK: - Codable round-trips (the wire contract)

@Suite("Vision wire contract")
struct VisionWireContractTests {
    @Test("VisionCapabilities round-trips")
    func capabilities() throws {
        let caps = VisionCapabilities(
            available: true, backend: VisionBackendID.mobileSAMONNX, model: "mobile-sam",
            pointPrompts: true, boxPrompts: true, multimask: true, autoMask: false,
            maxImageSize: 1024, sessionCaching: true
        )
        let decoded = try JSONDecoder().decode(VisionCapabilities.self, from: JSONEncoder().encode(caps))
        #expect(decoded == caps)
    }

    @Test("OpenSessionRequest / VisionSession round-trip with camelCase sessionId")
    func sessionTypes() throws {
        let req = OpenSessionRequest(image: .file("/layer.png"))
        #expect(try JSONDecoder().decode(OpenSessionRequest.self, from: JSONEncoder().encode(req)) == req)

        let session = VisionSession(sessionID: "abc", width: 10, height: 20)
        let data = try JSONEncoder().encode(session)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["sessionId"] as? String == "abc")
        #expect(try JSONDecoder().decode(VisionSession.self, from: data) == session)
    }

    @Test("SegmentRequest with points + box round-trips")
    func segmentRequest() throws {
        let req = SegmentRequest(
            sessionID: "s1", points: [VisionPoint(x: 1, y: 2, label: 1)], box: [0, 0, 10, 10], multimask: true
        )
        let decoded = try JSONDecoder().decode(SegmentRequest.self, from: JSONEncoder().encode(req))
        #expect(decoded == req)
        #expect(decoded.sessionID == "s1")
    }

    @Test("VisionMask / SegmentResult round-trip")
    func maskTypes() throws {
        let mask = VisionMask(bounds: [0, 0, 4, 4], rle: [16, 0], score: 0.75)
        #expect(try JSONDecoder().decode(VisionMask.self, from: JSONEncoder().encode(mask)) == mask)
        let result = SegmentResult(masks: [mask])
        #expect(try JSONDecoder().decode(SegmentResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test("VisionProgress progress and done round-trip")
    func progressEvents() throws {
        let progress = VisionProgress.progress(done: 1, total: 4)
        #expect(try JSONDecoder().decode(VisionProgress.self, from: JSONEncoder().encode(progress)) == progress)
        let done = VisionProgress.done(masks: [VisionMask(bounds: [0, 0, 1, 1], rle: [1], score: 1)])
        #expect(try JSONDecoder().decode(VisionProgress.self, from: JSONEncoder().encode(done)) == done)
    }

    @Test("CloseSessionRequest decodes camelCase sessionId")
    func closeSessionRequest() throws {
        let req = try JSONDecoder().decode(CloseSessionRequest.self, from: Data(#"{"sessionId":"s9"}"#.utf8))
        #expect(req.sessionID == "s9")
    }
}
