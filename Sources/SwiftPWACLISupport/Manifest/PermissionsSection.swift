import Foundation

public extension PWAManifest {
    /// `pwa.json`'s `permissions` block — the build-time half of the device
    /// surface, and the only half that can reach a *cross-compiled* artifact.
    ///
    /// The runtime ceiling is `ctx.permissions.declare(…)` in Swift. This is
    /// the ceiling baked into the platform artifact: the Android
    /// `uses-permission` entries, the Apple usage-description strings, the MSIX
    /// device capabilities. The two are separate because a build for Android or
    /// iOS can't run the app to ask what it declared — the same limit that
    /// makes `agent.expose` unverifiable when cross-compiling.
    struct PermissionsSection: Codable, Sendable, Equatable {
        /// Permissions a *page* asks for through an ordinary web API. Keyed by
        /// the same names `WebPermission` uses in Swift and `pwa.json`:
        /// `camera`, `microphone`, `geolocation`, `notifications`.
        public var web: WebPermissionDeclarations?

        public init(web: WebPermissionDeclarations? = nil) {
            self.web = web
        }
    }

    /// Accepts a bare list for the simple case and an object when a platform
    /// needs more, the way `window.background_color` takes a hex string *or* a
    /// `{light, dark}` pair:
    ///
    /// ```json
    /// "permissions": { "web": ["microphone", "geolocation"] }
    /// ```
    /// ```json
    /// "permissions": {
    ///   "web": {
    ///     "microphone":  { "reason": "Record a voice note." },
    ///     "geolocation": { "reason": "Show jobs near you." }
    ///   }
    /// }
    /// ```
    ///
    /// The list form can't carry Apple's per-permission purpose strings, which
    /// are mandatory there — so it's shorthand for "no detail needed yet",
    /// not a second way of saying the same thing.
    struct WebPermissionDeclarations: Codable, Sendable, Equatable {
        public struct Detail: Codable, Sendable, Equatable {
            /// The human-readable purpose Apple shows in its system prompt and
            /// requires for App Store review. Emitted as the matching
            /// `NS…UsageDescription`.
            public var reason: String?

            public init(reason: String? = nil) {
                self.reason = reason
            }
        }

        /// Declared names in the order written, so generated artifacts are
        /// stable rather than reordered by a dictionary's hashing.
        public var names: [String]
        public var details: [String: Detail]

        public init(names: [String], details: [String: Detail] = [:]) {
            self.names = names
            self.details = details
        }

        public func detail(for name: String) -> Detail? { details[name] }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([String].self) {
                names = list
                details = [:]
                return
            }
            let object = try container.decode([String: Detail].self)
            // A JSON object has no order, so sort for a stable artifact.
            names = object.keys.sorted()
            details = object
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            if details.isEmpty {
                try container.encode(names)
            } else {
                try container.encode(details)
            }
        }
    }
}
