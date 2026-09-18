import Foundation

/// Plugin exposing the `auth.*` command set: open a provider's consent page in
/// the system browser and catch the OAuth redirect back, per platform, with
/// PKCE.
///
/// This is the one step of an OAuth 2.0 authorization-code flow an app in a
/// swift-pwa shell couldn't do for itself. Everything either side of it already
/// exists — `net.*` does the token exchange and every API call after it,
/// CORS-free and with the right TLS stack on Android, and `secrets.*` holds the
/// refresh token — but the middle is per-platform in a way an app shouldn't own,
/// and it is the *same* middle for every app that reaches a cloud API.
///
/// **The page can't just do it in an iframe.** Google, GitHub and Microsoft all
/// refuse to render their consent page inside an embedded webview
/// (`disallowed_useragent`), which is RFC 8252 §8.12 working as intended: an app
/// that hosts the consent page can read the password out of it. So the consent
/// page is the system browser, and the redirect has to cross a process boundary.
///
/// **Opt-in**, registered with the backend's pieces the way `net.*` is:
///
/// ```swift
/// ctx.use(AuthPlugin(
///     urlOpener: AppleURLOpener(),
///     events: ctx.events,
///     networkClient: URLSessionNetworkClient(),
///     presenter: SystemAuthorizationSession()   // Apple only
/// ))
/// ```
///
/// ## Commands
/// - `auth.authorize(AuthorizeArgs)` → ``AuthorizationResult``. Opens the
///   consent page, waits for a redirect whose `state` matches, and returns
///   `{ code, codeVerifier, redirectUri, state }`.
/// - `auth.exchange(TokenExchangeArgs)` → ``TokenExchangeResult``. The
///   form-encoded POST that swaps the code for tokens.
///
/// `codeVerifier` and `redirectUri` come back from `authorize` because the
/// exchange needs both and neither is reconstructable: the verifier was
/// generated inside the flow, and with a loopback redirect the URI isn't known
/// until the OS assigns a port. RFC 6749 §4.1.3 requires the exchange to repeat
/// it byte-for-byte.
///
/// **Nothing is stored.** No token cache, no refresh scheduling, no keychain
/// writes — `secrets.*` is where a refresh token belongs and the app decides
/// that, not the framework.
public struct AuthPlugin: Plugin {
    public static let pluginName = "auth"

    private let networkClient: (any NetworkClient)?
    private let explicit: OAuthAuthorizer?

    /// The one-line registration, and the one that compiles unchanged on all
    /// five platforms:
    ///
    /// ```swift
    /// ctx.use(AuthPlugin(networkClient: URLSessionNetworkClient()))
    /// ```
    ///
    /// The browser and (on Apple) the OS authorization session come from the
    /// backend through ``AppContext/urlOpener`` and
    /// ``AppContext/authorizationSession``, so an adopter never names
    /// `AppleURLOpener` or `GTKURLOpener` — a branch in a shared `main.swift`
    /// is a branch that breaks on the platform its author can't test.
    ///
    /// `networkClient` is still per-platform, because it already is for `net.*`
    /// and for the remote-AI tier: Android's `URLSession` has no injectable CA
    /// trust store, so HTTPS there routes through the Kotlin bridge. Omit it and
    /// `auth.authorize` still works; only `auth.exchange` refuses.
    public init(networkClient: (any NetworkClient)? = nil) {
        self.networkClient = networkClient
        explicit = nil
    }

    /// Register with pieces chosen by hand — a different browser, no OS session
    /// on Apple, or a stub in a test.
    public init(
        urlOpener: (any URLOpener)?,
        events: EventBus,
        networkClient: (any NetworkClient)? = nil,
        presenter: (any AuthorizationSessionPresenter)? = nil
    ) {
        self.networkClient = networkClient
        explicit = OAuthAuthorizer(
            urlOpener: urlOpener,
            events: events,
            networkClient: networkClient,
            presenter: presenter
        )
    }

    /// Register with an authorizer built elsewhere — for an app that runs the
    /// same flow from Swift and from JS backed by one object, so a token can
    /// stay on the native side for the Swift path.
    public init(_ authorizer: OAuthAuthorizer) {
        networkClient = nil
        explicit = authorizer
    }

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let authorizer = explicit ?? OAuthAuthorizer(
            urlOpener: app.urlOpener,
            events: app.events,
            networkClient: networkClient,
            presenter: app.authorizationSession
        )
        let policy = app.externalURLs

        registry.register("auth.authorize", typed: { (args: AuthorizeArgs, ctx) async throws -> AuthorizationResult in
            let request = try args.request()
            // The consent page is handed to the OS, so it goes through the same
            // gate `system.openURL` does. `https` is in `defaultSchemes`, so an
            // ordinary provider needs no declaration — but an app that has
            // locked external URLs down shouldn't find a second way out of
            // itself here.
            switch policy.decide(request.authorizationEndpoint, from: ctx.frame) {
            case .open:
                break
            case .refuse:
                throw BridgeError(
                    code: BridgeError.url,
                    message: "this app's external-URL policy refuses "
                        + "\(request.authorizationEndpoint.scheme ?? "that") sign-in pages"
                )
            }
            return try await authorizer.authorize(request)
        })

