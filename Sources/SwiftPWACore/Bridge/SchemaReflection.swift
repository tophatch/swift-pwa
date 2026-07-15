import Foundation

/// Derives a ``BridgeSchema`` from a `Codable` type **without a macro** — by
/// decoding a probe instance through a reflecting `Decoder` that records which
/// keys and types the synthesized `init(from:)` asks for. The vast majority of
/// command arg/result types are plain structs of scalars / strings / optionals
/// / arrays / nested structs, and those get a full schema with zero annotation.
///
/// This is invoked **lazily** — only when the catalog is materialized
/// (`CommandRegistry.descriptors()` / `__bridge.describe` / `swift-pwa codegen`),
/// never on the normal command path — so a probe that can't handle a type is
/// harmless: it degrades that type to ``BridgeSchema/unknown`` and normal app
/// startup / dispatch never runs it.
///
/// Not handled by the probe (→ `.unknown`, recover with an explicit
/// ``BridgeType`` conformance): enums, types with a hand-written `init(from:)`
/// that branches on the input, and recursive/cyclic types (bounded by a depth
/// guard). A type that conforms to `BridgeType` short-circuits the probe.
enum SchemaReflection {
    /// The schema for a type: its `BridgeType.bridgeSchema` if it conforms, else
    /// a probe-derived schema, else `.unknown`.
    static func schema(for type: Any.Type) -> BridgeSchema {
        if let bridgeType = type as? any BridgeType.Type { return bridgeType.bridgeSchema }
        return reflect(type, depth: 0)?.schema ?? .unknown
    }

    private static let maxDepth = 12

    /// Returns `(schema, dummy)` where `dummy` is a value of `type` suitable for
    /// satisfying a `decode` call while probing a parent, or `nil` if the type
    /// can't be reflected (caller degrades to `.unknown`).
    static func reflect(_ type: Any.Type, depth: Int) -> (schema: BridgeSchema, dummy: Any)? {
        // An explicit BridgeType conformance wins, but we still need a dummy for
        // the parent probe — only structs we can also instance-construct qualify,
        // so fall through to the structural probe for the dummy and just trust
        // the declared schema. Simpler: honor BridgeType only at the top level
        // (schema(for:)); here we do purely structural reflection.
        switch type {
        case is Bool.Type: return (.bool, false)
        case is String.Type: return (.string, "")
        case is Double.Type: return (.double, Double(0))
        case is Float.Type: return (.double, Float(0))
        case is Int.Type: return (.int, Int(0))
        case is Int8.Type: return (.int, Int8(0))
        case is Int16.Type: return (.int, Int16(0))
        case is Int32.Type: return (.int, Int32(0))
        case is Int64.Type: return (.int, Int64(0))
        case is UInt.Type: return (.int, UInt(0))
        case is UInt8.Type: return (.int, UInt8(0))
        case is UInt16.Type: return (.int, UInt16(0))
        case is UInt32.Type: return (.int, UInt32(0))
        case is UInt64.Type: return (.int, UInt64(0))
        default: break
        }

        if let opt = type as? any _ReflectOptional.Type {
            let inner = reflect(opt._wrappedType, depth: depth + 1)?.schema ?? .unknown
            return (.optional(inner), opt._noneValue)
        }
        if let arr = type as? any _ReflectArray.Type {
            let inner = reflect(arr._elementType, depth: depth + 1)?.schema ?? .unknown
            return (.array(inner), arr._emptyValue)
        }
        if let dict = type as? any _ReflectDictionary.Type, dict._keyIsString {
            let inner = reflect(dict._valueType, depth: depth + 1)?.schema ?? .unknown
            return (.dictionary(inner), dict._emptyValue)
        }
        if let decodable = type as? any Decodable.Type, depth < maxDepth {
            return probeStruct(decodable, depth: depth)
        }
        return nil
    }

    private static func probeStruct(_ type: any Decodable.Type, depth: Int) -> (schema: BridgeSchema, dummy: Any)? {
        let builder = SchemaBuilder()
        let decoder = ProbeDecoder(builder: builder, depth: depth + 1)
        do {
            let instance = try type.init(from: decoder)
            return (.object(name: String(describing: type), fields: builder.fields), instance)
        } catch {
            return nil
        }
    }
}

// MARK: - Container-type markers (extract element/value types + empty dummies)

private protocol _ReflectOptional {
    static var _wrappedType: Any.Type { get }
    static var _noneValue: Any { get }
}

extension Optional: _ReflectOptional {
    static var _wrappedType: Any.Type {
        Wrapped.self
    }
    static var _noneValue: Any {
        Wrapped?.none as Any
    }
}

private protocol _ReflectArray {
    static var _elementType: Any.Type { get }
    static var _emptyValue: Any { get }
}

extension Array: _ReflectArray {
    static var _elementType: Any.Type {
        Element.self
    }
    static var _emptyValue: Any {
        [Element]()
    }
}

private protocol _ReflectDictionary {
    static var _valueType: Any.Type { get }
    static var _keyIsString: Bool { get }
    static var _emptyValue: Any { get }
}

extension Dictionary: _ReflectDictionary {
    static var _valueType: Any.Type {
        Value.self
    }
    static var _keyIsString: Bool {
        Key.self == String.self
    }
    static var _emptyValue: Any {
        [Key: Value]()
    }
}

// MARK: - Reflecting decoder

private final class SchemaBuilder {
    var fields: [BridgeField] = []
    func add(_ name: String, _ schema: BridgeSchema) { fields.append(BridgeField(name: name, schema: schema)) }
}

private enum ProbeError: Error { case unreflectable }

