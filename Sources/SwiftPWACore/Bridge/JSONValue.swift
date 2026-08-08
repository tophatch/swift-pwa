import Foundation

/// A loss-less, `Sendable` representation of any JSON value.
///
/// Used inside envelope types to round-trip arbitrary command payloads
/// through `JSONEncoder` / `JSONDecoder` without committing to a static
/// schema.
public indirect enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "value is not valid JSON"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}

public extension JSONValue {
    /// Decode raw UTF-8 JSON bytes into a `JSONValue`. Accepts JSON fragments.
    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Encode this value as raw UTF-8 JSON bytes.
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

public extension JSONValue {
    /// Read a key off an object value, so payload access reads as
    /// `payload?["js"]` instead of a `case .object` dance at every call.
    ///
    /// Lives here rather than beside the driver that first needed it: the agent
    /// surface uses it too and ships in **release** builds, where the driver is
    /// compiled out entirely.
    subscript(key: String) -> JSONValue? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    /// The string members of an array value; anything else is empty. Used for
    /// things like `modifiers`, where a malformed value should mean "none"
    /// rather than failing the whole request.
    var stringArray: [String] {
        guard case let .array(items) = self else { return [] }
        return items.compactMap { if case let .string(value) = $0 { value } else { nil } }
    }
}
