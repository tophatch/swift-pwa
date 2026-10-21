import Foundation
@testable import SwiftPWACLISupport
import Testing

/// What the bundlers generate for icon appearances and alternate icons (#314).
/// The platform behaviour these encode was measured on devices; see
/// `docs/proposals/app-icon-appearances.md`.
@Suite("App icon appearances and alternates in the bundlers")
struct IconAppearanceBundlerTests {
    private let root = URL(fileURLWithPath: "/project")

    private func icon(dark: Bool = true, tinted: Bool = true) -> AppleIconCatalog.Icon {
        AppleIconCatalog.Icon(
            name: "AppIcon",
            light: root.appendingPathComponent("l.png"),
            dark: dark ? root.appendingPathComponent("d.png") : nil,
            tinted: tinted ? root.appendingPathComponent("t.png") : nil
        )
    }

    /// Which layer each appearance shows: a layer is visible where its
    /// `hidden-specializations` entry for that appearance is `false`, and the
    /// entry with no appearance is the default.
    private func visibleLayer(in json: String, appearance: String?) throws -> [String] {
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let groups = try #require(object["groups"] as? [[String: Any]])
        let layers = try #require(groups.first?["layers"] as? [[String: Any]])
        return try layers.filter { layer in
            let specs = try #require(layer["hidden-specializations"] as? [[String: Any]])
            let spec = specs.first { ($0["appearance"] as? String) == appearance }
            return (spec?["value"] as? Bool) == false
        }.compactMap { $0["name"] as? String }
    }

    @Test("the Icon Composer document shows exactly one layer per appearance")
    func iconComposerLayers() throws {
        let json = AppleIconCatalog.iconComposerJSON(icon())
        #expect(try visibleLayer(in: json, appearance: nil) == ["light"])
        #expect(try visibleLayer(in: json, appearance: "light") == ["light"])
        #expect(try visibleLayer(in: json, appearance: "dark") == ["dark"])
        #expect(try visibleLayer(in: json, appearance: "tinted") == ["tinted"])
    }

    /// An appearance with no art of its own falls back to the light layer, so
    /// the system treats it as it treats a plain icon rather than drawing
    /// nothing.
    @Test("an appearance without art shows the light layer")
    func iconComposerFallsBackToLight() throws {
        let json = AppleIconCatalog.iconComposerJSON(icon(dark: false))
        #expect(try visibleLayer(in: json, appearance: "dark") == ["light"])
        #expect(try visibleLayer(in: json, appearance: "tinted") == ["tinted"])
    }

