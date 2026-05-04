import Foundation

/// On-disk schema for `pwa.json`. The single source of truth; all
/// platform-specific manifests (Info.plist, .desktop, AndroidManifest)
/// are *generated* from this file.
public struct PWAManifest: Codable, Sendable, Equatable {
    public var id: String                  // reverse-DNS, e.g. "com.example.hello"
    public var name: String                // human-readable name
    public var version: String             // e.g. "1.0.0"
    public var description: String?
    public var icon: String?               // path to a 1024x1024 PNG, optional
    public var web: WebSection
    public var window: WindowSection
    public var macos: MacOSSection?
    public var ios: IOSSection?
    public var linux: LinuxSection?

    public struct WebSection: Codable, Sendable, Equatable {
        public var directory: String       // path relative to project root
        public var entry: String           // default "index.html"
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
        public var bundleIdentifier: String?       // defaults to top-level `id`
        public var category: String?               // LSApplicationCategoryType
        public var minimumSystemVersion: String?   // e.g. "15.0"
    }

    public struct IOSSection: Codable, Sendable, Equatable {
        public var bundleIdentifier: String?
        public var minimumSystemVersion: String?   // e.g. "18.0"
    }

    public struct LinuxSection: Codable, Sendable, Equatable {
        public var desktopCategories: [String]?    // e.g. ["Utility"]
        public var executableName: String?         // defaults to top-level `id` last component
    }

    public static func load(from url: URL) throws -> PWAManifest {
        let data = try Data(contentsOf: url)
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
