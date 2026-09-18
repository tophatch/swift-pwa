import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - Mocks

/// Records the URL it was asked to open and signals when that happened, so a
/// test can drive the redirect *after* the flow has committed to a redirect URI
/// — which is the only moment the URI is knowable for a loopback flow.
private final class RecordingURLOpener: URLOpener, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []
    private let succeeds: Bool

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func open(_ url: URL) async -> Bool {
        lock.withLock { _opened.append(url) }
        return succeeds
    }

    var opened: [URL] {
        lock.withLock { _opened }
    }

    /// Wait until something has been opened, up to `seconds`.
    func waitForOpen(seconds: Double = 3) async -> URL? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let first = opened.first { return first }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}

private final class StubNetworkClient: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastRequest: NetRequest?
    private let response: NetResponse

    init(_ response: NetResponse) {
        self.response = response
    }

    func send(_ request: NetRequest) async throws -> NetResponse {
        lock.withLock { _lastRequest = request }
        return response
    }

    func download(_: NetDownloadRequest) -> AsyncThrowingStream<NetDownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    var lastRequest: NetRequest? {
        lock.withLock { _lastRequest }
    }
}

private struct StubPresenter: AuthorizationSessionPresenter {
    let callback: String
    /// Stand in for a user who never finishes: the real
    /// `ASWebAuthenticationSession` waits for them forever.
    var neverReturns = false

    func present(authorizationURL _: URL, callbackScheme _: String) async throws -> URL {
        if neverReturns {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        // The state is only knowable from the URL the flow built, so tests that
        // need a matching one build the callback from it.
        return URL(string: callback)!
    }
}

// MARK: - Redirect resolution

@Suite("AuthorizationRedirect")
struct AuthorizationRedirectTests {
    @Test("auto is loopback on desktop")
    func autoDesktop() throws {
        #expect(try AuthorizationRedirect.resolve(.auto, platform: .desktop) == .loopback)
    }

    /// The resolution table is pinned from macOS on purpose: it is a *decision*,
    /// not a platform capability, and a table that can only be evaluated on the
    /// platform it describes is a table nothing checks.
    @Test("auto refuses on mobile rather than guessing a scheme")
    func autoMobile() {
        #expect(throws: BridgeError.self) {
            try AuthorizationRedirect.resolve(.auto, platform: .mobile)
        }
        do {
            _ = try AuthorizationRedirect.resolve(.auto, platform: .mobile)
        } catch let error as BridgeError {
            #expect(error.code == BridgeError.authRedirect)
            // The message has to name both ways out, because the caller hitting
            // this has no way to know which one their provider wants.
            #expect(error.message.contains("scheme"))
            #expect(error.message.contains("loopback"))
        } catch {
            Issue.record("expected a BridgeError")
        }
    }

    @Test("an explicit choice passes through on either platform")
    func explicitPassesThrough() throws {
        for platform in [AuthorizationPlatform.desktop, .mobile] {
            #expect(try AuthorizationRedirect.resolve(.scheme("myapp"), platform: platform)
                == .scheme("myapp", uri: "myapp:/oauth2redirect"))
            #expect(try AuthorizationRedirect.resolve(.loopback, platform: platform) == .loopback)
        }
    }

    @Test("a full redirect uri keeps its own shape")
    func uriForm() {
        #expect(AuthorizationRedirect.uri("myapp://callback") == .scheme("myapp", uri: "myapp://callback"))
        #expect(AuthorizationRedirect.uri("not a url") == nil)
    }
}

// MARK: - URL building

@Suite("Authorization URL")
struct AuthorizationURLTests {
    private func parameters(of url: URL) -> [String: String] {
        LoopbackRedirectReceiver.queryItems(of: url.absoluteString)
    }

