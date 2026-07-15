import Foundation

/// A structural description of a JSON-serializable type crossing the bridge —
/// enough to generate a TypeScript interface / Swift struct for it, not a full
/// JSON-Schema validator. It's the unit the typed-codegen layer (roadmap #6)
/// consumes; the bridge itself still validates by decoding, so this is
/// purely for *generating typed clients*, never for runtime enforcement.
///
/// A type advertises its schema by conforming to ``BridgeType``. Types that
/// don't conform degrade to ``BridgeSchema/unknown`` (TS `unknown`), so adoption
/// is incremental — a command is typed exactly as well as its args/result types
/// opt in.
public indirect enum BridgeSchema: Codable, Sendable, Equatable {
    /// No schema available — the type didn't conform to `BridgeType`. Generates
    /// to `unknown` (TS) so a call still type-checks, just without field detail.
    case unknown
    /// No payload at all (`EmptyArgs` / `EmptyResult`).
    case void
    case bool
    case int
    case double
    case string
    /// An optional `T` (a nullable / absent field).
    case optional(BridgeSchema)
    /// A homogeneous array `[T]`.
    case array(BridgeSchema)
    /// A `[String: V]` dictionary (open-keyed object).
    case dictionary(BridgeSchema)
    /// A named struct with ordered fields.
    case object(name: String, fields: [BridgeField])
    /// A string-raw-value enum (`case a, b, c` → a TS string-literal union).
    case stringEnum(name: String, cases: [String])
}

/// One field of a ``BridgeSchema/object(name:fields:)``. Optionality is carried
/// by wrapping `schema` in ``BridgeSchema/optional(_:)`` rather than a flag.
public struct BridgeField: Codable, Sendable, Equatable {
    public let name: String
    public let schema: BridgeSchema

    public init(name: String, schema: BridgeSchema) {
        self.name = name
        self.schema = schema
    }
}

/// How a command is called from JS — the three bridge call shapes. Drives which
/// signature the generated client emits (Promise / unsubscribe fn / session).
public enum CommandKind: String, Codable, Sendable, Equatable {
    /// `invoke` → `Promise<Result>`.
    case unary
    /// `subscribe` → server-streams `Result` chunks.
    case stream
    /// `session` → duplex: client pushes `inbound` frames, server streams `Result`.
    case session
}

/// A single registered command's typed shape, captured at registration time and
/// exposed via `CommandRegistry.descriptors()` / the `__bridge.describe` command.
/// The typed-codegen CLI turns a set of these into a typed client.
public struct CommandDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let kind: CommandKind
    /// The open/args payload shape.
    public let args: BridgeSchema
    /// For `unary`, the return shape; for `stream`/`session`, the downstream
    /// chunk/event shape.
    public let result: BridgeSchema
    /// `session` only: the client→server frame shape pushed via `push`.
    public let inbound: BridgeSchema?

    public init(
        name: String,
        kind: CommandKind,
        args: BridgeSchema,
        result: BridgeSchema,
        inbound: BridgeSchema? = nil
    ) {
        self.name = name
        self.kind = kind
        self.args = args
        self.result = result
        self.inbound = inbound
    }
}

/// A `Codable` type that advertises a ``BridgeSchema`` for typed client codegen.
///
/// Conform your command's args / result / frame structs to opt them into typed
/// bindings. A future `@BridgeType` macro will synthesize `bridgeSchema` from
/// stored properties; until then it's hand-written (or `.unknown` if the type
/// doesn't conform at all).
public protocol BridgeType: Codable, Sendable {
    static var bridgeSchema: BridgeSchema { get }
}

extension EmptyArgs: BridgeType {
    public static var bridgeSchema: BridgeSchema {
        .void
    }
}

extension EmptyResult: BridgeType {
    public static var bridgeSchema: BridgeSchema {
        .void
    }
}
