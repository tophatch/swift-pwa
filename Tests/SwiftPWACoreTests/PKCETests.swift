import Foundation
@testable import SwiftPWACore
import Testing

@Suite("PKCE")
struct PKCETests {
    /// The worked example from RFC 7636 Appendix B. It is the one thing in this
    /// flow with an official test vector, and getting the challenge wrong fails
    /// at the *token exchange* — long after the browser closed, with the
    /// provider reporting only `invalid_grant`.
    @Test("S256 challenge matches RFC 7636 appendix B")
    func rfcVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("a generated verifier is 43 unreserved characters")
    func verifierShape() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for _ in 0 ..< 32 {
            let verifier = PKCE.makeVerifier()
            #expect(verifier.count == 43)
            #expect(verifier.allSatisfy(allowed.contains))
        }
    }

    @Test("verifiers and states don't repeat")
    func distinct() {
        let verifiers = Set((0 ..< 64).map { _ in PKCE.makeVerifier() })
        let states = Set((0 ..< 64).map { _ in PKCE.makeState() })
        #expect(verifiers.count == 64)
        #expect(states.count == 64)
    }

    @Test("base64url drops padding and the two unsafe characters")
    func base64URLShape() {
        // 0xFB 0xFF encodes as "+/8=" in standard base64 — one of each
        // substitution plus padding, which is the case that catches a
        // half-applied conversion.
        #expect(PKCE.base64URL(Data([0xFB, 0xFF])) == "-_8")
    }

    @Test("constant-time compare still compares")
    func constantTime() {
        #expect(PKCE.constantTimeEquals("abc", "abc"))
        #expect(!PKCE.constantTimeEquals("abc", "abd"))
        #expect(!PKCE.constantTimeEquals("abc", "abcd"))
        #expect(PKCE.constantTimeEquals("", ""))
    }
}
