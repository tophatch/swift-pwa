import Foundation

/// Where the provider should send the user back, and therefore which receiver
/// runs while the consent page is open.
///
/// The two shapes are not interchangeable and the choice is not cosmetic: a
/// provider's *client type* decides which one it will accept. Google's
/// "Desktop app" credentials redirect only to `http://127.0.0.1:<port>/…`;
/// its iOS and Android credentials only to a reverse-DNS custom scheme.
public enum AuthorizationRedirect: Sendable, Equatable {
    /// Loopback on desktop, custom scheme on mobile. See
    /// ``AuthorizationRedirect/resolve(_:platform:)`` for what "auto" can and
    /// can't work out on its own.
    case auto

    /// Bind `127.0.0.1` on an OS-assigned port and serve `path`. The
    /// `redirect_uri` isn't known until the bind succeeds, which is why
    /// ``AuthorizationResult`` carries it back.
    case loopback(path: String)

    /// Catch a custom-scheme callback on the `app.openURL` channel (or, on
    /// Apple, through `ASWebAuthenticationSession`). `uri` is the full
    /// `redirect_uri` sent to the provider; `scheme` is what the callback is
    /// matched on.
    case scheme(String, uri: String)

    /// `loopback` with the conventional path.
    public static var loopback: AuthorizationRedirect {
        .loopback(path: "/callback")
    }

    /// A custom scheme with the conventional path — `<scheme>:/oauth2redirect`,
    /// the spelling Google documents for its iOS and Android client types.
    public static func scheme(_ scheme: String) -> AuthorizationRedirect {
        .scheme(scheme, uri: "\(scheme):/oauth2redirect")
    }

    /// A full redirect URI, with the scheme taken from it. For a provider that
    /// documents a different shape (`myapp://callback`).
    public static func uri(_ uri: String) -> AuthorizationRedirect? {
        guard let scheme = URL(string: uri)?.scheme, !scheme.isEmpty else { return nil }
        return .scheme(scheme, uri: uri)
    }
}

/// Which of the five this build is, for redirect resolution. Read from the
/// compiler rather than passed in, except in tests — the resolution table is
/// the part worth pinning, and it can't be pinned if it can only be evaluated
/// on the platform it describes.
public enum AuthorizationPlatform: Sendable, Equatable {
    case desktop
    case mobile

    /// This build's platform.
    public static var current: AuthorizationPlatform {
        #if os(iOS) || os(Android)
            return .mobile
        #else
            return .desktop
        #endif
    }
}

public extension AuthorizationRedirect {
    /// Resolve ``auto`` for `platform`, or pass an explicit choice through.
    ///
    /// **Desktop → loopback.** It needs nothing registered, which matters most
    /// on a portable Windows `.exe`: a custom scheme there costs the user a
    /// `register-url-schemes.cmd` run *before* they can ever finish signing in,
    /// and there is no way for the app to tell them that at the right moment.
    ///
    /// **Mobile → the scheme the caller gave.** Loopback on iOS and Android is
    /// technically possible and practically wrong — the app is backgrounded
    /// while the browser is in front, which is exactly when the socket has to
    /// answer — and the mobile client types refuse it anyway.
    ///
    /// `auto` on mobile with no scheme is an **error, not a guess**. The
    /// framework genuinely cannot work it out: `pwa.json`'s `url_schemes` is
    /// build-time only (it generates `CFBundleURLTypes`, an `<intent-filter>`,
    /// a `.desktop` handler and Windows registry scripts, and nothing carries
    /// it into the process), and even with that list in hand the right entry is
    /// provider-specific — Google's is the *reversed client ID*, derived from a
    /// value only the caller knows. A wrong guess wouldn't fail here; it would
    /// fail minutes later at the provider's redirect, in a browser, with the
    /// app showing nothing.
    static func resolve(
        _ requested: AuthorizationRedirect,
        platform: AuthorizationPlatform = .current
    ) throws -> AuthorizationRedirect {
        switch requested {
        case .loopback, .scheme:
            return requested
        case .auto:
            switch platform {
            case .desktop:
                return .loopback
            case .mobile:
                throw BridgeError(
                    code: BridgeError.authRedirect,
                    message: "redirect 'auto' can't pick a custom scheme for you on iOS/Android — "
                        + "the provider decides it (Google's is the reversed client ID). Pass "
                        + "`redirect: { scheme: '…' }` (and declare it in pwa.json's `url_schemes`), "
                        + "or `redirect: 'loopback'` if this provider accepts a loopback redirect."
                )
            }
        }
    }
}

