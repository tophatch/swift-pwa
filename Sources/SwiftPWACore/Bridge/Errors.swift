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
}