    @Test("every required OAuth + PKCE parameter is present")
    func requiredParameters() throws {
        let request = try AuthorizationRequest(
            authorizationEndpoint: #require(URL(string: "https://accounts.example.com/authorize")),
            clientId: "client-1",
            scopes: ["read", "write"]
        )
        let url = try OAuthAuthorizer.authorizationURL(
            request, redirectURI: "http://127.0.0.1:1234/callback", state: "st", verifier: "ver"
        )
        let items = parameters(of: url)
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "client-1")
        #expect(items["redirect_uri"] == "http://127.0.0.1:1234/callback")
        #expect(items["state"] == "st")
        #expect(items["code_challenge"] == PKCE.challenge(for: "ver"))
        #expect(items["code_challenge_method"] == "S256")
        // Space-delimited per RFC 6749, which means percent-encoded on the wire.
        #expect(items["scope"] == "read write")
        #expect(url.absoluteString.contains("scope=read%20write"))
    }

    @Test("no scopes means no scope parameter, rather than an empty one")
    func emptyScopes() throws {
        let request = try AuthorizationRequest(
            authorizationEndpoint: #require(URL(string: "https://example.com/a")),
            clientId: "c"
        )
        let url = try OAuthAuthorizer.authorizationURL(
            request, redirectURI: "http://127.0.0.1:1/cb", state: "s", verifier: "v"
        )
        #expect(parameters(of: url)["scope"] == nil)
    }

    @Test("an endpoint that already has a query keeps it")
    func existingQuery() throws {
        let request = try AuthorizationRequest(
            authorizationEndpoint: #require(URL(string: "https://login.example.com/authorize?tenant=acme")),
            clientId: "c"
        )
        let url = try OAuthAuthorizer.authorizationURL(
            request, redirectURI: "http://127.0.0.1:1/cb", state: "s", verifier: "v"
        )
        let items = parameters(of: url)
        #expect(items["tenant"] == "acme")
        #expect(items["client_id"] == "c")
    }

    @Test("extraParams are appended, and may not overwrite what the flow owns")
    func extraParams() throws {
        let ok = try AuthorizationRequest(
            authorizationEndpoint: #require(URL(string: "https://example.com/a")),
            clientId: "c",
            extraParams: ["access_type": "offline", "prompt": "consent"]
        )
        let url = try OAuthAuthorizer.authorizationURL(
            ok, redirectURI: "http://127.0.0.1:1/cb", state: "s", verifier: "v"
        )
        #expect(parameters(of: url)["access_type"] == "offline")

        // Silently letting a caller overwrite `state` or `code_challenge` would
        // disable the two protections the flow exists to provide.
        #expect(throws: BridgeError.self) {
            try OAuthAuthorizer.validateExtraParams(["state": "mine"])
        }
        #expect(throws: BridgeError.self) {
            try OAuthAuthorizer.validateExtraParams(["code_challenge": "x"])
        }
    }

    @Test("values are percent-encoded strictly, so both platforms spell them alike")
    func strictEncoding() {
        // `+` is legal in a query and read as a space by a form decoder on the
        // other end — the classic mismatch, and the reason this isn't left to
        // Foundation's character sets.
        #expect(OAuthAuthorizer.percentEncode("a+b c/d") == "a%2Bb%20c%2Fd")
        #expect(OAuthAuthorizer.percentEncode("-._~aZ0") == "-._~aZ0")
        #expect(OAuthAuthorizer.percentEncode("ä") == "%C3%A4")
    }
}

// MARK: - Token exchange

@Suite("Token exchange")
struct TokenExchangeTests {
    @Test("a token response maps onto the result")
    func success() throws {
        let body = #"{"access_token":"at","refresh_token":"rt","expires_in":3599,"token_type":"Bearer"}"#
        let result = try OAuthAuthorizer.tokenResult(from: NetResponse(status: 200, body: Data(body.utf8)))
        #expect(result.accessToken == "at")
        #expect(result.refreshToken == "rt")
        #expect(result.expiresIn == 3599)
        #expect(result.tokenType == "Bearer")
    }

    @Test("a refused grant carries the provider's own description")
    func refused() {
        let body = #"{"error":"invalid_grant","error_description":"Code was already redeemed"}"#
        do {
            _ = try OAuthAuthorizer.tokenResult(from: NetResponse(status: 400, body: Data(body.utf8)))
            Issue.record("expected a throw")
        } catch let error as BridgeError {
            #expect(error.code == BridgeError.authToken)
            // Without the description these are undiagnosable: every one of them
            // is a 400 saying `invalid_grant`.
            #expect(error.message.contains("Code was already redeemed"))
        } catch {
            Issue.record("expected a BridgeError")
        }
    }

