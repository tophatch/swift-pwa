import Foundation

/// The OS's own authorization browser, where a platform has one.
///
/// Apple does: `ASWebAuthenticationSession` puts the consent page, the
/// custom-scheme callback and cancellation in a single object, and shows the
/// "Do you want to allow … to sign in?" prompt that decides whether the session
/// shares Safari's cookies — which is the difference between an
/// already-signed-in user tapping once and typing a password again.
///
/// Injected the way ``URLOpener`` and ``BiometricAuth`` are: `SwiftPWAWebKit`
/// supplies one, and the platforms with no equivalent supply none and fall back
/// to opening the default browser plus ``SchemeRedirectReceiver``. Android's
/// nearest equivalent is Custom Tabs, which needs `androidx.browser` — a runtime
/// dependency for a nicer-looking browser launch, which isn't a trade this
/// project makes.
///
/// **Scheme callbacks only.** `ASWebAuthenticationSession` cannot call back to
/// an `http://127.0.0.1` redirect, so a desktop build in loopback mode uses the
/// default browser even on a Mac. That is the right way round: a desktop client
/// type wants loopback anyway, and an iOS build wants the session.
public protocol AuthorizationSessionPresenter: Sendable {
    /// Present the authorization page and return the callback URL the OS
    /// redirected to.
    ///
    /// - Throws: `BridgeError(code: .authCancelled)` when the user dismisses it.
    func present(authorizationURL: URL, callbackScheme: String) async throws -> URL
}

/// Runs an OAuth 2.0 authorization-code flow with PKCE, and exchanges the code.
///
/// The Swift-facing half of `auth.*`. An app that runs the flow from here
/// instead of from JS gets the same behaviour with the tokens never becoming
/// visible to the page — which, with ``SecretStore`` on the other side, is the
/// arrangement worth aiming for.
public final class OAuthAuthorizer: Sendable {
    private let urlOpener: (any URLOpener)?
    private let events: EventBus
    private let networkClient: (any NetworkClient)?
    private let presenter: (any AuthorizationSessionPresenter)?
    private let platform: AuthorizationPlatform

    /// - Parameters:
    ///   - urlOpener: how a URL reaches the system browser. `nil` makes
    ///     ``authorize(_:)`` refuse with `E_UNIMPLEMENTED` rather than appear to
    ///     work on a backend that has no opener.
    ///   - events: the app-wide bus, for the custom-scheme receiver.
    ///   - networkClient: the transport for ``exchange(_:)`` — the same one
    ///     `net.*` uses, so Android gets its Kotlin TLS bridge.
    ///   - presenter: the OS authorization session, where the platform has one.
    ///   - platform: which redirect ``AuthorizationRedirect/auto`` resolves to.
    ///     Defaults to this build's; overridable so the resolution table can be
    ///     tested somewhere other than the platform it describes.
    public init(
        urlOpener: (any URLOpener)?,
        events: EventBus,
        networkClient: (any NetworkClient)? = nil,
        presenter: (any AuthorizationSessionPresenter)? = nil,
        platform: AuthorizationPlatform = .current
    ) {
        self.urlOpener = urlOpener
        self.events = events
        self.networkClient = networkClient
        self.presenter = presenter
        self.platform = platform
    }

    // MARK: - Authorize

