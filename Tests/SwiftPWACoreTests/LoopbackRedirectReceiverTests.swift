import Foundation
@testable import SwiftPWACore
import Testing

/// End-to-end over a **real socket**, not a mock: bind, connect, write an HTTP
/// request, read the response. The point of this receiver is that it works on
/// five platforms' socket APIs, and a fake in front of `LoopbackSocket` would
/// test the one thing that was never in doubt.
///
/// Each test carries its own control — a run that *should* find the code and one
/// that shouldn't — because "nothing arrived" is what both a working drop and a
/// broken listener look like.
@Suite("LoopbackRedirectReceiver")
struct LoopbackRedirectReceiverTests {
    /// Minimal HTTP/1.1 GET over a raw socket, the way a browser issues the
    /// redirect. Returns the full response text.
    @discardableResult
    private func get(port: UInt16, target: String) -> String? {
        LoopbackSocket.startup()
        let socket = LoopbackSocket.makeStreamSocket()
        guard LoopbackSocket.isValid(socket) else { return nil }
        defer { LoopbackSocket.closeSocket(socket) }
        guard LoopbackSocket.connectLoopback(socket, port: port) else { return nil }

        let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        let bytes = Array(request.utf8)
        guard LoopbackSocket.sendAll(socket, bytes, offset: 0, count: bytes.count) else { return nil }

        var response = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while LoopbackSocket.pollReadable(socket, timeoutMs: 3000) > 0 {
            let n = LoopbackSocket.recvInto(socket, &buffer)
            if n <= 0 { break }
            response.append(contentsOf: buffer[0 ..< n])
        }
        return String(decoding: response, as: UTF8.self)
    }

    @Test("a matching redirect resolves, and the browser gets a real page")
    func happyPath() async throws {
        let receiver = try LoopbackRedirectReceiver()
        async let callback = receiver.waitForCallback(state: "s-123", timeout: 5)

        // Give the accept loop a moment to reach its first poll. Not required
        // for correctness — the connection would sit in the backlog — but it
        // keeps a failure here meaning what it says.
        try await Task.sleep(nanoseconds: 100_000_000)
        let response = get(port: receiver.port, target: "/callback?code=abc123&state=s-123")

        let result = try await callback
        #expect(result.parameters["code"] == "abc123")
        #expect(response?.hasPrefix("HTTP/1.1 200 OK") == true)
        // The response has to actually arrive: a receiver that closes the socket
        // with the request's headers still unread sends an RST instead, and the
        // user sees a connection-reset page after a sign-in that worked.
        #expect(response?.contains("You can close this tab") == true)
    }

    @Test("a callback with the wrong state is dropped, and the flow keeps waiting")
    func wrongStateDropped() async throws {
        let receiver = try LoopbackRedirectReceiver()
        async let callback = receiver.waitForCallback(state: "right", timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)

        let refused = get(port: receiver.port, target: "/callback?code=attacker&state=wrong")
        #expect(refused?.hasPrefix("HTTP/1.1 400") == true)

        // The control: the flow is still live, so the real callback still lands.
        let accepted = get(port: receiver.port, target: "/callback?code=real&state=right")
        #expect(accepted?.hasPrefix("HTTP/1.1 200") == true)

        let result = try await callback
        #expect(result.parameters["code"] == "real")
    }

    @Test("a callback with no state at all is dropped too")
    func missingStateDropped() async throws {
        let receiver = try LoopbackRedirectReceiver()
        async let callback = receiver.waitForCallback(state: "right", timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(get(port: receiver.port, target: "/callback?code=bare")?.hasPrefix("HTTP/1.1 400") == true)
        #expect(get(port: receiver.port, target: "/callback?code=real&state=right")?
            .hasPrefix("HTTP/1.1 200") == true)
        #expect(try await callback.parameters["code"] == "real")
    }

    @Test("a stray request on another path 404s without ending the flow")
    func faviconDoesNotEndTheFlow() async throws {
        let receiver = try LoopbackRedirectReceiver()
        async let callback = receiver.waitForCallback(state: "s", timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)

        // What a browser actually does after rendering the success page. A
        // receiver that stopped at the first connection would lose the callback
        // to this roughly as often as it caught it.
        #expect(get(port: receiver.port, target: "/favicon.ico")?.hasPrefix("HTTP/1.1 404") == true)
        #expect(get(port: receiver.port, target: "/callback?code=c&state=s")?.hasPrefix("HTTP/1.1 200") == true)
        #expect(try await callback.parameters["code"] == "c")
    }

