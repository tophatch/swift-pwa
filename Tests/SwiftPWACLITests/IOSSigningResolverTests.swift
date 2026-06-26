import Foundation
@testable import SwiftPWACLISupport
import Testing

/// Unit tests for the pure `--team` → signing-inputs matching logic (no
/// keychain / on-disk profiles required).
@Suite("iOS --team signing resolution")
struct IOSSigningResolverTests {
    private let team = "ABCDE12345"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var future: Date {
        now.addingTimeInterval(86400)
    }
    private var past: Date {
        now.addingTimeInterval(-86400)
    }

    private func profile(
        teamIDs: [String]? = nil, appID: String, expiry: Date? = nil
    ) -> [String: Any] {
        var p: [String: Any] = [
            "TeamIdentifier": teamIDs ?? [team],
            "Entitlements": ["application-identifier": appID]
        ]
        if let expiry { p["ExpirationDate"] = expiry }
        return p
    }

    @Test("parseIdentities reads (hash, name) pairs and ignores the footer")
    func parseIdentities() {
        let out = """
          1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Apple Development: dev@example.com (ABCDE12345)"
          2) 1122334455667788990011223344556677889900 "Apple Distribution: Example Inc (ABCDE12345)"
             2 valid identities found
        """
        let ids = IOSSigning.parseIdentities(out)
        #expect(ids.count == 2)
        #expect(ids[0].name == "Apple Development: dev@example.com (ABCDE12345)")
        #expect(ids[1].hash == "1122334455667788990011223344556677889900")
    }

    @Test("selectIdentity prefers Apple Development and matches the team id")
    func selectIdentity() {
        let ids = [
            (hash: "h1", name: "Apple Distribution: Example Inc (ABCDE12345)"),
            (hash: "h2", name: "Apple Development: dev@example.com (ABCDE12345)"),
            (hash: "h3", name: "Apple Development: other@example.com (ZZZZZ99999)")
        ]
        #expect(IOSSigning.selectIdentity(team: team, from: ids) == "Apple Development: dev@example.com (ABCDE12345)")
        #expect(IOSSigning.selectIdentity(team: "NOPE000000", from: ids) == nil)
    }

    @Test("profileMatches honors bundle id, team, wildcard, and expiry")
    func profileMatches() {
        let exact = profile(appID: "\(team).com.example.app", expiry: future)
        #expect(IOSSigning.profileMatches(bundleID: "com.example.app", team: team, plist: exact, now: now))
        #expect(!IOSSigning.profileMatches(bundleID: "com.example.other", team: team, plist: exact, now: now))

        let wildcard = profile(appID: "\(team).*", expiry: future)
        #expect(IOSSigning.profileMatches(bundleID: "com.anything.here", team: team, plist: wildcard, now: now))

        let wrongTeam = profile(teamIDs: ["ZZZZZ99999"], appID: "ZZZZZ99999.com.example.app", expiry: future)
        #expect(!IOSSigning.profileMatches(bundleID: "com.example.app", team: team, plist: wrongTeam, now: now))

        let expired = profile(appID: "\(team).com.example.app", expiry: past)
        #expect(!IOSSigning.profileMatches(bundleID: "com.example.app", team: team, plist: expired, now: now))
    }

    @Test("bestProfile prefers an exact match over a wildcard")
    func bestProfilePrefersExact() {
        let wildcardURL = URL(fileURLWithPath: "/tmp/wild.mobileprovision")
        let exactURL = URL(fileURLWithPath: "/tmp/exact.mobileprovision")
        let candidates = [
            (url: wildcardURL, plist: profile(appID: "\(team).*", expiry: future)),
            (url: exactURL, plist: profile(appID: "\(team).com.example.app", expiry: future))
        ]
        #expect(IOSSigning
            .bestProfile(bundleID: "com.example.app", team: team, candidates: candidates, now: now) == exactURL)
    }

    @Test("bestProfile picks the latest expiry among equal-specificity matches")
    func bestProfilePrefersLatest() {
        let soonURL = URL(fileURLWithPath: "/tmp/soon.mobileprovision")
        let laterURL = URL(fileURLWithPath: "/tmp/later.mobileprovision")
        let candidates = [
            (url: soonURL, plist: profile(appID: "\(team).com.example.app", expiry: future)),
            (
                url: laterURL,
                plist: profile(appID: "\(team).com.example.app", expiry: future.addingTimeInterval(1_000_000))
            )
        ]
        #expect(IOSSigning
            .bestProfile(bundleID: "com.example.app", team: team, candidates: candidates, now: now) == laterURL)
    }

    @Test("build parses --team")
    func buildParsesTeam() throws {
        let cmd = try Build.parse(["--target", "ios", "--team", "ABCDE12345"])
        #expect(cmd.team == "ABCDE12345")
    }
}
