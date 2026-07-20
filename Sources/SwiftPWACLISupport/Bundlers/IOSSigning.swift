import Foundation
#if canImport(CryptoKit)
    import CryptoKit
#endif

/// Resolves iOS signing inputs from a `--team` id, so `swift-pwa build
/// --target ios --team <TEAMID>` can fill in the signing identity,
/// provisioning profile, and entitlements that a device build otherwise needs
/// spelled out via `--sign` / `--provisioning-profile` / `--entitlements`.
///
/// It's a **convenience over the existing manual path**, for a developer who
/// already has Xcode-managed signing set up (i.e. an installed profile for the
/// app's bundle id). It does NOT create a profile from nothing — that needs a
/// generated app-target Xcode project, which a SwiftPM package doesn't have.
/// See docs/ios-setup.md.
///
/// The parsing / matching is split into pure functions so it's unit-testable
/// without a real keychain or on-disk profiles.
enum IOSSigning {
    /// Signing inputs resolved from a team id. Any field may be `nil` if it
    /// couldn't be resolved; the caller only fills gaps the user didn't pass.
    struct Resolved: Equatable {
        var identity: String?
        var profile: URL?
        var entitlements: URL?
    }

    // MARK: - Pure logic (unit-tested)

    /// Parse `security find-identity -v -p codesigning` output into
    /// `(sha1, name)` pairs. Lines look like:
    /// `  1) ABCD…1234 "Apple Development: you@example.com (TEAMID)"`.
    static func parseIdentities(_ output: String) -> [(hash: String, name: String)] {
        var result: [(String, String)] = []
        for line in output.split(separator: "\n") {
            // index) <40-hex> "<name>"
            guard let open = line.firstIndex(of: "\""), line.hasSuffix("\"") else { continue }
            let name = String(line[line.index(after: open) ..< line.index(before: line.endIndex)])
            let prefix = line[line.startIndex ..< open]
                .split(whereSeparator: { $0 == " " || $0 == ")" })
            // prefix is [index, hash]; take the last token that looks like a hash.
            guard let hash = prefix.last.map(String.init), hash.allSatisfy(\.isHexDigit), hash.count >= 16
            else { continue }
            result.append((hash, name))
        }
        return result
    }

    /// Pick the signing identity *name* for `team` — the 10-char id that
    /// appears as `(TEAMID)` in the cert's common name. Prefers an "Apple
    /// Development" identity (the device-development cert) over others.
    static func selectIdentity(team: String, from identities: [(hash: String, name: String)]) -> String? {
        let matches = identities.filter { $0.name.contains("(\(team))") }
        return matches.first(where: { $0.name.hasPrefix("Apple Development") })?.name
            ?? matches.first?.name
    }

    /// The app-id pattern a profile authorizes, with the team prefix stripped:
    /// `<team>.com.example.app` → `com.example.app`, `<team>.*` → `*`.
    static func appIDPattern(team: String, plist: [String: Any]) -> String? {
        guard let ent = plist["Entitlements"] as? [String: Any],
              let appID = ent["application-identifier"] as? String else { return nil }
        let prefix = "\(team)."
        return appID.hasPrefix(prefix) ? String(appID.dropFirst(prefix.count)) : appID
    }

    /// Whether a decoded provisioning-profile plist matches `bundleID` + `team`
    /// and is unexpired as of `now`.
    static func profileMatches(bundleID: String, team: String, plist: [String: Any], now: Date) -> Bool {
        let teams = (plist["TeamIdentifier"] as? [String]) ?? []
        guard teams.contains(team) else { return false }
        if let expiry = plist["ExpirationDate"] as? Date, expiry <= now { return false }
        guard let pattern = appIDPattern(team: team, plist: plist) else { return false }
        if pattern == bundleID { return true }
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") { return bundleID.hasPrefix(String(pattern.dropLast())) }
        return false
    }

    /// Best matching profile among candidates: an exact (non-wildcard) app-id
    /// match wins over a wildcard, then the latest expiration date.
    static func bestProfile(
        bundleID: String, team: String,
        candidates: [(url: URL, plist: [String: Any])], now: Date
    ) -> URL? {
        let matches = candidates.filter { profileMatches(bundleID: bundleID, team: team, plist: $0.plist, now: now) }
        func isExact(_ plist: [String: Any]) -> Bool {
            appIDPattern(team: team, plist: plist) == bundleID
        }
        func expiry(_ plist: [String: Any]) -> Date {
            (plist["ExpirationDate"] as? Date) ?? .distantPast
        }
        return matches.sorted { a, b in
            if isExact(a.plist) != isExact(b.plist) { return isExact(a.plist) }
            return expiry(a.plist) > expiry(b.plist)
        }.first?.url
    }

