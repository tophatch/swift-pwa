import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// The registration-time command catalog that feeds typed codegen (roadmap #6):
/// `CommandRegistry` records a `CommandDescriptor` for every `typed:`
/// registration, exposed via `descriptors()` and the `__bridge.describe` command.
@Suite("Bridge command catalog")
struct BridgeCatalogTests {
    struct Point2D: BridgeType, Equatable {
        let x: Int
        let y: Int
        static var bridgeSchema: BridgeSchema {
            .object(name: "Point2D", fields: [
                .init(name: "x", schema: .int),
                .init(name: "y", schema: .int)
            ])
        }
    }

    struct MoveArgs: BridgeType {
        let to: Point2D
        let label: String?
        static var bridgeSchema: BridgeSchema {
            .object(name: "MoveArgs", fields: [
                .init(name: "to", schema: Point2D.bridgeSchema),
                .init(name: "label", schema: .optional(.string))
            ])
        }
    }

    @Test("typed unary registration records a descriptor with arg + result schemas")
    func unaryDescriptor() {
        let registry = CommandRegistry()
        registry.register("geo.move", typed: { (_: MoveArgs, _) -> Point2D in Point2D(x: 0, y: 0) })

        let d = registry.descriptors().first { $0.name == "geo.move" }
        #expect(d?.kind == .unary)
        #expect(d?.args == MoveArgs.bridgeSchema)
        #expect(d?.result == Point2D.bridgeSchema)
        #expect(d?.inbound == nil)
    }

    @Test("stream + session registrations record their kind, chunk, and inbound shapes")
    func streamAndSessionDescriptors() {
        let registry = CommandRegistry()
        registry.registerStream("geo.track", typed: { (_: EmptyArgs, _) -> AsyncThrowingStream<Point2D, any Error> in
            AsyncThrowingStream { $0.finish() }
        })
        registry.registerSession(
            "geo.session",
            typed: { (_: EmptyArgs, _: BridgeInbound<Point2D>, _) -> AsyncThrowingStream<Point2D, any Error> in
                AsyncThrowingStream { $0.finish() }
            }
        )

        let stream = registry.descriptors().first { $0.name == "geo.track" }
        #expect(stream?.kind == .stream)
        #expect(stream?.args == .void)
        #expect(stream?.result == Point2D.bridgeSchema)

        let session = registry.descriptors().first { $0.name == "geo.session" }
        #expect(session?.kind == .session)
        #expect(session?.inbound == Point2D.bridgeSchema)
        #expect(session?.result == Point2D.bridgeSchema)
    }

    @Test("a non-BridgeType arg/result degrades to .unknown")
    func unknownForNonConforming() {
        struct Opaque: Codable, Sendable { let v: Int }
        let registry = CommandRegistry()
        registry.register("x.opaque", typed: { (_: Opaque, _) -> Opaque in Opaque(v: 1) })

        let d = registry.descriptors().first { $0.name == "x.opaque" }
        #expect(d?.args == .unknown)
        #expect(d?.result == .unknown)
    }

    @Test("raw register has no descriptor but still appears in names()")
    func rawHasNoDescriptor() {
        let registry = CommandRegistry()
        registry.register("raw.cmd") { _ in .ok(Data("null".utf8)) }

        #expect(registry.descriptors().contains { $0.name == "raw.cmd" } == false)
        #expect(registry.names().contains("raw.cmd"))
    }

    @Test("unregister drops the descriptor")
    func unregisterDropsDescriptor() {
        let registry = CommandRegistry()
        registry.register("geo.move", typed: { (_: MoveArgs, _) -> Point2D in Point2D(x: 0, y: 0) })
        #expect(registry.descriptors().contains { $0.name == "geo.move" })
        registry.unregister("geo.move")
        #expect(registry.descriptors().contains { $0.name == "geo.move" } == false)
    }

    @Test("descriptor + nested schema round-trip through JSON")
    func descriptorJSONRoundTrip() throws {
        let d = CommandDescriptor(
            name: "geo.move",
            kind: .unary,
            args: MoveArgs.bridgeSchema,
            result: Point2D.bridgeSchema
        )
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(CommandDescriptor.self, from: data)
        #expect(back == d)
    }

    @Test("__bridge.describe returns the catalog over the bridge")
    @MainActor
    func describeCommand() async throws {
        let app = MockAppContext()
        app.use(PlatformInfoPlugin())
        app.registry.register("geo.move", typed: { (_: MoveArgs, _) -> Point2D in Point2D(x: 0, y: 0) })

        let inv = Invocation(id: 1, command: "__bridge.describe", payload: Data("{}".utf8))
        let result = await app.registry.dispatch(
            CommandContext(invocation: inv, originWindow: nil, appContext: app)
        )
        guard case let .ok(data) = result else { Issue.record("expected .ok"); return }
        let descriptors = try JSONDecoder().decode([CommandDescriptor].self, from: data)

        let move = descriptors.first { $0.name == "geo.move" }
        #expect(move?.kind == .unary)
        #expect(move?.args == MoveArgs.bridgeSchema)
        // The describe command lists itself too.
        #expect(descriptors.contains { $0.name == "__bridge.describe" })
    }
}
