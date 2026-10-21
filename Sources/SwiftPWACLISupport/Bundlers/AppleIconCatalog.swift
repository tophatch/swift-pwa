import Foundation

/// The app-icon inputs `actool` compiles, for the two Apple bundlers.
///
/// Two forms, because `actool` treats them differently per platform
/// (measured on Xcode 27.1, see `docs/proposals/app-icon-appearances.md`):
///
/// - An **Icon Composer `.icon`** document, generated here from the PNGs,
///   one layer per appearance. It's the only input from which macOS keeps
///   dark and tinted art: an `.appiconset` with appearance entries compiles
///   for `macosx` without a warning and keeps the light art alone. iOS
///   accepts it too, alternates included, so one generator serves both.
///   Needs the Xcode 26 `actool`.
/// - A classic **`.appiconset`**, for an icon with no appearances (today's
///   output, unchanged) and as the iOS fallback when `actool` predates
///   `.icon`. iOS honours its `luminosity` dark and tinted entries.
///
/// iOS and macOS both draw their Clear styles from the tinted art, so there
/// is no separate Clear input.
enum AppleIconCatalog {
    /// One icon to compile, with its PNGs already resolved on disk.
    struct Icon: Equatable {
        /// The asset name: `AppIcon` for the primary, an alternate's own name.
        var name: String
        var light: URL
        var dark: URL?
        var tinted: URL?

        var hasAppearances: Bool {
            dark != nil || tinted != nil
        }
    }

    /// The asset name of the primary icon, which `--app-icon` names.
    static let primaryName = "AppIcon"

    enum Resolution {
        case icon(Icon)
        /// A file is missing or isn't a PNG; report this instead.
        case failed(IconOutcome)
    }

    /// Find `art`'s files under `projectRoot`, or the outcome to report when
    /// one is missing or isn't a PNG.
    static func resolve(_ art: PWAManifest.IconArt, name: String, projectRoot: URL) -> Resolution {
        if let problem = art.problem(under: projectRoot) { return .failed(problem) }
        func url(_ path: String) -> URL {
            projectRoot.appendingPathComponent(path)
        }
        return .icon(Icon(name: name, light: url(art.light), dark: art.dark.map(url), tinted: art.tinted.map(url)))
    }

    /// The appearances an icon carries, for the build's one-line summary.
    static func appearanceSummary(_ icon: Icon) -> String? {
        let names = [icon.dark.map { _ in "dark" }, icon.tinted.map { _ in "tinted" }].compactMap(\.self)
        return names.isEmpty ? nil : names.joined(separator: " + ")
    }

    // MARK: - Icon Composer document

    /// Write `<name>.icon` into `directory` and return its URL.
    @discardableResult
    static func writeIconComposerDocument(_ icon: Icon, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let document = directory.appendingPathComponent("\(icon.name).icon")
        let assets = document.appendingPathComponent("Assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        for layer in layerFiles(icon) {
            try fm.copyItem(at: layer.source, to: assets.appendingPathComponent(layer.file))
        }
        try iconComposerJSON(icon).write(
            to: document.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8
        )
        return document
    }

    /// The asset file each supplied appearance's PNG is copied to. The light
    /// art keeps the name the single-PNG icon set has always used, which
    /// `actool` records in the rendition, so a plain icon compiles exactly as
    /// it did before appearances existed.
    static func layerFiles(_ icon: Icon) -> [(appearance: String, file: String, source: URL)] {
        [("light", "icon.png", icon.light), ("dark", "dark.png", icon.dark), ("tinted", "tinted.png", icon.tinted)]
            .compactMap { appearance, file, url in url.map { (appearance, file, $0) } }
    }

    /// `icon.json` for `icon`: one layer per supplied appearance, each shown
    /// in exactly the appearances whose art it is. An appearance with no art
    /// of its own shows the light layer, which leaves the system to treat it
    /// the way it treats a plain icon (darkening it, tinting it).
    ///
    /// Glass, specular highlights, shadow and translucency are all off: the
    /// art arrives finished, and on a device this drew identically to the
    /// same PNGs in a classic icon set.
    static func iconComposerJSON(_ icon: Icon) -> String {
        let appearances = ["light", "dark", "tinted"]
        func shown(_ appearance: String) -> String {
            switch appearance {
            case "dark" where icon.dark != nil: "dark"
            case "tinted" where icon.tinted != nil: "tinted"
            default: "light"
            }
        }
        let layers = layerFiles(icon).map { label, file, _ in
            // The first entry, with no appearance, is the default — shown
            // only for the light art.
            let hidden = [#"{ "value" : \#(label != "light") }"#] + appearances.map {
                #"{ "appearance" : "\#($0)", "value" : \#(shown($0) != label) }"#
            }
            return """
                {
                  "glass" : false,
                  "hidden-specializations" : [ \(hidden.joined(separator: ", ")) ],
                  "image-name" : "\(file)",
                  "name" : "\(label)"
                }
            """
        }
        return """
        {
          "groups" : [ {
            "layers" : [
        \(layers.joined(separator: ",\n"))
            ],
            "shadow" : { "kind" : "none", "opacity" : 0 },
            "specular" : false,
            "translucency" : { "enabled" : false, "value" : 0 }
          } ],
          "supported-platforms" : { "squares" : "shared" }
        }
        """
    }

    // MARK: - Classic icon set

    /// Write `<name>.appiconset` into the asset catalog at `catalog`: the
    /// single-size universal iOS form, plus a `luminosity` entry per
    /// appearance supplied.
    static func writeIconSet(_ icon: Icon, in catalog: URL) throws {
        let fm = FileManager.default
        let set = catalog.appendingPathComponent("\(icon.name).appiconset")
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        for layer in layerFiles(icon) {
            try fm.copyItem(at: layer.source, to: set.appendingPathComponent(layer.file))
        }
        try iconSetContentsJSON(icon).write(
            to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
        )
    }

    static func iconSetContentsJSON(_ icon: Icon) -> String {
        let images = layerFiles(icon).map { label, file, _ in
            let appearance = label == "light"
                ? ""
                : #" "appearances" : [ { "appearance" : "luminosity", "value" : "\#(label)" } ],"#
            return #"    {\#(appearance) "filename" : "\#(file)", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }"#
        }
        return """
        {
          "images" : [
        \(images.joined(separator: ",\n"))
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
    }

    // MARK: - Compile result

    /// Whether `actool`'s partial Info.plist registers the primary icon and
    /// every alternate — the check that a compile produced icons at all. An
    /// `actool` that doesn't understand an input can finish without
    /// registering it, so a clean exit alone doesn't say.
    static func registers(primary: String, alternates: [String], in partial: [String: Any]) -> Bool {
        if partial["CFBundleIcons"] == nil {
            // macOS: no `CFBundleIcons` dictionary, just the name.
            return alternates.isEmpty && (partial["CFBundleIconName"] as? String) == primary
        }
        let icons = partial["CFBundleIcons"] as? [String: Any]
        let primaryName = (icons?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] as? String
        let registered = Set(((icons?["CFBundleAlternateIcons"] as? [String: Any]) ?? [:]).keys)
        return primaryName == primary && registered.isSuperset(of: alternates)
    }

    /// A one-line reason for the build's icon summary. `actool` prints its
    /// own diagnostics above it, so the command line it ran adds nothing.
    static func reason(_ error: any Error) -> String {
        if case let BundlerError.shell(code, _) = error { return "actool exited with status \(code)" }
        return "actool failed: \(error)"
    }

    /// Read a partial Info.plist `actool` wrote.
    static func readPartialPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
