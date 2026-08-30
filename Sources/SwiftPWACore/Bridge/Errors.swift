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

    /// This build has no codec for the requested source or output format. Kept
    /// distinct from ``image`` because it answers a question the page could
    /// have asked first via `image.info`, and because it is a property of the
    /// platform rather than of the file.
    public static let imageUnsupported = "E_IMAGE_UNSUPPORTED"
}
