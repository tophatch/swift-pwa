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
        let plist = InfoPlistGenerator.macOS(manifest: manifest)
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
            from: InfoPlistGenerator.macOS(manifest: withCopyright).encode(),
            options: [], format: nil
        ) as? [String: Any])
        #expect(parsed["NSHumanReadableCopyright"] as? String == "© 2026 Acme Corp.")
    }

    @Test("iOS plist declares a UIScene configuration")
    func ios() throws {
        let plist = InfoPlistGenerator.iOS(manifest: manifest)
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
            from: InfoPlistGenerator.iOS(manifest: manifest, launchStoryboardName: "LaunchScreen").encode(),
            options: [], format: nil
        ) as? [String: Any])
        #expect(parsed["UILaunchStoryboardName"] as? String == "LaunchScreen")
        #expect(parsed["UILaunchScreen"] == nil)
    }
}
