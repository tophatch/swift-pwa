import Foundation

/// On-disk schema for `pwa.json`. The single source of truth; all
/// platform-specific manifests (Info.plist, .desktop, AndroidManifest)
/// are *generated* from this file.
public struct PWAManifest: Codable, Sendable, Equatable {
    public var id: String // reverse-DNS, e.g. "com.example.hello"
    public var name: String // human-readable name
    public var version: String // e.g. "1.0.0"
    public var description: String?
    public var icon: String? // path to a 1024x1024 PNG, optional
    public var web: WebSection
    public var window: WindowSection
    public var macos: MacOSSection?
    public var ios: IOSSection?
    public var linux: LinuxSection?
    public var updater: UpdaterSection?

    public struct WebSection: Codable, Sendable, Equatable {
        public var directory: String // path relative to project root
        public var entry: String // default "index.html"
        public init(directory: String, entry: String = "index.html") {
            self.directory = directory
            self.entry = entry
        }
    }

    public struct WindowSection: Codable, Sendable, Equatable {
        public var title: String
        public var width: Double
        public var height: Double
        public var resizable: Bool
        public var fullscreen: Bool
        public init(
            title: String,
            width: Double = 1024,
            height: Double = 768,
            resizable: Bool = true,
            fullscreen: Bool = false
        ) {
            self.title = title
            self.width = width
            self.height = height
            self.resizable = resizable
            self.fullscreen = fullscreen
        }
    }

    public struct MacOSSection: Codable, Sendable, Equatable {
        public var bundleIdentifier: String? // defaults to top-level `id`
        public var category: String? // LSApplicationCategoryType
        public var minimumSystemVersion: String? // e.g. "15.0"
        public var copyright: String? // NSHumanReadableCopyright; shown under the version in the About panel
    }

    public struct IOSSection: Codable, Sendable, Equatable {
        public var bundleIdentifier: String?
        public var minimumSystemVersion: String? // e.g. "18.0"
    }

    public struct LinuxSection: Codable, Sendable, Equatable {
        public var desktopCategories: [String]? // e.g. ["Utility"]
        public var executableName: String? // defaults to top-level `id` last component
    }

    /// Auto-updater configuration. Optional — apps that don't ship
    /// in-app updates (e.g. App Store / Mac App Store distribution,
    /// Microsoft Store MSIX) leave this section out. The runtime side
    /// (`UpdaterPlugin` + a backend `Updater`) is opt-in regardless;
    /// this section primarily configures the *publishing* side (CLI
    /// manifest signing, planned in v0.4) and documents the runtime's
    /// expected wiring.
    ///
    /// Example:
    /// ```json
    /// "updater": {
    ///   "endpoint": "https://updates.example.com/{{target}}/{{current_version}}",
    ///   "public_key": "RWQf6...",
    ///   "pubkey_algorithm": "ed25519",
    ///   "auto_check": true,
    ///   "check_interval_seconds": 21600,
    ///   "windows": { "install_mode": "passive" },
    ///   "linux":   { "appimage_strategy": "in_place" }
    /// }
    /// ```
    public struct UpdaterSection: Codable, Sendable, Equatable {
        /// HTTPS URL of the JSON manifest endpoint. May contain
        /// `{{target}}` and `{{current_version}}` placeholders.
        public var endpoint: String

        /// Base64 of the raw 32-byte Ed25519 public key. Required for
        /// macOS / Windows / Linux backends; ignored on iOS (where
        /// `itms-services://` validates the .ipa via Apple's signing
        /// chain). Minisign-format key parsing is a planned follow-up.
        public var publicKey: String?

        /// Signature algorithm. Only `"ed25519"` is supported today;
        /// the field exists so the schema can extend without a
        /// breaking change.
        public var pubkeyAlgorithm: String?

        /// Whether the runtime should poll on its own. Defaults to
        /// false — most apps want to drive checks from a menu item or
        /// foregrounding event rather than a timer.
        public var autoCheck: Bool?

        /// Polling cadence when `auto_check` is true.
        public var checkIntervalSeconds: Int?

        public var windows: WindowsUpdater?
        public var linux: LinuxUpdater?

        public struct WindowsUpdater: Codable, Sendable, Equatable {
            /// `"passive"` (no UI, no reboot prompts; default) or
            /// `"silent"` (no UI at all). Reserved for the Windows
            /// updater backend (pending in v0.4).
            public var installMode: String?
        }

        public struct LinuxUpdater: Codable, Sendable, Equatable {
            /// `"in_place"` (atomic-rename onto the running AppImage's
            /// path; default) or `"side_by_side"` (write next to the
            /// running AppImage and let the launcher pick it up next
            /// time). Reserved for the Linux updater backend (pending
            /// in v0.4).
            public var appimageStrategy: String?
        }
    }

    public static func load(from url: URL) throws -> PWAManifest {
        // `Data(contentsOf: fileURL)` is unreliable on swift-corelibs-
        // foundation under Windows: the file URL is routed through a
        // URL-loading path that returns NSCocoaError 260 ("file
        // doesn't exist") even when the file does exist. Read via
        // path string for `file://` URLs to go straight through
        // `CreateFileW` / `fopen` — works identically on every host.
        // (Apple Foundation's `Data(contentsOf:)` is fine, but
        // routing the same way there too keeps the behavior uniform.)
        let data: Data
        if url.isFileURL {
            guard let bytes = FileManager.default.contents(atPath: url.path) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: 260,
                    userInfo: [
                        NSFilePathErrorKey: url.path,
                        NSLocalizedDescriptionKey: "Couldn't read pwa.json at \(url.path)"
                    ]
                )
            }
            data = bytes
        } else {
            data = try Data(contentsOf: url)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PWAManifest.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(self).write(to: url)
    }
}
