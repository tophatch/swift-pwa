import Foundation
@testable import SwiftPWACore
import Testing

@Suite("Envelope codec")
struct EnvelopeTests {
    @Test("invoke frame round-trips with object payload")
    func decodeInvokeObject() throws {
        let json = #"{"v":1,"kind":"invoke","id":42,"cmd":"window.setTitle","payload":{"title":"hi"}}"#
        let frame = try Envelope.decode(Data(json.utf8))
        #expect(frame == .invoke(id: 42, command: "window.setTitle", payload: Data(#"{"title":"hi"}"#.utf8)))
    }

    @Test("invoke frame supports null payload")
    func decodeInvokeNull() throws {
        let json = #"{"v":1,"kind":"invoke","id":7,"cmd":"window.id","payload":null}"#
        let frame = try Envelope.decode(Data(json.utf8))
        guard case let .invoke(id, cmd, payload) = frame else {
            Issue.record("expected .invoke"); return
        }
        #expect(id == 7)
        #expect(cmd == "window.id")
        #expect(String(data: payload, encoding: .utf8) == "null")
    }

    @Test("subscribe and unsubscribe frames decode correctly")
    func subscribeUnsubscribe() throws {
        let sub = try Envelope
            .decode(Data(#"{"v":1,"kind":"subscribe","id":3,"cmd":"window.subscribe","payload":{}}"#.utf8))
        guard case let .subscribe(id, cmd, _) = sub else {
            Issue.record("expected .subscribe"); return
        }
        #expect(id == 3 && cmd == "window.subscribe")

        let unsub = try Envelope.decode(Data(#"{"v":1,"kind":"unsubscribe","id":3}"#.utf8))
        #expect(unsub == .unsubscribe(id: 3))
    }

    @Test("push frame decodes with payload and no cmd")
    func decodePush() throws {
        let push = try Envelope
            .decode(Data(#"{"v":1,"kind":"push","id":7,"payload":{"pcm":[1,2,3]}}"#.utf8))
        guard case let .push(id, payload) = push else {
            Issue.record("expected .push"); return
        }
        #expect(id == 7)
        let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect((obj?["pcm"] as? [Int]) == [1, 2, 3])
    }

    @Test("push frame supports null payload")
    func decodePushNull() throws {
        let push = try Envelope.decode(Data(#"{"v":1,"kind":"push","id":8}"#.utf8))
        #expect(push == .push(id: 8, payload: Data("null".utf8)))
    }

    @Test("rejects unsupported version")
    func badVersion() {
        #expect(throws: EnvelopeError.unsupportedVersion(2)) {
            try Envelope.decode(Data(#"{"v":2,"kind":"invoke","id":1,"cmd":"x"}"#.utf8))
        }
    }

    @Test("rejects unknown kind")
    func badKind() {
        #expect(throws: EnvelopeError.unknownKind("bogus")) {
            try Envelope.decode(Data(#"{"v":1,"kind":"bogus","id":1}"#.utf8))
        }
    }

    @Test("rejects non-object")
    func notObject() {
        #expect(throws: EnvelopeError.notObject) {
            try Envelope.decode(Data("[]".utf8))
        }
    }

    @Test("reply frame round-trips ok payload")
    func encodeReply() throws {
        let payload = Data(#"{"value":7}"#.utf8)
        let data = try Envelope.encode(.reply(id: 9, ok: payload))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["v"] as? Int == 1)
        #expect(json?["kind"] as? String == "reply")
        #expect(json?["id"] as? UInt64 == 9 || (json?["id"] as? NSNumber)?.uint64Value == 9)
        let ok = json?["ok"] as? [String: Any]
        #expect(ok?["value"] as? Int == 7)
    }

    @Test("reply error encodes code and message")
    func encodeReplyError() throws {
        let err = BridgeError(code: "E_X", message: "oops")
        let data = try Envelope.encode(.replyError(id: 1, error: err))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errBlob = json?["err"] as? [String: Any]
        #expect(errBlob?["code"] as? String == "E_X")
        #expect(errBlob?["message"] as? String == "oops")
    }

    @Test("event and end frames encode")
    func encodeEventEnd() throws {
        let chunkData = Data(#"{"x":1}"#.utf8)
        let event = try Envelope.encode(.event(id: 2, chunk: chunkData))
        let eventDict = try JSONSerialization.jsonObject(with: event) as? [String: Any]
        #expect(eventDict?["kind"] as? String == "event")

        let end = try Envelope.encode(.end(id: 2))
        let endDict = try JSONSerialization.jsonObject(with: end) as? [String: Any]
        #expect(endDict?["kind"] as? String == "end")
    }
}