    @Test("a 200 with no access_token is still a failure")
    func emptyBody() {
        #expect(throws: BridgeError.self) {
            try OAuthAuthorizer.tokenResult(from: NetResponse(status: 200, body: Data("{}".utf8)))
        }
    }

    @Test("the POST is form-encoded with the grant the spec names")
    func requestShape() async throws {
        let client = StubNetworkClient(NetResponse(status: 200, body: Data(#"{"access_token":"at"}"#.utf8)))
        let authorizer = OAuthAuthorizer(urlOpener: nil, events: EventBus(), networkClient: client)
        _ = try await authorizer.exchange(TokenExchangeRequest(
            tokenEndpoint: #require(URL(string: "https://oauth2.example.com/token")),
            clientId: "c",
            code: "the-code",
            codeVerifier: "the-verifier",
            redirectURI: "http://127.0.0.1:99/callback"
        ))
        let request = try #require(client.lastRequest)
        #expect(request.method == "POST")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let form = LoopbackRedirectReceiver.parseFormEncoded(String(decoding: request.body ?? Data(), as: UTF8.self))
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "the-code")
        #expect(form["code_verifier"] == "the-verifier")
        // Byte-for-byte the URI the authorization used — RFC 6749 §4.1.3, and
        // the single easiest thing to get wrong by hand.
        #expect(form["redirect_uri"] == "http://127.0.0.1:99/callback")
        #expect(form["client_secret"] == nil)
    }
}

// MARK: - End-to-end through the plugin

@Suite("AuthPlugin")
@MainActor
struct AuthPluginTests {
    private func dispatch(
        _ app: MockAppContext,
        _ command: String,
        _ payload: String
    ) async -> InvocationResult {
        let invocation = Invocation(id: 1, command: command, payload: Data(payload.utf8))
        return await app.registry.dispatch(
            CommandContext(invocation: invocation, caller: .agent, appContext: app)
        )
    }

    /// A full loopback flow driven through the bridge: the plugin opens a URL,
    /// the test plays the provider by requesting the redirect URI out of it, and
    /// the command answers with the code.
    @Test("auth.authorize runs a loopback flow end to end")
    func loopbackFlow() async throws {
        let app = MockAppContext()
        let opener = RecordingURLOpener()
        app.use(AuthPlugin(urlOpener: opener, events: app.events))

        async let reply = dispatch(app, "auth.authorize", """
        {"authorizationEndpoint":"https://accounts.example.com/auth",
         "clientId":"client-1","scopes":["drive.readonly"],"redirect":"loopback"}
        """)

        let authURL = try #require(await opener.waitForOpen())
        let sent = LoopbackRedirectReceiver.queryItems(of: authURL.absoluteString)
        let redirect = try #require(sent["redirect_uri"])
        let state = try #require(sent["state"])
        #expect(redirect.hasPrefix("http://127.0.0.1:"))

        // Play the provider.
        let port = try #require(UInt16(redirect.split(separator: ":")[2].prefix(while: \.isNumber)))
        _ = RawHTTP.get(port: port, target: "/callback?code=granted&state=\(state)")

        guard case let .ok(data) = await reply else {
            Issue.record("expected ok")
            return
        }
        let result = try JSONDecoder().decode(AuthorizationResult.self, from: data)
        #expect(result.code == "granted")
        #expect(result.redirectURI == redirect)
        #expect(result.state == state)
        // The verifier has to come back: it was generated inside the flow and
        // the exchange can't happen without it.
        #expect(PKCE.challenge(for: result.codeVerifier) == sent["code_challenge"])
    }

    @Test("auth.authorize runs a custom-scheme flow off the app.openURL channel")
    func schemeFlow() async throws {
        let app = MockAppContext()
        let opener = RecordingURLOpener()
        app.use(AuthPlugin(urlOpener: opener, events: app.events))

        async let reply = dispatch(app, "auth.authorize", """
        {"authorizationEndpoint":"https://accounts.example.com/auth",
         "clientId":"c","redirect":{"scheme":"com.example.app"}}
        """)

        let authURL = try #require(await opener.waitForOpen())
        let sent = LoopbackRedirectReceiver.queryItems(of: authURL.absoluteString)
        #expect(sent["redirect_uri"] == "com.example.app:/oauth2redirect")
        let state = try #require(sent["state"])

        // Exactly what a backend does when the OS hands the app a deep link.
        OpenURL.emit(["com.example.app:/oauth2redirect?code=scheme-code&state=\(state)"], on: app.events)

        guard case let .ok(data) = await reply else {
            Issue.record("expected ok")
            return
        }
        #expect(try JSONDecoder().decode(AuthorizationResult.self, from: data).code == "scheme-code")
    }

    /// The scheme receiver subscribes to a channel that replays its last value,
    /// so an app cold-started by a deep link has a stale URL waiting. `state` is
    /// what keeps it harmless — and this is the test that says so.
    @Test("a retained deep link from before the flow doesn't resolve it")
    func staleRetainedDeepLinkIgnored() async {
        let app = MockAppContext()
        let opener = RecordingURLOpener()
        app.use(AuthPlugin(urlOpener: opener, events: app.events))

        OpenURL.emit(["com.example.app:/oauth2redirect?code=stale&state=from-a-previous-launch"], on: app.events)

        async let reply = dispatch(app, "auth.authorize", """
        {"authorizationEndpoint":"https://accounts.example.com/auth",
         "clientId":"c","redirect":{"scheme":"com.example.app"},"timeoutMs":400}
        """)
        _ = await opener.waitForOpen()

        guard case let .failure(error) = await reply else {
            Issue.record("expected the stale link to be ignored and the flow to time out")
            return
        }
        #expect(error.code == BridgeError.authTimeout)
    }

    @Test("a presenter takes over the scheme flow, and a bad state is terminal there")
    func presenterStateMismatch() async {
        let app = MockAppContext()
        let opener = RecordingURLOpener()
        app.use(AuthPlugin(
            urlOpener: opener,
            events: app.events,
            presenter: StubPresenter(callback: "com.example.app:/oauth2redirect?code=c&state=not-ours")
        ))

        let reply = await dispatch(app, "auth.authorize", """
        {"authorizationEndpoint":"https://accounts.example.com/auth",
         "clientId":"c","redirect":{"scheme":"com.example.app"}}
        """)
        guard case let .failure(error) = reply else {
            Issue.record("expected a state mismatch")
            return
        }
        #expect(error.code == BridgeError.authState)
        // A presented session runs the browser itself, so nothing is handed to
        // the URL opener.
        #expect(opener.opened.isEmpty)
    }

    /// `timeoutMs` is documented for every platform, and the presented-session
    /// path is the one with no deadline of its own —
    /// `ASWebAuthenticationSession` waits for the user indefinitely. Honouring
    /// it on three platforms and not the fourth is the kind of gap an adopter
    /// only finds on the platform they can't test.
    @Test("a presented session that never returns still honours timeoutMs")
    func presenterTimesOut() async {
        let app = MockAppContext()
        app.authorizationSession = StubPresenter(callback: "com.example.app:/cb", neverReturns: true)
        app.urlOpener = RecordingURLOpener()
        app.use(AuthPlugin())

        let started = Date()
        let reply = await dispatch(app, "auth.authorize", """
        {"authorizationEndpoint":"https://accounts.example.com/auth",
         "clientId":"c","redirect":{"scheme":"com.example.app"},"timeoutMs":400}
        """)
        guard case let .failure(error) = reply else {
            Issue.record("expected a timeout")
            return
        }
        #expect(error.code == BridgeError.authTimeout)
        // And it fails *at* the timeout, not at the presenter's own 60s — the
        // check that would still pass if the deadline were never applied.
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a backend with no URL opener refuses instead of hanging")
    func noOpener() async {
        let app = MockAppContext()
        app.use(AuthPlugin(urlOpener: nil, events: app.events))
        let reply = await dispatch(app, "auth.authorize", """
        {"authorizationEndpoint":"https://accounts.example.com/auth","clientId":"c","redirect":"loopback"}
        """)
        guard case let .failure(error) = reply else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.code == BridgeError.unimplemented)
    }

    @Test("auth.exchange needs a NetworkClient and says so")
    func exchangeWithoutClient() async {
        let app = MockAppContext()
        app.use(AuthPlugin(urlOpener: RecordingURLOpener(), events: app.events))
        let reply = await dispatch(app, "auth.exchange", """
        {"tokenEndpoint":"https://example.com/t","clientId":"c","code":"x",
         "codeVerifier":"v","redirectUri":"http://127.0.0.1:1/cb"}
        """)
        guard case let .failure(error) = reply else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.code == BridgeError.unimplemented)
    }

    /// The registration an adopter actually writes: no opener named, no
    /// `#if os(…)`. If the backend's pieces ever stop reaching the plugin this
    /// is the test that notices, and the symptom otherwise is a sign-in that
    /// reports `E_UNIMPLEMENTED` on one platform only.
    @Test("the one-line registration picks the browser up from the app context")
    func picksUpPlatformPieces() async throws {
        let app = MockAppContext()
        let opener = RecordingURLOpener()
        app.urlOpener = opener
        app.use(AuthPlugin())

        async let reply = dispatch(app, "auth.authorize", """
        {"authorizationEndpoint":"https://accounts.example.com/auth",
         "clientId":"c","redirect":"loopback","timeoutMs":3000}
        """)
        let authURL = try #require(await opener.waitForOpen())
        let sent = LoopbackRedirectReceiver.queryItems(of: authURL.absoluteString)
        let redirect = try #require(sent["redirect_uri"])
        let port = try #require(UInt16(redirect.split(separator: ":")[2].prefix(while: \.isNumber)))
        _ = RawHTTP.get(port: port, target: "/callback?code=ok&state=\(sent["state"]!)")

        guard case let .ok(data) = await reply else {
            Issue.record("expected ok")
            return
        }
        #expect(try JSONDecoder().decode(AuthorizationResult.self, from: data).code == "ok")
    }

    /// And the control for it: with no opener on the context the same
    /// registration refuses, rather than the previous test passing because
    /// something else opened the URL.
    @Test("with no opener on the context, the same registration refuses")
    func picksUpNothingWhenThereIsNothing() async {
        let app = MockAppContext()
        app.use(AuthPlugin())
        let reply = await dispatch(app, "auth.authorize", """
        {"authorizationEndpoint":"https://accounts.example.com/auth","clientId":"c","redirect":"loopback"}
        """)
        guard case let .failure(error) = reply else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.code == BridgeError.unimplemented)
    }

    @Test("the redirect argument decodes from all four spellings")
    func redirectDecoding() throws {
        func decode(_ json: String) throws -> AuthorizationRedirect {
            try JSONDecoder().decode(AuthorizeRedirectArgs.self, from: Data(json.utf8)).redirect()
        }
        #expect(try decode("\"auto\"") == .auto)
        #expect(try decode("\"loopback\"") == .loopback)
        #expect(try decode(#"{"path":"/oauth"}"#) == .loopback(path: "/oauth"))
        #expect(try decode(#"{"scheme":"myapp:"}"#) == .scheme("myapp", uri: "myapp:/oauth2redirect"))
        #expect(try decode(#"{"uri":"myapp://cb"}"#) == .scheme("myapp", uri: "myapp://cb"))
        #expect(throws: (any Error).self) { try decode("\"nonsense\"") }
        #expect(throws: (any Error).self) { try decode(#"{"scheme":"http://x"}"#) }
    }
}

/// Raw HTTP GET over loopback, shared with the receiver's own suite — a browser
/// issuing the redirect, with no URLSession in the way to behave differently on
/// Darwin and corelibs.
enum RawHTTP {
    @discardableResult
    static func get(port: UInt16, target: String) -> String? {
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
}