private struct ProbeDecoder: Decoder {
    let builder: SchemaBuilder
    let depth: Int
    var codingPath: [any CodingKey] {
        []
    }
    var userInfo: [CodingUserInfoKey: Any] {
        [:]
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(ProbeKeyed<Key>(builder: builder, depth: depth))
    }

    func unkeyedContainer() -> any UnkeyedDecodingContainer {
        ProbeUnkeyed(depth: depth)
    }

    func singleValueContainer() -> any SingleValueDecodingContainer {
        ProbeSingleValue(depth: depth)
    }
}

private struct ProbeKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let builder: SchemaBuilder
    let depth: Int
    var codingPath: [any CodingKey] {
        []
    }
    var allKeys: [Key] {
        []
    }
    func contains(_: Key) -> Bool { true }

    private func value<T>(_ type: T.Type, key: Key) throws -> T {
        guard let (schema, dummy) = SchemaReflection.reflect(T.self, depth: depth),
              let typed = dummy as? T
        else { throw ProbeError.unreflectable }
        builder.add(key.stringValue, schema)
        return typed
    }

    /// An optional field: record `.optional(wrapped)`, contribute nil. The
    /// synthesized `init(from:)` calls the *non-generic* overload for a scalar
    /// wrapped type (e.g. `decodeIfPresent(String.self, …)`), so every scalar
    /// overload must be implemented — otherwise the protocol-extension default
    /// short-circuits via `contains`/`decodeNil` and the field is dropped.
    private func optional<T>(_: T.Type, key: Key) -> T? {
        let inner = SchemaReflection.reflect(T.self, depth: depth)?.schema ?? .unknown
        builder.add(key.stringValue, .optional(inner))
        return nil
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? { optional(type, key: key) }
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { optional(type, key: key) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { optional(type, key: key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { optional(type, key: key) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { optional(type, key: key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { optional(type, key: key) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { optional(type, key: key) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { optional(type, key: key) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { optional(type, key: key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { optional(type, key: key) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { optional(type, key: key) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { optional(type, key: key) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { optional(type, key: key) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { optional(type, key: key) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { optional(type, key: key) }

    func decodeNil(forKey _: Key) throws -> Bool { true }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try value(type, key: key) }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try value(type, key: key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try value(type, key: key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try value(type, key: key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try value(type, key: key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try value(type, key: key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try value(type, key: key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try value(type, key: key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try value(type, key: key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try value(type, key: key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try value(type, key: key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try value(type, key: key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try value(type, key: key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try value(type, key: key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try value(type, key: key) }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type, forKey _: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(ProbeKeyed<NestedKey>(builder: SchemaBuilder(), depth: depth))
    }

    func nestedUnkeyedContainer(forKey _: Key) throws -> any UnkeyedDecodingContainer { ProbeUnkeyed(depth: depth) }
    func superDecoder() throws -> any Decoder { ProbeDecoder(builder: SchemaBuilder(), depth: depth) }
    func superDecoder(forKey _: Key) throws -> any Decoder { ProbeDecoder(builder: SchemaBuilder(), depth: depth) }
}

/// Yields exactly one element (so an `Array`/collection init probes its element
/// type once) then reports empty.
private final class ProbeUnkeyed: UnkeyedDecodingContainer {
    let depth: Int
    private var yielded = false
    init(depth: Int) { self.depth = depth }

    var codingPath: [any CodingKey] {
        []
    }
    var count: Int? {
        1
    }
    var isAtEnd: Bool {
        yielded
    }
    var currentIndex: Int {
        yielded ? 1 : 0
    }

    private func value<T>(_: T.Type) throws -> T {
        yielded = true
        guard let (_, dummy) = SchemaReflection.reflect(T.self, depth: depth), let typed = dummy as? T
        else { throw ProbeError.unreflectable }
        return typed
    }

    func decodeNil() throws -> Bool { yielded = true; return true }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try value(type) }
    func decode(_ type: Bool.Type) throws -> Bool { try value(type) }
    func decode(_ type: String.Type) throws -> String { try value(type) }
    func decode(_ type: Double.Type) throws -> Double { try value(type) }
    func decode(_ type: Float.Type) throws -> Float { try value(type) }
    func decode(_ type: Int.Type) throws -> Int { try value(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try value(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try value(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try value(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try value(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try value(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try value(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try value(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try value(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try value(type) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy _: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        KeyedDecodingContainer(ProbeKeyed<NestedKey>(builder: SchemaBuilder(), depth: depth))
    }

    func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { ProbeUnkeyed(depth: depth) }
    func superDecoder() throws -> any Decoder { ProbeDecoder(builder: SchemaBuilder(), depth: depth) }
}

private struct ProbeSingleValue: SingleValueDecodingContainer {
    let depth: Int
    var codingPath: [any CodingKey] {
        []
    }

    private func value<T>(_: T.Type) throws -> T {
        guard let (_, dummy) = SchemaReflection.reflect(T.self, depth: depth), let typed = dummy as? T
        else { throw ProbeError.unreflectable }
        return typed
    }

    func decodeNil() -> Bool { true }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try value(type) }
    func decode(_ type: Bool.Type) throws -> Bool { try value(type) }
    func decode(_ type: String.Type) throws -> String { try value(type) }
    func decode(_ type: Double.Type) throws -> Double { try value(type) }
    func decode(_ type: Float.Type) throws -> Float { try value(type) }
    func decode(_ type: Int.Type) throws -> Int { try value(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try value(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try value(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try value(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try value(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try value(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try value(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try value(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try value(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try value(type) }
}