    /// Open the provider's consent page and wait for the redirect.
    ///
    /// The receiver is started **before** the browser opens. A provider that
    /// redirects immediately — an already-consented user, `prompt=none` — can
    /// otherwise beat the listener to the socket, and that race only shows up on
    /// the second sign-in of a session, which is a miserable bug to be handed.
    public func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationResult {
        try Self.validateExtraParams(request.extraParams)
        let redirect = try AuthorizationRedirect.resolve(request.redirect, platform: platform)
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeState()

        switch redirect {
        case .auto:
            // `resolve` returns only the two concrete cases.
            throw BridgeError(code: BridgeError.authRedirect, message: "unresolved redirect")

        case let .loopback(path):
            let receiver = try LoopbackRedirectReceiver(path: path)
            defer { receiver.stop() }
            let url = try Self.authorizationURL(
                request, redirectURI: receiver.redirectURI, state: state, verifier: verifier
            )
            try await open(url)
            let callback = try await receiver.waitForCallback(state: state, timeout: request.timeout)
            return try Self.result(
                from: callback, verifier: verifier, redirectURI: receiver.redirectURI, state: state
            )

        case let .scheme(scheme, uri):
            let url = try Self.authorizationURL(request, redirectURI: uri, state: state, verifier: verifier)
            if let presenter {
                let callbackURL = try await Self.withTimeout(request.timeout) {
                    try await presenter.present(authorizationURL: url, callbackScheme: scheme)
                }
                let parameters = SchemeRedirectReceiver.queryItems(of: callbackURL.absoluteString)
                // A one-shot session has nothing left to wait on, so a `state`
                // mismatch here is terminal — unlike the two receivers, which
                // drop the callback and keep waiting.
                guard let received = parameters["state"], PKCE.constantTimeEquals(received, state) else {
                    throw BridgeError(
                        code: BridgeError.authState,
                        message: "the sign-in came back with a state that doesn't match the request"
                    )
                }
                return try Self.result(
                    from: AuthorizationCallback(parameters: parameters),
                    verifier: verifier, redirectURI: uri, state: state
                )
            }
            let receiver = SchemeRedirectReceiver(events: events, state: state)
            defer { receiver.stop() }
            try await open(url)
            let callback = try await receiver.waitForCallback(timeout: request.timeout)
            return try Self.result(from: callback, verifier: verifier, redirectURI: uri, state: state)
        }
    }

