import Foundation

public extension PWAManifest {
    /// An app icon: one 1024×1024 PNG, or one per appearance.
    ///
    /// ```json
    /// "icon": "icon.png"
    /// "icon": { "light": "icon.png", "dark": "icon-dark.png", "tinted": "icon-tinted.png" }
    /// ```
    ///
    /// `dark` and `tinted` are optional, and a platform without the variant
    /// ignores it. `tinted` is the grayscale art the system colours: iOS and
    /// macOS draw both their Clear and Tinted styles from it (Icon Composer
    /// calls it "mono"), Android uses it as the themed icon's monochrome layer
    /// (its alpha channel only), and Windows has no use for it. `dark` is the
    /// iOS / macOS dark icon and the Windows dark-taskbar logo.
    ///
    /// Art for appearances is full-bleed: every platform that draws them
    /// applies its own mask. Decodes from a string or an object and re-encodes
    /// in the shape it was written.
    struct IconArt: Codable, Sendable, Equatable, ExpressibleByStringLiteral {
        public var light: String
        public var dark: String?
        public var tinted: String?

        public init(light: String, dark: String? = nil, tinted: String? = nil) {
            self.light = light
            self.dark = dark
            self.tinted = tinted
        }

        public init(stringLiteral value: String) {
            self.init(light: value)
        }

        /// Whether any art beyond the light icon is supplied — the switch for
        /// the build paths that exist only to carry it.
        public var hasAppearances: Bool {
            dark != nil || tinted != nil
        }

        /// Every path this icon names, for checking they exist.
        public var paths: [String] {
            [light, dark, tinted].compactMap(\.self)
        }

        private enum Keys: String, CodingKey { case light, dark, tinted }

        public init(from decoder: any Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let path = try? container.decode(String.self)
            {
                self.init(light: path)
                return
            }
            let keyed = try decoder.container(keyedBy: Keys.self)
            try self.init(
                light: keyed.decode(String.self, forKey: .light),
                dark: keyed.decodeIfPresent(String.self, forKey: .dark),
                tinted: keyed.decodeIfPresent(String.self, forKey: .tinted)
            )
        }

        public func encode(to encoder: any Encoder) throws {
            guard hasAppearances else {
                var container = encoder.singleValueContainer()
                try container.encode(light)
                return
            }
            var keyed = encoder.container(keyedBy: Keys.self)
            try keyed.encode(light, forKey: .light)
            try keyed.encodeIfPresent(dark, forKey: .dark)
            try keyed.encodeIfPresent(tinted, forKey: .tinted)
        }
    }

    /// One `alternate_icons` entry: an icon the person can pick in the app's
    /// settings.
    ///
    /// ```json
    /// "alternate_icons": [
    ///   { "name": "sketch", "icon": { "light": "sketch.png", "dark": "sketch-dark.png", "tinted": "sketch-tinted.png"
    /// } }
    /// ]
    /// ```
    struct AlternateIcon: Codable, Sendable, Equatable {
        /// The id the page passes to `app.icon.set` and reads back from
        /// `app.icon.list`. Lowercase letters, digits and `_`, starting with
        /// a letter, because it becomes an iOS asset name and part of an
        /// Android component name.
        public var name: String
        public var icon: IconArt

        public init(name: String, icon: IconArt) {
            self.name = name
            self.icon = icon
        }

        /// Why `name` can't be used, or `nil` when it can.
        public static func problem(withName name: String) -> String? {
            guard let first = name.unicodeScalars.first else { return "a name is required" }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
            guard CharacterSet.lowercaseLetters.contains(first), first.isASCII,
                  name.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else {
                return "\"\(name)\" must be lowercase letters, digits and _, starting with a letter"
            }
            // Too close to the primary icon's asset name, `AppIcon`, to share a
            // catalog with it safely.
            guard name != "appicon" else { return "\"appicon\" is reserved for the primary icon" }
            return nil
        }
    }
}
