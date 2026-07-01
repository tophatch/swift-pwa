import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - Mocks

/// A controllable `ProcessChild` whose events are driven by the test.
private final class MockProcessChild: ProcessChild, @unchecked Sendable {
    let pid: Int32
    let events: AsyncThrowingStream<ProcessEvent, any Error>
    private let continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation
    private let lock = NSLock()
    private var _written: [Data] = []
    private var _terminated = false
    private var _stdinClosed = false

    init(pid: Int32) {
        self.pid = pid
        var cont: AsyncThrowingStream<ProcessEvent, any Error>.Continuation!
        events = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }

    func emit(_ event: ProcessEvent) { continuation.yield(event) }
    func finishEvents() { continuation.finish() }

    func write(_ data: Data) { lock.withLock { _written.append(data) } }
    func closeStdin() { lock.withLock { _stdinClosed = true } }
    func terminate() {
        lock.withLock { _terminated = true }
        continuation.finish()
    }

    var written: [Data] {
        lock.withLock { _written }
    }
    var didTerminate: Bool {
        lock.withLock { _terminated }
    }
    var didCloseStdin: Bool {
        lock.withLock { _stdinClosed }
    }
}

private final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    let child: MockProcessChild
    private let error: (any Error)?

    init(child: MockProcessChild, error: (any Error)? = nil) {
        self.child = child
        self.error = error
    }

    func spawn(_: ProcessSpawnConfig) throws -> any ProcessChild {
        if let error { throw error }
        return child
    }
}

// MARK: - Tests

@Suite("ProcessPlugin")
@MainActor
struct ProcessPluginTests {
    private func makeApp(runner: any ProcessRunner) -> MockAppContext {
        let app = MockAppContext()
        app.use(ProcessPlugin(runner))
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

    private func openStream(_ config: [String: Any], on app: MockAppContext) async throws
        -> AsyncThrowingStream<Data, any Error>
    {
        let result = await dispatch("process.stream", config, on: app)
        guard case let .stream(stream) = result else {
            throw BridgeError(code: "TEST", message: "expected a stream")
        }
        return stream
    }

    private func decode(_ data: Data?) throws -> ProcessStreamChunk {
        try JSONDecoder().decode(ProcessStreamChunk.self, from: data ?? Data())
    }

    @Test("process.stream emits spawned, then stdout, then a terminal exit")
    func streamLifecycle() async throws {
        let child = MockProcessChild(pid: 4242)
        let app = makeApp(runner: MockProcessRunner(child: child))
        let stream = try await openStream(["command": "x"], on: app)
        var iter = stream.makeAsyncIterator()

        // First frame is `spawned`, yielded synchronously during spawn.
        let spawned = try await decode(iter.next())
        #expect(spawned.type == "spawned")
        #expect(spawned.pid == 4242)

        child.emit(.stdout(Data("hello".utf8)))
        let out = try await decode(iter.next())
        #expect(out.type == "stdout")
        #expect(Data(base64Encoded: out.dataBase64 ?? "") == Data("hello".utf8))

        child.emit(.exit(code: 0))
        child.finishEvents()
        let exit = try await decode(iter.next())
        #expect(exit.type == "exit")
        #expect(exit.code == 0)

        // Stream is complete.
        let end = try await iter.next()
        #expect(end == nil)
    }

    @Test("process.write routes base64 stdin to the child by pid")
    func writeRoutes() async throws {
        let child = MockProcessChild(pid: 7)
        let app = makeApp(runner: MockProcessRunner(child: child))
        // Hold the stream alive: dropping it would deinit → onTermination →
        // deregister the child before we write to it.
        let stream = try await openStream(["command": "x"], on: app)
        let payload = Data("feed me".utf8).base64EncodedString()
        let result = await dispatch("process.write", ["pid": 7, "dataBase64": payload], on: app)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(child.written == [Data("feed me".utf8)])
        withExtendedLifetime(stream) {}
    }

    @Test("process.write with closeStdin closes the child's stdin")
    func writeCloseStdin() async throws {
        let child = MockProcessChild(pid: 7)
        let app = makeApp(runner: MockProcessRunner(child: child))
        let stream = try await openStream(["command": "x"], on: app)
        _ = await dispatch("process.write", ["pid": 7, "closeStdin": true], on: app)
        #expect(child.didCloseStdin)
        withExtendedLifetime(stream) {}
    }

    @Test("process.kill terminates the child by pid")
    func killTerminates() async throws {
        let child = MockProcessChild(pid: 99)
        let app = makeApp(runner: MockProcessRunner(child: child))
        let stream = try await openStream(["command": "x"], on: app)
        _ = await dispatch("process.kill", ["pid": 99], on: app)
        #expect(child.didTerminate)
        withExtendedLifetime(stream) {}
    }

    @Test("process.write / process.kill on an unknown pid fail with notFound")
    func unknownPid() async {
        let child = MockProcessChild(pid: 1)
        let app = makeApp(runner: MockProcessRunner(child: child))
        for command in ["process.write", "process.kill"] {
            let result = await dispatch(command, ["pid": 123_456], on: app)
            guard case let .failure(err) = result else { Issue.record("expected failure"); return }
            #expect(err.code == BridgeError.notFound)
        }
    }

    @Test("a spawn failure surfaces as a stream error")
    func spawnFailure() async throws {
        let child = MockProcessChild(pid: 1)
        let runner = MockProcessRunner(
            child: child,
            error: BridgeError(code: BridgeError.handler, message: "boom")
        )
        let app = makeApp(runner: runner)
        let stream = try await openStream(["command": "nope"], on: app)
        await #expect(throws: (any Error).self) {
            for try await _ in stream {}
        }
    }