    /// Run `body`, failing with `E_AUTH_TIMEOUT` if it hasn't finished in
    /// `timeout` seconds.
    ///
    /// The presented-session path needs this spelled out because, unlike the two
    /// receivers, it has no deadline of its own — `ASWebAuthenticationSession`
    /// waits for the user forever. Without it `timeoutMs` would be documented
    /// for every platform and honoured on three, which is the kind of gap an
    /// adopter finds only on the platform they can't test. Cancelling the group
    /// cancels the presenter's task, which dismisses the sheet.
    static func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                throw BridgeError(
                    code: BridgeError.authTimeout,
                    message: "the sign-in wasn't completed within the timeout"
                )
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw BridgeError(code: BridgeError.authTimeout, message: "the sign-in ended with no callback")
            }
            return first
        }
    }

    private func open(_ url: URL) async throws {
        guard let urlOpener else {
            throw BridgeError(
                code: BridgeError.unimplemented,
                message: "this backend can't open a browser, so it can't run a sign-in flow"
            )
        }
        guard await urlOpener.open(url) else {
            throw BridgeError(
                code: BridgeError.authRedirect,
                message: "the system wouldn't open a browser for the sign-in page"
            )
        }
    }

    // MARK: - Exchange

    /// Swap an authorization code for tokens.
    ///
    /// One form-encoded POST. It is in the framework because it is the same POST
    /// for every provider and the same nine lines in every app — and because an
    /// app running the flow from Swift can then put the result straight into a
    /// ``SecretStore`` without a token ever reaching the page.
    public func exchange(_ request: TokenExchangeRequest) async throws -> TokenExchangeResult {
        guard let networkClient else {
            throw BridgeError(
                code: BridgeError.unimplemented,
                message: "auth.exchange needs a NetworkClient — register AuthPlugin with one"
            )
        }
        var form: [String: String] = [
            "grant_type": "authorization_code",
            "code": request.code,
            "code_verifier": request.codeVerifier,
            "redirect_uri": request.redirectURI,
            "client_id": request.clientId
        ]
        if let secret = request.clientSecret { form["client_secret"] = secret }
        for (name, value) in request.extraParams { form[name] = value }

        let response = try await networkClient.send(NetRequest(
            method: "POST",
            url: request.tokenEndpoint,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json"
            ],
            body: Data(Self.formEncode(form).utf8)
        ))
        return try Self.tokenResult(from: response)
    }

    static func tokenResult(from response: NetResponse) throws -> TokenExchangeResult {
        struct Body: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Int?
            let token_type: String?
            let scope: String?
            let id_token: String?
            let error: String?
            let error_description: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: response.body)

        guard response.isSuccess else {
            // The provider's own `error_description` is the only part of this
            // that is ever diagnosable, so it goes in the message rather than
            // being flattened into "the request failed".
            let detail = [body?.error, body?.error_description]
                .compactMap(\.self)
                .joined(separator: ": ")
            throw BridgeError(
                code: BridgeError.authToken,
                message: detail.isEmpty
                    ? "the token endpoint answered \(response.status)"
                    : "the token endpoint refused the grant (\(response.status)): \(detail)"
            )
        }
        guard let body, let accessToken = body.access_token else {
            throw BridgeError(
                code: BridgeError.authToken,
                message: "the token endpoint answered \(response.status) with no access_token"
            )
        }
        return TokenExchangeResult(
            accessToken: accessToken,
            refreshToken: body.refresh_token,
            expiresIn: body.expires_in,
            tokenType: body.token_type,
            scope: body.scope,
            idToken: body.id_token
        )
    }

    // MARK: - URL building

    static func validateExtraParams(_ extraParams: [String: String]) throws {
        let clashes = extraParams.keys
            .filter(AuthorizationRequest.reservedParameters.contains)
            .sorted()
        guard clashes.isEmpty else {
            throw BridgeError(
                code: BridgeError.decode,
                message: "extraParams may not set \(clashes.joined(separator: ", ")) — the flow owns those"
            )
        }
    }

    static func authorizationURL(
        _ request: AuthorizationRequest,
        redirectURI: String,
        state: String,
        verifier: String
    ) throws -> URL {
        var parameters: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", request.clientId),
            ("redirect_uri", redirectURI),
            ("state", state),
            ("code_challenge", PKCE.challenge(for: verifier)),
            ("code_challenge_method", "S256")
        ]
        // Omitted entirely when empty rather than sent as `scope=`: some
        // providers treat an empty scope as a request for none and others as a
        // malformed request, and neither is what a caller that passed no scopes
        // meant.
        if !request.scopes.isEmpty {
            parameters.append(("scope", request.scopes.joined(separator: " ")))
        }
        for (name, value) in request.extraParams.sorted(by: { $0.key < $1.key }) {
            parameters.append((name, value))
        }

        let query = parameters
            .map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }
            .joined(separator: "&")
        // An endpoint that already carries a query keeps it — a few providers
        // document one (a tenant id, an `audience`), and dropping it would make
        // the request fail at the provider with nothing to point at.
        let base = request.authorizationEndpoint.absoluteString
        let separator = base.contains("?") ? "&" : "?"
        guard let url = URL(string: base + separator + query) else {
            throw BridgeError(
                code: BridgeError.authRedirect,
                message: "couldn't build an authorization URL from \(base)"
            )
        }
        return url
    }

    static func formEncode(_ fields: [String: String]) -> String {
        fields
            .sorted(by: { $0.key < $1.key })
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
    }

    /// Percent-encode everything outside RFC 3986's *unreserved* set.
    ///
    /// Hand-rolled rather than `addingPercentEncoding(withAllowedCharacters:)`
    /// because the character-set spellings differ between Darwin Foundation and
    /// swift-corelibs at exactly the awkward edges (`+` in a query value is the
    /// classic one: legal in a URL, and read as a space by a form decoder on the
    /// other end). Encoding strictly is correct everywhere and identical
    /// everywhere, which matters more here than brevity — a `redirect_uri` that
    /// encodes differently on two platforms fails the exchange's byte-for-byte
    /// comparison and nothing says why.
    static func percentEncode(_ value: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    // MARK: - Callback → result

    static func result(
        from callback: AuthorizationCallback,
        verifier: String,
        redirectURI: String,
        state: String
    ) throws -> AuthorizationResult {
        if let error = callback.parameters["error"] {
            let description = callback.parameters["error_description"]
            // `access_denied` included: the user pressing "Deny" on the consent
            // screen is a decision the app should show, not the same event as
            // dismissing the browser window (`E_AUTH_CANCELLED`), which tells
            // it nothing about what the user wants.
            throw BridgeError(
                code: BridgeError.authDenied,
                message: description.map { "\(error): \($0)" } ?? error
            )
        }
        guard let code = callback.parameters["code"], !code.isEmpty else {
            throw BridgeError(
                code: BridgeError.authDenied,
                message: "the redirect carried neither a code nor an error"
            )
        }
        return AuthorizationResult(code: code, codeVerifier: verifier, redirectURI: redirectURI, state: state)
    }
}
