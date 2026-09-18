import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#elseif canImport(Crypto)
    import Crypto
#endif

/// Proof Key for Code Exchange ([RFC 7636](https://www.rfc-editor.org/rfc/rfc7636))
/// — the verifier/challenge pair that makes an authorization code useless to
/// anyone who intercepts it.
///
/// **Mandatory, not optional.** RFC 8252 requires PKCE for native clients, and
/// the reason is exactly this runtime's situation: on every platform where the
/// redirect comes back over a custom scheme, another locally installed app can
/// register the same scheme and receive the code. Without the verifier, that
/// code is a session. So there is no `plain` method here and no way to turn it
/// off — a caller that could ask for a weaker flow would eventually be a caller
/// that did.
///
/// The hash is available everywhere: CryptoKit on Apple, swift-crypto's
/// `Crypto` on Linux / Windows / Android (declared on `SwiftPWACore` itself in
/// `Package.swift`). An *app* on Windows or Android has no SHA-256 of its own,
/// which is the whole reason this belongs in the framework.
public enum PKCE {
    /// A fresh code verifier: 32 random bytes, base64url-encoded to 43
    /// characters of `[A-Za-z0-9-._~]`. RFC 7636 §4.1 allows 43–128; 43 is the
    /// minimum *and* a full 256 bits of entropy, so a longer one buys nothing.
    public static func makeVerifier() -> String {
        base64URL(randomBytes(32))
    }

    /// The `S256` challenge for `verifier`: `BASE64URL(SHA256(ASCII(verifier)))`.
    ///
    /// Hashes the verifier's **ASCII bytes**, not its UTF-8 re-encoding of some
    /// decoded form — the spec is explicit that the string sent to the
    /// authorization server is what gets hashed, and the two differ the moment
    /// a caller supplies its own verifier containing anything unusual.
    public static func challenge(for verifier: String) -> String {
        base64URL(sha256(Data(verifier.utf8)))
    }

    /// A fresh `state` value: 32 random bytes, base64url. Used to bind the
    /// callback to the request that started it.
    ///
    /// Deliberately not caller-supplied. There is no reason an app would want
    /// to choose this, and every reason it shouldn't be able to — a
    /// constant, a counter, or a reused value all turn `state` into decoration.
    public static func makeState() -> String {
        base64URL(randomBytes(32))
    }

    /// Constant-time string comparison for the `state` check, so a callback
    /// arriving on a shared machine can't be probed a byte at a time.
    ///
    /// The timing channel here is thin — a local attacker would need to drive
    /// the loopback receiver repeatedly within one flow — but the comparison is
    /// three lines either way and the thin version is the one that ages badly.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    // MARK: - Internals

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(count: count)
        for index in 0 ..< count {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return bytes
    }

    /// base64url without padding — RFC 4648 §5, which is what both the verifier
    /// and the challenge are encoded with.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit) || canImport(Crypto)
            return Data(SHA256.hash(data: data))
        #else
            // Unreachable on all five supported platforms — every one of them
            // links CryptoKit or swift-crypto. Kept as a compile-time guard so
            // a sixth platform fails here rather than silently shipping a flow
            // with no proof key at all.
            fatalError("PKCE requires SHA-256, which this build has no crypto module for")
        #endif
    }
}