    @Test("after the child exits it is deregistered (write fails with notFound)")
    func deregisterOnExit() async throws {
        let child = MockProcessChild(pid: 55)
        let app = makeApp(runner: MockProcessRunner(child: child))
        let stream = try await openStream(["command": "x"], on: app)

        // Drain to completion.
        child.emit(.exit(code: 0))
        child.finishEvents()
        for try await _ in stream {}

        let result = await dispatch("process.write", ["pid": 55, "dataBase64": ""], on: app)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.notFound)
    }

    @Test("cancelling the subscription terminates the child (teardown)")
    func cancellationTerminates() async throws {
        let child = MockProcessChild(pid: 321)
        let app = makeApp(runner: MockProcessRunner(child: child))
        let stream = try await openStream(["command": "x"], on: app)

        // Consume in a task, then cancel it — this is what BridgeRuntime does on
        // unsubscribe / window close, and it must reach `child.terminate()`.
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()

        // onTermination fires asynchronously after cancellation; poll briefly.
        var terminated = false
        for _ in 0 ..< 100 {
            if child.didTerminate { terminated = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(terminated)
    }

    #if os(macOS) || os(Linux)
        @Test("SystemProcess runs a real command and streams its stdout + exit")
        func realEcho() async throws {
            let app = makeApp(runner: SystemProcess())
            let stream = try await openStream(["command": "/bin/echo", "args": ["hello"]], on: app)

            var pid: Int32?
            var stdout = Data()
            var exitCode: Int32?
            for try await data in stream {
                let chunk = try decode(data)
                switch chunk.type {
                case "spawned": pid = chunk.pid
                case "stdout": stdout.append(Data(base64Encoded: chunk.dataBase64 ?? "") ?? Data())
                case "exit": exitCode = chunk.code
                default: break
                }
            }
            #expect(pid != nil)
            #expect(String(decoding: stdout, as: UTF8.self) == "hello\n")
            #expect(exitCode == 0)
        }

        @Test("SystemProcess feeds stdin and reads it back (cat)")
        func realCat() async throws {
            let app = makeApp(runner: SystemProcess())
            let stream = try await openStream(["command": "/bin/cat"], on: app)

            var stdout = Data()
            var exitCode: Int32?
            for try await data in stream {
                let chunk = try decode(data)
                switch chunk.type {
                case "spawned":
                    // Feed stdin then close it so `cat` echoes and exits.
                    let pid = try #require(chunk.pid)
                    let bytes = Data("ping\n".utf8).base64EncodedString()
                    _ = await dispatch(
                        "process.write",
                        ["pid": pid, "dataBase64": bytes, "closeStdin": true],
                        on: app
                    )
                case "stdout": stdout.append(Data(base64Encoded: chunk.dataBase64 ?? "") ?? Data())
                case "exit": exitCode = chunk.code
                default: break
                }
            }
            #expect(String(decoding: stdout, as: UTF8.self) == "ping\n")
            #expect(exitCode == 0)
        }
    #endif
}
