import Foundation

/// One JS→Swift command invocation. `payload` is raw UTF-8 JSON bytes;
/// it is *not* `JSONValue` because we want zero-copy when the handler
/// just decodes into its own typed struct.
public struct Invocation: Sendable, Hashable {
    public let id: UInt64
    public let command: String
    public let payload: Data

    public init(id: UInt64, command: String, payload: Data) {
        self.id = id
        self.command = command
        self.payload = payload
    }

    /// Convenience: decode the payload into a typed struct.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

/// Result of dispatching one `Invocation`.
public enum InvocationResult: Sendable {
    /// Single JSON-encoded value, returned as the awaited result on the JS side.
    case ok(Data)
    /// Structured error sent back to JS. The JS-side `invoke()` Promise rejects.
    case failure(BridgeError)
    /// Multi-emit stream (used by `subscribe`). Each `Data` is a JSON-encoded chunk.
    case stream(AsyncThrowingStream<Data, any Error>)
}

// MARK: - Wire envelope

/// One frame received from JS over the bridge channel.
public enum InboundFrame: Sendable, Equatable {
    case invoke(id: UInt64, command: String, payload: Data)
    case subscribe(id: UInt64, command: String, payload: Data)
    case unsubscribe(id: UInt64)
    /// A client frame pushed *into* an already-open duplex session `id`
    /// (opened via `subscribe` of a `registerSession` command). The command
    /// was fixed at open time, so no `cmd` — just the correlation id and the
    /// frame payload. See `registerSession` / `BridgeInbound`.
    case push(id: UInt64, payload: Data)
}

/// One frame to be sent to JS over the bridge channel.
public enum OutboundFrame: Sendable, Equatable {
    case reply(id: UInt64, ok: Data)
    case replyError(id: UInt64, error: BridgeError)
    case event(id: UInt64, chunk: Data)
    case end(id: UInt64)
}

public enum EnvelopeError: Error, Equatable, Sendable {
    case notObject
    case unsupportedVersion(Int)
    case missingField(String)
    case unknownKind(String)
    case malformedPayload
}

public enum Envelope {
    public static let version = 1

    /// Decode one inbound frame from the JSON bytes received on the channel.
    public static func decode(_ data: Data) throws -> InboundFrame {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = raw as? [String: Any] else { throw EnvelopeError.notObject }
        guard let v = dict["v"] as? Int else { throw EnvelopeError.missingField("v") }
        guard v == version else { throw EnvelopeError.unsupportedVersion(v) }
        guard let kind = dict["kind"] as? String else { throw EnvelopeError.missingField("kind") }
        guard let id = try uint64(dict["id"]) else { throw EnvelopeError.missingField("id") }

        switch kind {
        case "invoke", "subscribe":
            guard let cmd = dict["cmd"] as? String else { throw EnvelopeError.missingField("cmd") }
            let payload = try reserialize(dict["payload"] ?? NSNull())
            return kind == "invoke"
                ? .invoke(id: id, command: cmd, payload: payload)
                : .subscribe(id: id, command: cmd, payload: payload)
        case "unsubscribe":
            return .unsubscribe(id: id)
        case "push":
            let payload = try reserialize(dict["payload"] ?? NSNull())
            return .push(id: id, payload: payload)
        default:
            throw EnvelopeError.unknownKind(kind)
        }
    }

    /// Encode one outbound frame as JSON bytes ready for `evaluateJavaScript`.
    public static func encode(_ frame: OutboundFrame) throws -> Data {
        var dict: [String: Any] = ["v": version]
        switch frame {
        case let .reply(id, ok):
            dict["kind"] = "reply"
            dict["id"] = NSNumber(value: id)
            dict["ok"] = try jsonObject(from: ok)
        case let .replyError(id, error):
            dict["kind"] = "reply"
            dict["id"] = NSNumber(value: id)
            dict["err"] = ["code": error.code, "message": error.message]
        case let .event(id, chunk):
            dict["kind"] = "event"
            dict["id"] = NSNumber(value: id)
            dict["chunk"] = try jsonObject(from: chunk)
        case let .end(id):
            dict["kind"] = "end"
            dict["id"] = NSNumber(value: id)
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed])
    }

    // MARK: - helpers

    private static func uint64(_ any: Any?) throws -> UInt64? {
        guard let any else { return nil }
        if let n = any as? NSNumber { return n.uint64Value }
        if let i = any as? Int, i >= 0 { return UInt64(i) }
        return nil
    }

    private static func reserialize(_ any: Any) throws -> Data {
        if any is NSNull {
            return Data("null".utf8)
        }
        return try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
    }

    private static func jsonObject(from data: Data) throws -> Any {
        // `data` is always a complete JSON value (including `null`).
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

// MARK: - Convenience values used by handlers with no args / no result.

public struct EmptyArgs: Sendable, Codable, Equatable {
    public init() {}
}

public struct EmptyResult: Sendable, Codable, Equatable {
    public init() {}
}
