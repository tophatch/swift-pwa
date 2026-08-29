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
///
/// Every case carries the **document epoch** `bridge.js` minted at load (`ep`
/// on the wire). It is `nil` only for a frame synthesized in Swift — nothing
/// on the JS side omits it. See ``InboundFrame/hello(epoch:)`` for what the
/// runtime does with it.
public enum InboundFrame: Sendable, Equatable {
    /// A document announcing that it now owns this window, posted by
    /// `bridge.js` at document start before any of the page's own scripts run.
    ///
    /// This is how a navigation reaches the runtime. A window's `BridgeRuntime`
    /// outlives the documents loaded into it, so without this the streams a
    /// document opened keep running after it is gone — delivering into the
    /// *next* document, against correlation ids it has since reused. Handling
    /// it in Core rather than at each backend's navigation seam is deliberate:
    /// one implementation covers all five, and three of them have no equivalent
    /// of `WKNavigationDelegate` to hang it off anyway.
    case hello(epoch: String)
    case invoke(id: UInt64, command: String, payload: Data, epoch: String?)
    case subscribe(id: UInt64, command: String, payload: Data, epoch: String?)
    case unsubscribe(id: UInt64, epoch: String?)
    /// A client frame pushed *into* an already-open duplex session `id`
    /// (opened via `subscribe` of a `registerSession` command). The command
    /// was fixed at open time, so no `cmd` — just the correlation id and the
    /// frame payload. See `registerSession` / `BridgeInbound`.
    case push(id: UInt64, payload: Data, epoch: String?)

    /// The document that produced this frame.
    public var epoch: String? {
        switch self {
        case let .hello(epoch): epoch
        case let .invoke(_, _, _, epoch), let .subscribe(_, _, _, epoch): epoch
        case let .unsubscribe(_, epoch), let .push(_, _, epoch): epoch
        }
    }
}

public extension InboundFrame {
    /// Epoch-less spellings, for callers that build frames directly (tests, a
    /// custom backend) and have no document to attribute them to.
    static func invoke(id: UInt64, command: String, payload: Data) -> InboundFrame {
        .invoke(id: id, command: command, payload: payload, epoch: nil)
    }

    static func subscribe(id: UInt64, command: String, payload: Data) -> InboundFrame {
        .subscribe(id: id, command: command, payload: payload, epoch: nil)
    }

    static func unsubscribe(id: UInt64) -> InboundFrame {
        .unsubscribe(id: id, epoch: nil)
    }

    static func push(id: UInt64, payload: Data) -> InboundFrame {
        .push(id: id, payload: payload, epoch: nil)
    }
}

/// One frame to be sent to JS over the bridge channel.
///
/// `epoch` is the document that opened the correlation this frame answers, so
/// `bridge.js` can drop a frame produced for a document that has since been
/// navigated away from rather than resolve it against whatever now holds that
/// id.
public enum OutboundFrame: Sendable, Equatable {
    case reply(id: UInt64, ok: Data, epoch: String?)
    case replyError(id: UInt64, error: BridgeError, epoch: String?)
    case event(id: UInt64, chunk: Data, epoch: String?)
    case end(id: UInt64, epoch: String?)

    /// The document this frame is addressed to.
    public var epoch: String? {
        switch self {
        case let .reply(_, _, epoch), let .event(_, _, epoch): epoch
        case let .replyError(_, _, epoch), let .end(_, epoch): epoch
        }
    }
}

public extension OutboundFrame {
    /// Epoch-less spellings, as on `InboundFrame`.
    static func reply(id: UInt64, ok: Data) -> OutboundFrame {
        .reply(id: id, ok: ok, epoch: nil)
    }

    static func replyError(id: UInt64, error: BridgeError) -> OutboundFrame {
        .replyError(id: id, error: error, epoch: nil)
    }

    static func event(id: UInt64, chunk: Data) -> OutboundFrame {
        .event(id: id, chunk: chunk, epoch: nil)
    }

    static func end(id: UInt64) -> OutboundFrame {
        .end(id: id, epoch: nil)
    }
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

    /// Wire key for the document epoch (see ``InboundFrame/hello(epoch:)``).
    /// Short because it rides on every frame in both directions.
    public static let epochKey = "ep"

    /// Decode one inbound frame from the JSON bytes received on the channel.
    public static func decode(_ data: Data) throws -> InboundFrame {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = raw as? [String: Any] else { throw EnvelopeError.notObject }
        guard let v = dict["v"] as? Int else { throw EnvelopeError.missingField("v") }
        guard v == version else { throw EnvelopeError.unsupportedVersion(v) }
        guard let kind = dict["kind"] as? String else { throw EnvelopeError.missingField("kind") }
        let epoch = dict[epochKey] as? String

        if kind == "hello" {
            guard let epoch else { throw EnvelopeError.missingField(epochKey) }
            return .hello(epoch: epoch)
        }

        guard let id = try uint64(dict["id"]) else { throw EnvelopeError.missingField("id") }

        switch kind {
        case "invoke", "subscribe":
            guard let cmd = dict["cmd"] as? String else { throw EnvelopeError.missingField("cmd") }
            let payload = try reserialize(dict["payload"] ?? NSNull())
            return kind == "invoke"
                ? .invoke(id: id, command: cmd, payload: payload, epoch: epoch)
                : .subscribe(id: id, command: cmd, payload: payload, epoch: epoch)
        case "unsubscribe":
            return .unsubscribe(id: id, epoch: epoch)
        case "push":
            let payload = try reserialize(dict["payload"] ?? NSNull())
            return .push(id: id, payload: payload, epoch: epoch)
        default:
            throw EnvelopeError.unknownKind(kind)
        }
    }

    /// Encode one outbound frame as JSON bytes ready for `evaluateJavaScript`.
    public static func encode(_ frame: OutboundFrame) throws -> Data {
        var dict: [String: Any] = ["v": version]
        if let epoch = frame.epoch { dict[epochKey] = epoch }
        switch frame {
        case let .reply(id, ok, _):
            dict["kind"] = "reply"
            dict["id"] = NSNumber(value: id)
            dict["ok"] = try jsonObject(from: ok)
        case let .replyError(id, error, _):
            dict["kind"] = "reply"
            dict["id"] = NSNumber(value: id)
            dict["err"] = ["code": error.code, "message": error.message]
        case let .event(id, chunk, _):
            dict["kind"] = "event"
            dict["id"] = NSNumber(value: id)
            dict["chunk"] = try jsonObject(from: chunk)
        case let .end(id, _):
            dict["kind"] = "end"
            dict["id"] = NSNumber(value: id)
        }
        // `.sortedKeys` is part of the wire contract: `JSONEncoder` does not
        // preserve declaration order for synthesized `CodingKeys` and varies
        // per encode, so identical records reached the page with their fields
        // in different orders and `JSON.stringify(a) === JSON.stringify(b)`
        // — the obvious way to ask "did this change?" — never matched. It is
        // applied here, at the one choke point every backend delivers through,
        // because this re-serialization would otherwise undo a sort done by
        // the handler's own encoder. It sorts nested objects too.
        return try JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed, .sortedKeys])
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
