import Foundation
@testable import SwiftPWACLISupport
import Testing
#if canImport(CryptoKit)
    import CryptoKit
#endif

@Suite("iOS device signing")
struct IOSSigningTests {
    private func manifest() -> PWAManifest {
        PWAManifest(
            id: "com.example.sign",
            name: "Sign",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "Sign"),
            macos: nil,
            ios: nil,
            linux: nil
        )
    }

    @Test("a device build with no --sign fails fast before invoking xcodebuild")
    func deviceUnsignedFailsFast() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ios-sign-\(UUID().uuidString)")
        let bundler = IPABundler(
            manifest: manifest(),
            projectRoot: dir,
            outputDir: dir.appendingPathComponent("build"),
            signIdentity: nil,
            simulator: false
        )
        await #expect(throws: BundlerError.self) { _ = try await bundler.build() }
    }

    @Test("the fail-fast message names the signing flags and the simulator escape hatch")
    func failFastMessageGuides() {
        let message = String(describing: BundlerError.iosDeviceUnsigned)
        #expect(message.contains("--sign"))
        #expect(message.contains("--provisioning-profile"))
        #expect(message.contains("--entitlements"))
        #expect(message.contains("--simulator"))
    }

    @Test("the xcodebuild build phase is always unsigned (never passes CODE_SIGN_IDENTITY)")
    func buildPhaseIsUnsigned() {
        // Regression guard: 0.7.0 passed CODE_SIGN_IDENTITY to the build phase,
        // which fails for a SwiftPM-target product without a DEVELOPMENT_TEAM.
        // swift-pwa signs the assembled .app post-assembly, so the build phase
        // must stay unsigned.
        let args = IPABundler.buildPhaseSigningArgs
        #expect(args.contains("CODE_SIGNING_ALLOWED=NO"))
        #expect(args.contains("CODE_SIGNING_REQUIRED=NO"))
        #expect(!args.contains { $0.hasPrefix("CODE_SIGN_IDENTITY") })
    }

    @Test("build parses --provisioning-profile and --entitlements")
    func buildParsesSigningFlags() throws {
        let cmd = try Build.parse([
            "--target", "ios",
            "--sign", "Apple Development: Dev (TEAMID)",
            "--provisioning-profile", "/tmp/app.mobileprovision",
            "--entitlements", "/tmp/app.entitlements"
        ])
        #expect(cmd.sign == "Apple Development: Dev (TEAMID)")
        #expect(cmd.provisioningProfile == "/tmp/app.mobileprovision")
        #expect(cmd.entitlements == "/tmp/app.entitlements")
    }

    // The free-team fix: match the signing identity to the profile's embedded
    // cert (by SHA-1) rather than the team id in the cert's name — because a
    // free personal team's cert CN carries a *different* 10-char id than the
    // profile's TeamIdentifier, so the team-string match misses.
    #if canImport(CryptoKit)
        @Test("identityForProfile matches an identity whose cert the profile authorizes")
        func identityMatchedByProfileCert() {
            let cert = Data("a-fake-DER-cert".utf8)
            let hash = Insecure.SHA1.hash(data: cert).map { String(format: "%02X", $0) }.joined()
            let plist: [String: Any] = ["DeveloperCertificates": [cert]]
            let identities = [
                (hash: "0000000000000000000000000000000000000000", name: "Apple Development: other (AAA)"),
                (hash: hash.lowercased(), name: "Apple Development: me (ABCDE12345)")
            ]
            // find-identity prints the hash uppercase; ours here is lowercase —
            // the match must be case-insensitive (it uppercases both sides).
            #expect(IOSSigning.identityForProfile(plist: plist, identities: identities)
                == "Apple Development: me (ABCDE12345)")
        }

        @Test("identityForProfile returns nil when no installed cert is authorized")
        func identityNoMatch() {
            let plist: [String: Any] = ["DeveloperCertificates": [Data("cert-A".utf8)]]
            let identities = [(hash: "DEADBEEF", name: "Apple Development: unrelated (BBB)")]
            #expect(IOSSigning.identityForProfile(plist: plist, identities: identities) == nil)
            #expect(IOSSigning.identityForProfile(plist: [:], identities: identities) == nil)
        }
    #endif
}