/// An authorization-code request, Swift-facing. The JS wire form is translated
/// by `AuthPlugin`; Swift callers running the flow natively build this directly
/// so a token never has to be visible to the page.
public struct AuthorizationRequest: Sendable, Equatable {
    public var authorizationEndpoint: URL
    public var clientId: String
    public var scopes: [String]
    public var redirect: AuthorizationRedirect
    /// Extra query parameters appended verbatim — `access_type=offline`,
    /// `prompt=consent`, `login_hint`, a provider's `audience`. Reserved
    /// parameters the flow owns (`client_id`, `redirect_uri`, `state`,
    /// `code_challenge`, `code_challenge_method`, `response_type`, `scope`)
    /// are refused rather than silently overwritten.
    public var extraParams: [String: String]
    public var timeout: TimeInterval

    public init(
        authorizationEndpoint: URL,
        clientId: String,
        scopes: [String] = [],
        redirect: AuthorizationRedirect = .auto,
        extraParams: [String: String] = [:],
        timeout: TimeInterval = 300
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.clientId = clientId
        self.scopes = scopes
        self.redirect = redirect
        self.extraParams = extraParams
        self.timeout = timeout
    }

    /// Query parameters the flow sets itself; an `extraParams` entry naming one
    /// is a caller bug worth reporting rather than absorbing.
    static let reservedParameters: Set<String> = [
        "client_id", "redirect_uri", "response_type", "scope",
        "state", "code_challenge", "code_challenge_method"
    ]
}

/// What a completed authorization yields.
///
/// `codeVerifier` and `redirectURI` are here because the token exchange needs
/// both and neither is something the caller can reconstruct: the verifier was
/// generated inside the flow, and with loopback the URI isn't known until the
/// OS assigns a port. RFC 6749 §4.1.3 requires the exchange to repeat the
/// redirect URI byte-for-byte, which is the single easiest thing to get wrong
/// by hand.
public struct AuthorizationResult: Sendable, Codable, Equatable {
    public var code: String
    public var codeVerifier: String
    public var redirectURI: String
    public var state: String

    public init(code: String, codeVerifier: String, redirectURI: String, state: String) {
        self.code = code
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier
        case redirectURI = "redirectUri"
        case state
    }
}

/// A token-endpoint request. Only the authorization-code grant, deliberately —
/// see `docs/auth.md` on why refresh isn't here.
public struct TokenExchangeRequest: Sendable, Equatable {
    public var tokenEndpoint: URL
    public var clientId: String
    /// Sent when present. Google's "Desktop app" client type still issues a
    /// `client_secret` that isn't secret (RFC 8252 §8.5 acknowledges this), and
    /// refusing to send one would block the most common provider there is.
    public var clientSecret: String?
    public var code: String
    public var codeVerifier: String
    public var redirectURI: String
    public var extraParams: [String: String]

    public init(
        tokenEndpoint: URL,
        clientId: String,
        clientSecret: String? = nil,
        code: String,
        codeVerifier: String,
        redirectURI: String,
        extraParams: [String: String] = [:]
    ) {
        self.tokenEndpoint = tokenEndpoint
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.code = code
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
        self.extraParams = extraParams
    }
}

/// A token-endpoint response. Every field but `accessToken` is optional because
/// every field but `accessToken` is optional in practice: `refresh_token` only
/// arrives when the request asked for offline access (and, with Google, only on
/// the *first* consent), `id_token` only for OpenID scopes, and `scope` only
/// when the grant differs from what was asked for.
public struct TokenExchangeResult: Sendable, Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    /// Lifetime in seconds, as the provider reported it. Not converted to an
    /// absolute date: the app decides what clock to trust, and a framework that
    /// stamped `expiresAt` from the local clock would be wrong on a device
    /// whose time is off — which is a real state, not a hypothetical.
    public var expiresIn: Int?
    public var tokenType: String?
    public var scope: String?
    public var idToken: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: Int? = nil,
        tokenType: String? = nil,
        scope: String? = nil,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.scope = scope
        self.idToken = idToken
    }
}