        registry.register(
            "auth.exchange",
            typed: { (args: TokenExchangeArgs, _) async throws -> TokenExchangeResult in
                try await authorizer.exchange(args.request())
            }
        )
    }
}

// MARK: - Wire types (JS-facing)

/// How the JS side spells the redirect: `'auto'`, `'loopback'`,
/// `{ scheme: '…' }` or `{ uri: '…' }`.
///
/// A hand-written decoder because it is a union of a string and two object
/// shapes, and because the failure it most needs to produce is a *readable* one
/// — a caller who writes `{ schema: … }` should be told what the field is
/// called, not handed a type-mismatch dump.
public enum AuthorizeRedirectArgs: Sendable, Decodable, Equatable {
    case auto
    case loopback(path: String?)
    case scheme(String)
    case uri(String)

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let word = try? single.decode(String.self) {
            switch word {
            case "auto": self = .auto
            case "loopback": self = .loopback(path: nil)
            default:
                throw BridgeError(
                    code: BridgeError.decode,
                    message: "redirect: \"\(word)\" isn't one of: auto, loopback "
                        + "(or an object: { scheme } / { uri } / { loopback: { path } })"
                )
            }
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let scheme = try keyed.decodeIfPresent(String.self, forKey: .scheme) {
            self = .scheme(scheme)
        } else if let uri = try keyed.decodeIfPresent(String.self, forKey: .uri) {
            self = .uri(uri)
        } else if let path = try keyed.decodeIfPresent(String.self, forKey: .path) {
            self = .loopback(path: path)
        } else {
            throw BridgeError(
                code: BridgeError.decode,
                message: "redirect: expected 'auto', 'loopback', { scheme }, { uri } or { path }"
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case scheme, uri, path }

    /// Translate to the Swift-facing form, rejecting a redirect that can't be
    /// used before anything is opened.
    public func redirect() throws -> AuthorizationRedirect {
        switch self {
        case .auto:
            return .auto
        case let .loopback(path):
            let path = path ?? "/callback"
            guard path.hasPrefix("/") else {
                throw BridgeError(
                    code: BridgeError.authRedirect,
                    message: "redirect path must start with '/' — got \"\(path)\""
                )
            }
            return .loopback(path: path)
        case let .scheme(scheme):
            let bare = scheme.hasSuffix(":") ? String(scheme.dropLast()) : scheme
            guard !bare.isEmpty, !bare.contains("/") else {
                throw BridgeError(
                    code: BridgeError.authRedirect,
                    message: "redirect scheme \"\(scheme)\" isn't a URL scheme — pass { uri } for a full redirect URI"
                )
            }
            return .scheme(bare)
        case let .uri(uri):
            guard let redirect = AuthorizationRedirect.uri(uri) else {
                throw BridgeError(
                    code: BridgeError.authRedirect,
                    message: "redirect uri \"\(uri)\" has no scheme"
                )
            }
            return redirect
        }
    }
}

/// Arguments for `auth.authorize`.
public struct AuthorizeArgs: Sendable, Decodable, Equatable {
    public var authorizationEndpoint: String
    public var clientId: String
    public var scopes: [String]?
    public var redirect: AuthorizeRedirectArgs?
    public var extraParams: [String: String]?
    public var timeoutMs: Int?

    func request() throws -> AuthorizationRequest {
        guard let endpoint = URL(string: authorizationEndpoint), endpoint.scheme?.isEmpty == false else {
            throw BridgeError(
                code: BridgeError.decode,
                message: "authorizationEndpoint isn't a URL: \(authorizationEndpoint)"
            )
        }
        return try AuthorizationRequest(
            authorizationEndpoint: endpoint,
            clientId: clientId,
            scopes: scopes ?? [],
            redirect: (redirect ?? .auto).redirect(),
            extraParams: extraParams ?? [:],
            timeout: timeoutMs.map { Double($0) / 1000.0 } ?? 300
        )
    }
}

/// Arguments for `auth.exchange`.
public struct TokenExchangeArgs: Sendable, Decodable, Equatable {
    public var tokenEndpoint: String
    public var clientId: String
    public var clientSecret: String?
    public var code: String
    public var codeVerifier: String
    public var redirectUri: String
    public var extraParams: [String: String]?

    func request() throws -> TokenExchangeRequest {
        guard let endpoint = URL(string: tokenEndpoint), endpoint.scheme?.isEmpty == false else {
            throw BridgeError(code: BridgeError.decode, message: "tokenEndpoint isn't a URL: \(tokenEndpoint)")
        }
        return TokenExchangeRequest(
            tokenEndpoint: endpoint,
            clientId: clientId,
            clientSecret: clientSecret,
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectUri,
            extraParams: extraParams ?? [:]
        )
    }
}
