import Foundation
import Testing
@testable import swift_pwa_cli

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
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as! [String: Any]
        #expect(parsed["CFBundleIdentifier"] as? String == "com.example.hi")
        #expect(parsed["CFBundleShortVersionString"] as? String == "1.2.3")
        #expect(parsed["LSMinimumSystemVersion"] as? String == "15.0")
        #expect(parsed["LSApplicationCategoryType"] as? String == "public.app-category.utilities")
        #expect(parsed["CFBundleIconFile"] as? String == "AppIcon.icns")
        #expect(parsed["NSPrincipalClass"] as? String == "NSApplication")
    }

    @Test("iOS plist declares a UIScene configuration")
    func ios() throws {
        let plist = InfoPlistGenerator.iOS(manifest: manifest)
        let parsed = try PropertyListSerialization.propertyList(
            from: try plist.encode(), options: [], format: nil
        ) as! [String: Any]
        #expect(parsed["CFBundleIdentifier"] as? String == "com.example.hi.ios")
        #expect(parsed["MinimumOSVersion"] as? String == "18.0")
        let scenes = parsed["UIApplicationSceneManifest"] as? [String: Any]
        #expect(scenes?["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        let configs = scenes?["UISceneConfigurations"] as? [String: Any]
        let app = configs?["UIWindowSceneSessionRoleApplication"] as? [[String: Any]]
        #expect(app?.first?["UISceneDelegateClassName"] as? String == "$(PRODUCT_MODULE_NAME).SwiftPWASceneDelegate")
    }
}