    /// The `Entitlements` dict embedded in a profile plist.
    static func entitlements(from plist: [String: Any]) -> [String: Any]? {
        plist["Entitlements"] as? [String: Any]
    }

    /// The signing identity to use *for a specific profile* — matched by the
    /// profile's own embedded `DeveloperCertificates` rather than by the team id
    /// in the cert's common name. This is what makes **free personal teams**
    /// work: their "Apple Development" cert's CN carries a *different* 10-char id
    /// than the team id you pass as `--team` (the profile's `TeamIdentifier` and
    /// the id in the authorized cert's `Apple Development: … (XXXXXXXXXX)` name
    /// don't match), so `selectIdentity(team:)` can't find it — but the profile
    /// lists the exact cert that may sign it, so we match on the cert's SHA-1
    /// (which is what `security find-identity` prints as the identity hash).
    static func identityForProfile(
        plist: [String: Any], identities: [(hash: String, name: String)]
    ) -> String? {
        #if canImport(CryptoKit)
            guard let certs = plist["DeveloperCertificates"] as? [Data] else { return nil }
            let profileCertHashes = Set(certs.map(sha1Hex))
            return identities.first { profileCertHashes.contains($0.hash.uppercased()) }?.name
        #else
            return nil
        #endif
    }

    #if canImport(CryptoKit)
        private static func sha1Hex(_ data: Data) -> String {
            Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }
    #endif

    /// Resolve the signing identity for a profile *on disk* — decodes it and
    /// matches its certs against the installed identities. Used after minting a
    /// fresh profile (which `resolve`'s team-string match won't cover for a free
    /// team). Returns `nil` if nothing matches.
    static func identity(forProfileAt url: URL) async -> String? {
        guard let out = try? await Shell.capture(
            "/usr/bin/env", ["security", "find-identity", "-v", "-p", "codesigning"], discardStderr: true
        ),
            let xml = try? await Shell.capture(
                "/usr/bin/env", ["security", "cms", "-D", "-i", url.path], discardStderr: true
            ),
            let plist = try? PropertyListSerialization.propertyList(
                from: Data(xml.utf8), format: nil
            ) as? [String: Any]
        else { return nil }
        return identityForProfile(plist: plist, identities: parseIdentities(out))
    }

    // MARK: - IO

    /// Directories Xcode stores provisioning profiles in (the path moved in
    /// Xcode 16; check both).
    static var profileDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles"),
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
        ]
    }

    /// Resolve missing signing inputs for `team`. Shells out to `security` to
    /// read the keychain identities and decode installed profiles, runs the
    /// pure matchers, and writes the chosen profile's entitlements to
    /// `scratch`. Best-effort: any field that can't be resolved stays `nil`.
    static func resolve(team: String, bundleID: String, scratch: URL, now: Date = Date()) async -> Resolved {
        var resolved = Resolved()

        var parsedIdentities: [(hash: String, name: String)] = []
        if let out = try? await Shell.capture(
            "/usr/bin/env", ["security", "find-identity", "-v", "-p", "codesigning"], discardStderr: true
        ) {
            parsedIdentities = parseIdentities(out)
            resolved.identity = selectIdentity(team: team, from: parsedIdentities)
        }

        var candidates: [(url: URL, plist: [String: Any])] = []
        let fm = FileManager.default
        for dir in profileDirectories {
            for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                where ["mobileprovision", "provisionprofile"].contains(entry.pathExtension)
            {
                guard let xml = try? await Shell.capture(
                    "/usr/bin/env", ["security", "cms", "-D", "-i", entry.path], discardStderr: true
                ),
                    let data = xml.data(using: .utf8),
                    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                candidates.append((entry, plist))
            }
        }

        if let best = bestProfile(bundleID: bundleID, team: team, candidates: candidates, now: now) {
            resolved.profile = best
            let bestPlist = candidates.first(where: { $0.url == best })?.plist
            if let plist = bestPlist, let ent = entitlements(from: plist) {
                let entURL = scratch.appendingPathComponent("swift-pwa-\(bundleID).entitlements")
                if let data = try? PropertyListSerialization.data(fromPropertyList: ent, format: .xml, options: 0) {
                    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                    try? data.write(to: entURL)
                    resolved.entitlements = entURL
                }
            }
            // Free-team fallback: the team-string identity match missed, but the
            // profile names the cert that may sign it — use that.
            if resolved.identity == nil, let plist = bestPlist {
                resolved.identity = identityForProfile(plist: plist, identities: parsedIdentities)
            }
        }

        return resolved
    }
}
