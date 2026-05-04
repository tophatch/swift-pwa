import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("CommandRegistry")
struct RegistryTests {
    @Test("dispatch returns notFound for unregistered command")
    func notFound() async {
        let registry = CommandRegistry()
        let app = await MainActor.run { MockAppContext(registry: registry) }
        let inv = Invocation(id: 1, command: "missing", payload: Data("null".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await registry.dispatch(ctx)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.notFound)
    }

    @Test("typed handler decodes args and encodes result")
    func typedHandler() async throws {
        struct Args: Codable, Sendable { let n: Int }
        struct Out: Codable, Sendable, Equatable { let doubled: Int }

        let registry = CommandRegistry()
        registry.register("double", typed: { (args: Args, _) -> Out in
            Out(doubled: args.n * 2)
        })

        let app = await MainActor.run { MockAppContext(registry: registry) }
        let inv = try Invocation(
            id: 1,
            command: "double",
            payload: JSONEncoder().encode(Args(n: 21))
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(Out.self, from: data)
        #expect(out == Out(doubled: 42))
    }

    @Test("typed handler reports decode failures")
    func decodeFailure() async {
        struct Args: Codable, Sendable { let n: Int }
        let registry = CommandRegistry()
        registry.register("strict", typed: { (_: Args, _) -> Int in 0 })
        let app = await MainActor.run { MockAppContext(registry: registry) }
        let inv = Invocation(id: 1, command: "strict", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await registry.dispatch(ctx)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.decode)
    }

    @Test("thrown BridgeError surfaces verbatim")
    func bridgeErrorPropagates() async {
        let registry = CommandRegistry()
        registry.register("bang", typed: { (_: EmptyArgs, _) -> EmptyResult in
            throw BridgeError(code: "E_CUSTOM", message: "boom")
        })
        let app = await MainActor.run { MockAppContext(registry: registry) }
        let inv = Invocation(id: 1, command: "bang", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await registry.dispatch(ctx)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == "E_CUSTOM")
        #expect(err.message == "boom")
    }

    @Test("streaming handler yields chunks then ends")
    func streamingHandler() async throws {
        let registry = CommandRegistry()
        registry.registerStream("count", typed: { (_: EmptyArgs, _) -> AsyncThrowingStream<Int, any Error> in
            AsyncThrowingStream { continuation in
                continuation.yield(1)
                continuation.yield(2)
                continuation.yield(3)
                continuation.finish()
            }
        })

        let app = await MainActor.run { MockAppContext(registry: registry) }
        let inv = Invocation(id: 1, command: "count", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await registry.dispatch(ctx)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }
        var received: [Int] = []
        for try await chunk in stream {
            try received.append(JSONDecoder().decode(Int.self, from: chunk))
        }
        #expect(received == [1, 2, 3])
    }

    @Test("has and names report registered commands")
    func introspection() {
        let registry = CommandRegistry()
        registry.register("a") { _ in .ok(Data("null".utf8)) }
        registry.register("b") { _ in .ok(Data("null".utf8)) }
        #expect(registry.has("a"))
        #expect(registry.has("b"))
        #expect(!registry.has("c"))
        let names = registry.names().sorted()
        #expect(names == ["a", "b"])
    }
}
