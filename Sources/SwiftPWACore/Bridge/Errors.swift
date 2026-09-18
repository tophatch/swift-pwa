import Foundation

/// Error that crosses the JS↔Swift bridge. The `code` is a stable
/// string identifier (e.g. `E_NOT_FOUND`) suitable for JS-side switch.
public struct BridgeError: Error, Sendable, Codable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static let notFound = "E_NOT_FOUND"
    public static let decode = "E_DECODE"
    public static let encode = "E_ENCODE"
    public static let handler = "E_HANDLER"
    public static let invalidEnvelope = "E_ENVELOPE"
    public static let cancelled = "E_CANCELLED"
    public static let unimplemented = "E_UNIMPLEMENTED"
    /// A `net.*` request failed — transport error, non-2xx response the caller
    /// asked to treat as fatal, or a checksum mismatch on `net.download`.
    public static let net = "E_NET"

    /// Secure-storage failure (`secrets.*`): the platform store is unavailable,
    /// access was denied, or a read/write failed. A *missing* key is not an
    /// error — `secrets.get` returns `{ value: null }`.
    public static let secrets = "E_SECRETS"

    /// An `image.*` conversion failed — an undecodable file, a bad request
    /// (neither or both of `path` / `dataBase64`), or an I/O error writing the
    /// output.
    public static let image = "E_IMAGE"

    /// `system.openURL` couldn't hand the URL to the OS: an unparseable URL,
    /// a scheme that means something only inside this app (`pwa:`, `file:`,
    /// `javascript:`), or a platform that declined to open it.
    public static let url = "E_URL"

    /// The app hasn't declared this URL scheme, so the runtime refused to hand
    /// it to the OS. Kept distinct from ``url`` because it is the app's own
    /// build-time omission rather than anything about the URL or the machine —
    /// the same distinction `permissions` draws between undeclared and denied.
    public static let urlScheme = "E_URL_SCHEME"

    /// The user dismissed the consent browser (`auth.authorize`). Not a
    /// failure of anything — a page shows its signed-out state and moves on —
    /// which is why it is its own code rather than a generic handler error.
    public static let authCancelled = "E_AUTH_CANCELLED"

    /// No matching callback arrived within the flow's timeout. Distinct from
    /// ``authCancelled`` because the app can't tell whether the user is still
    /// looking at the consent page; a retry is reasonable, a signed-out state
    /// is not.
    public static let authTimeout = "E_AUTH_TIMEOUT"

    /// The provider refused — `error=access_denied`, `invalid_scope`, a
    /// disabled client. The message carries the provider's own
    /// `error_description`, which is the only thing that makes these
    /// diagnosable.
    public static let authDenied = "E_AUTH_DENIED"

    /// A callback came back with a wrong or missing `state`. Only reachable
    /// where the receiver is one-shot (Apple's `ASWebAuthenticationSession`):
    /// the loopback and custom-scheme receivers drop such a callback and keep
    /// waiting, since a mismatch is either an attack or another app's stray
    /// request and neither should end a flow the user is still in.
    public static let authState = "E_AUTH_STATE"

    /// The redirect couldn't be resolved: `auto` on a platform where the
    /// framework can't know the scheme, an unusable redirect URI, or a scheme
    /// this build doesn't register. Raised *before* the browser opens, which is
    /// the point — the alternative surfaces minutes later as a dead redirect.
    public static let authRedirect = "E_AUTH_REDIRECT"

    /// The token endpoint returned a non-2xx or a body without an
    /// `access_token`. Separate from ``net`` because the request itself
    /// succeeded; it is the grant that was refused.
    public static let authToken = "E_AUTH_TOKEN"

    /// This build has no codec for the requested source or output format. Kept
    /// distinct from ``image`` because it answers a question the page could
    /// have asked first via `image.info`, and because it is a property of the
    /// platform rather than of the file.
    public static let imageUnsupported = "E_IMAGE_UNSUPPORTED"
}
