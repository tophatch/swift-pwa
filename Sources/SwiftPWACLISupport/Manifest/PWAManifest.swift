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