    /// Glass, specular, shadow and translucency off: the art arrives finished,
    /// and on a device this drew identically to the same PNGs in an icon set.
    @Test("the Icon Composer document applies no Liquid Glass effects")
    func iconComposerIsFlat() throws {
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(AppleIconCatalog.iconComposerJSON(icon()).utf8)
        ) as? [String: Any])
        let group = try #require((object["groups"] as? [[String: Any]])?.first)
        #expect(group["specular"] as? Bool == false)
        #expect((group["translucency"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((group["shadow"] as? [String: Any])?["kind"] as? String == "none")
        for layer in try #require(group["layers"] as? [[String: Any]]) {
            #expect(layer["glass"] as? Bool == false)
        }
    }

    /// `actool` records the source file name in the rendition, so a plain icon
    /// has to keep the name it always had to compile identically.
    @Test("the light art keeps the icon set's historical file name")
    func lightFileName() {
        #expect(AppleIconCatalog.layerFiles(icon()).map(\.file) == ["icon.png", "dark.png", "tinted.png"])
        #expect(AppleIconCatalog.layerFiles(icon(dark: false, tinted: false)).map(\.file) == ["icon.png"])
    }

    @Test("the classic icon set carries a luminosity entry per appearance")
    func iconSetContents() throws {
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(AppleIconCatalog.iconSetContentsJSON(icon(dark: false)).utf8)
        ) as? [String: Any])
        let images = try #require(object["images"] as? [[String: Any]])
        #expect(images.count == 2)
        #expect(images[0]["filename"] as? String == "icon.png")
        #expect(images[0]["appearances"] == nil)
        let appearance = (images[1]["appearances"] as? [[String: String]])?.first
        #expect(appearance == ["appearance": "luminosity", "value": "tinted"])
    }

    @Test("a compile counts only when every icon asked for is registered")
    func registration() {
        let ios: [String: Any] = ["CFBundleIcons": [
            "CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"],
            "CFBundleAlternateIcons": ["sketch": ["CFBundleIconName": "sketch"]]
        ]]
        #expect(AppleIconCatalog.registers(primary: "AppIcon", alternates: ["sketch"], in: ios))
        #expect(!AppleIconCatalog.registers(primary: "AppIcon", alternates: ["sketch", "night"], in: ios))
        #expect(!AppleIconCatalog.registers(primary: "AppIcon", alternates: [], in: [:]))
        let mac: [String: Any] = ["CFBundleIconName": "AppIcon", "CFBundleIconFile": "AppIcon"]
        #expect(AppleIconCatalog.registers(primary: "AppIcon", alternates: [], in: mac))
    }

    @Test("macOS names the icon in Info.plist only when it's in the asset catalog")
    func macIconName() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(PWAManifest.self, from: Data("""
        { "id": "com.example.hi", "name": "Hi", "version": "1.0.0", "icon": "icon.png",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Hi", "width": 1024, "height": 768, "resizable": true, "fullscreen": false } }
        """.utf8))
        let plain = InfoPlistGenerator.macOS(manifest: manifest, executableName: "Hi")
        #expect(plain["CFBundleIconName"] == nil)
        #expect(plain["CFBundleIconFile"] as? String == "AppIcon.icns")
        let catalog = InfoPlistGenerator.macOS(manifest: manifest, executableName: "Hi", iconInAssetCatalog: true)
        #expect(catalog["CFBundleIconName"] as? String == "AppIcon")
        #expect(catalog["CFBundleIconFile"] as? String == "AppIcon.icns")
    }

    // MARK: - Android

    @Test("without alternates MainActivity keeps the launcher filter and there are no aliases")
    func androidNoAlternates() {
        let xml = AndroidTemplates.androidManifestXml(packageId: "com.example.hi", label: "Hi", hasIcon: true)
        #expect(xml.contains("android.intent.category.LAUNCHER"))
        #expect(!xml.contains("activity-alias"))
    }

    @Test("alternates move the launcher filter onto one alias per icon")
    func androidAliases() throws {
        let xml = AndroidTemplates.androidManifestXml(
            packageId: "com.example.hi", label: "Hi", hasIcon: true, alternateIcons: ["sketch", "night"]
        )
        let activity = try #require(xml.range(of: "<activity\n").map { xml[$0.lowerBound...] })
        let activityEnd = try #require(activity.range(of: "</activity>"))
        let mainActivity = String(activity[..<activityEnd.upperBound])
        #expect(!mainActivity.contains("LAUNCHER"))
        #expect(xml.components(separatedBy: "android.intent.category.LAUNCHER").count - 1 == 3)
        #expect(xml.contains(#"android:name="com.example.hi.LauncherDefault""#))
        #expect(xml.contains(#"android:name="com.example.hi.LauncherIcon_sketch""#))
        #expect(xml.contains(#"android:icon="@mipmap/ic_launcher_night""#))
        // Only the primary starts enabled, so the app has one launcher entry.
        #expect(xml.components(separatedBy: #"android:enabled="true""#).count - 1 == 1)
        #expect(xml.components(separatedBy: #"android:enabled="false""#).count - 1 == 2)
        #expect(xml.components(separatedBy: #"android:targetActivity="com.example.hi.MainActivity""#).count - 1 == 3)
    }

    /// The monochrome layer is drawn on the same 108 dp canvas as the
    /// foreground (measured on One UI), so both are inset to the 72 dp window.
    @Test("the adaptive icon insets both its art and its themed layer")
    func androidAdaptiveIcon() {
        let adaptive = AndroidTemplates.adaptiveIconXml(name: "ic_launcher_sketch")
        #expect(adaptive.contains(#"<foreground android:drawable="@drawable/ic_launcher_sketch_light_inset"/>"#))
        #expect(adaptive.contains(#"<monochrome android:drawable="@drawable/ic_launcher_sketch_tinted_inset"/>"#))
        #expect(adaptive.contains(#"<background android:drawable="@color/ic_launcher_sketch_background"/>"#))
        let inset = AndroidTemplates.insetDrawableXml(source: "ic_launcher_tinted")
        #expect(inset.contains(#"android:inset="16.667%""#))
        #expect(inset.contains(#"android:drawable="@drawable/ic_launcher_tinted""#))
    }

    @Test("the PNG header says whether the art can carry transparency")
    func pngAlpha() {
        func png(colourType: UInt8, chunks: [String] = []) -> Data {
            var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            bytes += [0, 0, 0, 13] + Array("IHDR".utf8) + [0, 0, 0, 1, 0, 0, 0, 1, 8, colourType, 0, 0, 0] + [
                0,
                0,
                0,
                0
            ]
            for chunk in chunks + ["IDAT"] {
                bytes += [0, 0, 0, 0] + Array(chunk.utf8) + [0, 0, 0, 0]
            }
            return Data(bytes)
        }
        #expect(PNGHeader.hasAlpha(png(colourType: 6)) == true) // RGBA
        #expect(PNGHeader.hasAlpha(png(colourType: 4)) == true) // grayscale + alpha
        #expect(PNGHeader.hasAlpha(png(colourType: 2)) == false) // RGB
        #expect(PNGHeader.hasAlpha(png(colourType: 2, chunks: ["tRNS"])) == true)
        #expect(PNGHeader.hasAlpha(Data("not a png at all, long enough to read a header".utf8)) == nil)
    }

    // MARK: - Windows

    @Test("the MSIX names the themed taskbar logo only when it's staged")
    func appxSquare44() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(PWAManifest.self, from: Data("""
        { "id": "com.example.hi", "name": "Hi", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": { "title": "Hi", "width": 1024, "height": 768, "resizable": true, "fullscreen": false } }
        """.utf8))
        #expect(AppxManifestGenerator.render(manifest: manifest).contains(#"Square44x44Logo="Square150x150Logo.png""#))
        #expect(AppxManifestGenerator.render(manifest: manifest, square44x44Logo: "Square44x44Logo.png")
            .contains(#"Square44x44Logo="Square44x44Logo.png""#))
    }
}
