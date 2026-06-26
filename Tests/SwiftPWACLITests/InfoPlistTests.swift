import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("InfoPlist generators")
struct InfoPlistTests {
    private let manifest = PWAManifest(
        id: "com.example.hi",
        name: "Hi",
        version: "1.2.3",
        description: nil,
        icon: "icon.png",
        web: .init(directory: "web"),
        window: .init(title: "Hi"),
        macos: .init(bundleIdentifier: nil, category: "public.app-category.utilities", minimumSystemVersion: "15.0"),
        ios: .init(bundleIdentifier: "com.example.hi.ios", minimumSystemVersion: "18.0"),
        linux: nil
    )

    @Test("macOS plist has required keys and serializes")
    func mac() throws {
        let plist = InfoPlistGenerator.macOS(manifest: manifest, executableName: manifest.binaryName)
        let data = try plist.encode()
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any])
        #expect(parsed["CFBundleIdentifier"] as? String == "com.example.hi")
        #expect(parsed["CFBundleShortVersionString"] as? String == "1.2.3")
        #expect(parsed["LSMinimumSystemVersion"] as? String == "15.0")
        #expect(parsed["LSApplicationCategoryType"] as? String == "public.app-category.utilities")
        #expect(parsed["CFBundleIconFile"] as? String == "AppIcon.icns")
        #expect(parsed["NSPrincipalClass"] as? String == "NSApplication")
        // No copyright on the base manifest — make sure we don't emit one.
        #expect(parsed["NSHumanReadableCopyright"] == nil)
    }

    @Test("macOS plist surfaces copyright when provided")
    func macCopyright() throws {
        var withCopyright = manifest
        withCopyright.macos?.copyright = "© 2026 Acme Corp."
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: InfoPlistGenerator.macOS(manifest: withCopyright, executableName: withCopyright.binaryName).encode(),
            options: [], format: nil
        ) as? [String: Any])
        #expect(parsed["NSHumanReadableCopyright"] as? String == "© 2026 Acme Corp.")
    }

    @Test("macOS info_plist passthrough merges, including nested objects")
    func macInfoPlistPassthrough() throws {
        var m = manifest
        m.macos?.infoPlist = [
            "NSAppTransportSecurity": .object(["NSAllowsLocalNetworking": .bool(true)]),
            "NSCameraUsageDescription": .string("Scan a code"),
            "CFBundleURLTypes": .array([.object(["CFBundleURLSchemes": .array([.string("myapp")])])])
        ]
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: InfoPlistGenerator.macOS(manifest: m, executableName: m.binaryName).encode(),
            options: [], format: nil
        ) as? [String: Any])
        let ats = try #require(parsed["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(parsed["NSCameraUsageDescription"] as? String == "Scan a code")
        let urlTypes = try #require(parsed["CFBundleURLTypes"] as? [[String: Any]])
        #expect((urlTypes.first?["CFBundleURLSchemes"] as? [String])?.first == "myapp")
        // Generated keys still present alongside the passthrough.
        #expect(parsed["CFBundleIdentifier"] as? String == "com.example.hi")
    }

    @Test("info_plist passthrough overrides a generated key on collision")
    func macInfoPlistOverride() throws {
        var m = manifest
        m.macos?.infoPlist = ["LSMinimumSystemVersion": .string("26.0")]
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: InfoPlistGenerator.macOS(manifest: m, executableName: m.binaryName).encode(),
            options: [], format: nil
        ) as? [String: Any])
        #expect(parsed["LSMinimumSystemVersion"] as? String == "26.0")
    }

    @Test("iOS info_plist passthrough merges too")
    func iosInfoPlistPassthrough() throws {
        var m = manifest
        m.ios?.infoPlist = ["UIFileSharingEnabled": .bool(true)]
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: InfoPlistGenerator.iOS(manifest: m, executableName: m.binaryName).encode(),
            options: [], format: nil
        ) as? [String: Any])
        #expect(parsed["UIFileSharingEnabled"] as? Bool == true)
        #expect(parsed["CFBundleIdentifier"] as? String == "com.example.hi.ios")
    }

    @Test("info_plist passthrough round-trips (incl. nested) through pwa.json")
    func infoPlistRoundTrips() throws {
        let json = """
        {"id":"com.example.x","name":"X","version":"1.0.0",
         "web":{"directory":"web","entry":"index.html"},
         "window":{"title":"X","width":1024,"height":768,"resizable":true,"fullscreen":false},
         "macos":{"info_plist":{"NSAppTransportSecurity":{"NSAllowsLocalNetworking":true}}}}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        // The CamelCase plist key survives convertFromSnakeCase (no underscores).
        #expect(m.macos?.infoPlist?["NSAppTransportSecurity"] == .object(["NSAllowsLocalNetworking": .bool(true)]))
    }

    @Test("CFBundleExecutable uses the resolved executable name while display keys use name")
    func executableNameDecoupledFromDisplay() throws {
        var m = manifest
        m.name = "Field Notes" // display, has a space
        // The bundler resolves the SwiftPM target name and passes it in;
        // the plist's executable key must use that, not the display name.
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: InfoPlistGenerator.macOS(manifest: m, executableName: "FieldNotes").encode(),
            options: [], format: nil
        ) as? [String: Any])
        // The executable key must match the on-disk binary (the target).
        #expect(parsed["CFBundleExecutable"] as? String == "FieldNotes")
        // The human-facing keys carry the display name (spaces allowed).
        #expect(parsed["CFBundleName"] as? String == "Field Notes")
        #expect(parsed["CFBundleDisplayName"] as? String == "Field Notes")

        // iOS mirrors the same split.
        let ios = try #require(PropertyListSerialization.propertyList(
            from: InfoPlistGenerator.iOS(manifest: m, executableName: "FieldNotes").encode(),
            options: [], format: nil
        ) as? [String: Any])
        #expect(ios["CFBundleExecutable"] as? String == "FieldNotes")
        #expect(ios["CFBundleDisplayName"] as? String == "Field Notes")
    }

    @Test("iOS plist declares a UIScene configuration")
    func ios() throws {
        let plist = InfoPlistGenerator.iOS(manifest: manifest, executableName: manifest.binaryName)
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: plist.encode(), options: [], format: nil
        ) as? [String: Any])
        #expect(parsed["CFBundleIdentifier"] as? String == "com.example.hi.ios")
        #expect(parsed["MinimumOSVersion"] as? String == "18.0")
        let scenes = parsed["UIApplicationSceneManifest"] as? [String: Any]
        #expect(scenes?["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        let configs = scenes?["UISceneConfigurations"] as? [String: Any]
        let app = configs?["UIWindowSceneSessionRoleApplication"] as? [[String: Any]]
        #expect(app?.first?["UISceneDelegateClassName"] as? String == "SwiftPWAWebKit.SwiftPWASceneDelegate")
        // No storyboard name → fall back to the empty UILaunchScreen dict.
        #expect(parsed["UILaunchStoryboardName"] == nil)
        #expect(parsed["UILaunchScreen"] is [String: Any])
    }

    @Test("iOS plist switches to UILaunchStoryboardName when a storyboard is supplied")
    func iosLaunchStoryboard() throws {
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: InfoPlistGenerator.iOS(
                manifest: manifest, executableName: manifest.binaryName, launchStoryboardName: "LaunchScreen"
            ).encode(),
            options: [], format: nil
        ) as? [String: Any])
        #expect(parsed["UILaunchStoryboardName"] as? String == "LaunchScreen")
        #expect(parsed["UILaunchScreen"] == nil)
    }
}