    @Test("the provider's error comes back as E_AUTH_DENIED with its description")
    func providerError() async throws {
        let receiver = try LoopbackRedirectReceiver()
        async let callback = receiver.waitForCallback(state: "s", timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        get(port: receiver.port, target: "/callback?error=access_denied&error_description=User%20said%20no&state=s")

        let parameters = try await callback.parameters
        #expect(throws: BridgeError.self) {
            try OAuthAuthorizer.result(
                from: AuthorizationCallback(parameters: parameters),
                verifier: "v", redirectURI: "http://127.0.0.1/cb", state: "s"
            )
        }
        do {
            _ = try OAuthAuthorizer.result(
                from: AuthorizationCallback(parameters: parameters),
                verifier: "v", redirectURI: "http://127.0.0.1/cb", state: "s"
            )
        } catch let error as BridgeError {
            #expect(error.code == BridgeError.authDenied)
            #expect(error.message.contains("User said no"))
        }
    }

    @Test("nothing arriving times out with E_AUTH_TIMEOUT")
    func timesOut() async throws {
        let receiver = try LoopbackRedirectReceiver()
        do {
            _ = try await receiver.waitForCallback(state: "s", timeout: 0.3)
            Issue.record("expected a timeout")
        } catch let error as BridgeError {
            #expect(error.code == BridgeError.authTimeout)
        }
    }

    @Test("the redirect URI names the bound port and the requested path")
    func redirectURIShape() throws {
        let receiver = try LoopbackRedirectReceiver(path: "/oauth")
        defer { receiver.stop() }
        #expect(receiver.port != 0)
        // 127.0.0.1, never `localhost`: the name can resolve to ::1 first, and
        // an IPv4-bound listener then never hears the browser.
        #expect(receiver.redirectURI == "http://127.0.0.1:\(receiver.port)/oauth")
    }

    /// The socket is bound in `init` but closed by the accept loop — so a flow
    /// that fails in between (the browser refuses to open, the external-URL
    /// policy says no) leaks a listening socket per attempt unless `stop()`
    /// closes it itself. The control is the second half: the port must go on to
    /// refuse connections.
    @Test("stopping before the wait starts still closes the socket")
    func stopBeforeAccepting() async throws {
        let receiver = try LoopbackRedirectReceiver()
        let port = receiver.port
        // The control: the port accepts a connection while it is bound.
        // Connect, not GET — nothing is accepting yet, so there would be no
        // response to read either way, and a test that waited for one would
        // fail here for the wrong reason.
        #expect(canConnect(port: port))

        receiver.stop()
        // A `waitForCallback` after `stop()` must not resurrect the listener.
        do {
            _ = try await receiver.waitForCallback(state: "s", timeout: 1)
            Issue.record("expected the stopped receiver to refuse")
        } catch let error as BridgeError {
            #expect(error.code == BridgeError.cancelled)
        }
        #expect(!canConnect(port: port))
    }

    /// Whether anything is listening on `port`.
    private func canConnect(port: UInt16) -> Bool {
        LoopbackSocket.startup()
        let socket = LoopbackSocket.makeStreamSocket()
        guard LoopbackSocket.isValid(socket) else { return false }
        defer { LoopbackSocket.closeSocket(socket) }
        return LoopbackSocket.connectLoopback(socket, port: port)
    }

    @Test("query parsing decodes percent escapes and plus-as-space")
    func queryParsing() {
        let items = LoopbackRedirectReceiver.queryItems(of: "/cb?code=a%2Fb&scope=read+write&empty=&bare")
        #expect(items["code"] == "a/b")
        #expect(items["scope"] == "read write")
        #expect(items["empty"] == "")
        #expect(items["bare"] == "")
    }

    @Test("only GET is treated as a redirect")
    func onlyGET() {
        #expect(LoopbackRedirectReceiver.requestTarget("GET /cb?x=1 HTTP/1.1") == "/cb?x=1")
        #expect(LoopbackRedirectReceiver.requestTarget("POST /cb HTTP/1.1") == nil)
        #expect(LoopbackRedirectReceiver.requestTarget("nonsense") == nil)
    }

    @Test("the header block is recognised in both CRLF and bare-LF spellings")
    func headerTermination() {
        #expect(LoopbackRedirectReceiver.headersComplete(Array("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        #expect(LoopbackRedirectReceiver.headersComplete(Array("GET / HTTP/1.1\nHost: x\n\n".utf8)))
        #expect(!LoopbackRedirectReceiver.headersComplete(Array("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
    }
}
