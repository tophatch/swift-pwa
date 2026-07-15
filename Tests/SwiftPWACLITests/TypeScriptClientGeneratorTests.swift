import Foundation
@testable import SwiftPWACLISupport
import SwiftPWACore
import Testing

@Suite("TypeScript client generator")
struct TypeScriptClientGeneratorTests {
    private let point = BridgeSchema.object(name: "Point2D", fields: [
        .init(name: "x", schema: .int),
        .init(name: "y", schema: .int)
    ])

    private var moveArgs: BridgeSchema {
        .object(name: "MoveArgs", fields: [
            .init(name: "to", schema: point),
            .init(name: "label", schema: .optional(.string))
        ])
    }

    @Test("unary command emits a typed Promise method + invoke call")
    func unary() {
        let ts = TypeScriptClientGenerator.generate([
            CommandDescriptor(name: "geo.move", kind: .unary, args: moveArgs, result: point)
        ])
        #expect(ts.contains("move: (args: MoveArgs): Promise<Point2D> => raw.invoke(\"geo.move\", args)"))
        // Named types are declared.
        #expect(ts.contains("export interface MoveArgs {"))
        #expect(ts.contains("export interface Point2D {"))
        // Optional field → `?:` with the unwrapped type.
        #expect(ts.contains("label?: string;"))
        #expect(ts.contains("to: Point2D;"))
        // Dotted name nests under a namespace.
        #expect(ts.contains("geo: {"))
    }

    @Test("void args → no parameter; void result → Promise<void>")
    func voidShapes() {
        let ts = TypeScriptClientGenerator.generate([
            CommandDescriptor(name: "app.quit", kind: .unary, args: .void, result: .void)
        ])
        #expect(ts.contains("quit: (): Promise<void> => raw.invoke(\"app.quit\")"))
    }

    @Test("stream command emits subscribe with onChunk/onError/onEnd → Unsubscribe")
    func stream() {
        let ts = TypeScriptClientGenerator.generate([
            CommandDescriptor(name: "geo.track", kind: .stream, args: .void, result: point)
        ])
        #expect(ts.contains("onChunk: (chunk: Point2D) => void"))
        #expect(ts.contains("): Unsubscribe => raw.subscribe(\"geo.track\", onChunk, onError, onEnd)"))
    }

    @Test("session command emits a duplex BridgeSession<Frame>")
    func session() {
        let ts = TypeScriptClientGenerator.generate([
            CommandDescriptor(
                name: "speech.evaluate", kind: .session,
                args: .void, result: .string, inbound: point
            )
        ])
        #expect(ts.contains("handlers: SessionHandlers<string>): BridgeSession<Point2D> =>"))
        #expect(ts.contains("raw.session(\"speech.evaluate\", handlers)"))
    }

    @Test("unknown args → optional unknown param; scalars/arrays/dicts map")
    func scalarsAndContainers() {
        let ts = TypeScriptClientGenerator.generate([
            CommandDescriptor(
                name: "x.mix", kind: .unary,
                args: .unknown,
                result: .object(name: "Mix", fields: [
                    .init(name: "flags", schema: .array(.bool)),
                    .init(name: "meta", schema: .dictionary(.string)),
                    .init(name: "n", schema: .double)
                ])
            )
        ])
        #expect(ts.contains("mix: (args?: unknown): Promise<Mix> => raw.invoke(\"x.mix\", args)"))
        #expect(ts.contains("flags: Array<boolean>;"))
        #expect(ts.contains("meta: Record<string, string>;"))
        #expect(ts.contains("n: number;"))
    }

    @Test("string enum emits a string-literal union")
    func stringEnum() {
        let ts = TypeScriptClientGenerator.generate([
            CommandDescriptor(
                name: "x.pick", kind: .unary, args: .void,
                result: .stringEnum(name: "Color", cases: ["red", "green"])
            )
        ])
        #expect(ts.contains("export type Color = \"red\" | \"green\";"))
        #expect(ts.contains("pick: (): Promise<Color> =>"))
    }

    @Test("generated module is stable across runs (deterministic ordering)")
    func deterministic() {
        let ds = [
            CommandDescriptor(name: "b.two", kind: .unary, args: .void, result: .void),
            CommandDescriptor(name: "a.one", kind: .unary, args: .void, result: .void)
        ]
        #expect(TypeScriptClientGenerator.generate(ds) == TypeScriptClientGenerator.generate(ds.reversed()))
    }
}
