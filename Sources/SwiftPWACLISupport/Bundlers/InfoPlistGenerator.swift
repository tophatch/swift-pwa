import Foundation

/// Generates `Info.plist` content for macOS / iOS bundles from a `PWAManifest`.
enum InfoPlistGenerator {
    static func macOS(manifest: PWAManifest, executableName: String) -> InfoPlist {
        var plist = InfoPlist()
        plist["CFBundleDevelopmentRegion"] = "en"
        plist["CFBundleDisplayName"] = manifest.name
        // CFBundleExecutable must match the on-disk binary in
        // Contents/MacOS — that's the SwiftPM target name, which may
        // differ from the human-facing display `name`.
        plist["CFBundleExecutable"] = executableName
        plist["CFBundleIdentifier"] = manifest.macos?.bundleIdentifier ?? manifest.id
        plist["CFBundleInfoDictionaryVersion"] = "6.0"
        plist["CFBundleName"] = manifest.name
        plist["CFBundlePackageType"] = "APPL"
        plist["CFBundleShortVersionString"] = manifest.version
        plist["CFBundleVersion"] = manifest.version
        plist["LSMinimumSystemVersion"] = manifest.macos?.minimumSystemVersion ?? "15.0"
        if let cat = manifest.macos?.category {
            plist["LSApplicationCategoryType"] = cat
        }
        if let copyright = manifest.macos?.copyright {
            plist["NSHumanReadableCopyright"] = copyright
        }
        plist["NSHighResolutionCapable"] = true
        plist["NSPrincipalClass"] = "NSApplication"
        if manifest.icon != nil {
            plist["CFBundleIconFile"] = "AppIcon.icns"
        }
        return plist
    }

    static func iOS(manifest: PWAManifest, executableName: String, launchStoryboardName: String? = nil) -> InfoPlist {
        var plist = InfoPlist()
        plist["CFBundleDevelopmentRegion"] = "en"
        plist["CFBundleDisplayName"] = manifest.name
        plist["CFBundleExecutable"] = executableName
        plist["CFBundleIdentifier"] = manifest.ios?.bundleIdentifier ?? manifest.id
        plist["CFBundleInfoDictionaryVersion"] = "6.0"
        plist["CFBundleName"] = manifest.name
        plist["CFBundlePackageType"] = "APPL"
        plist["CFBundleShortVersionString"] = manifest.version
        plist["CFBundleVersion"] = manifest.version
        plist["LSRequiresIPhoneOS"] = true
        plist["MinimumOSVersion"] = manifest.ios?.minimumSystemVersion ?? "18.0"

        // UIScene declarations for full multi-window support.
        plist["UIApplicationSceneManifest"] = [
            "UIApplicationSupportsMultipleScenes": true,
            "UISceneConfigurations": [
                "UIWindowSceneSessionRoleApplication": [
                    [
                        "UISceneConfigurationName": "swift-pwa",
                        "UISceneClassName": "UIWindowScene",
                        "UISceneDelegateClassName": "SwiftPWAWebKit.SwiftPWASceneDelegate"
                    ]
                ]
            ]
        ]
        plist["UISupportedInterfaceOrientations"] = [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
        ]
        // Without a launch screen declaration, iOS runs the app in
        // legacy compatibility mode and letterboxes the window on
        // modern devices. UILaunchStoryboardName takes precedence
        // when set; the empty UILaunchScreen is the system-default
        // fallback for projects without an icon.
        if let name = launchStoryboardName {
            plist["UILaunchStoryboardName"] = name
        } else {
            plist["UILaunchScreen"] = [String: Any]()
        }
        return plist
    }
}

/// Tiny ordered-key wrapper around `[String: Any]` so the generator can
/// be tested deterministically (sorted-keys output) without relying on
/// dictionary iteration order.
struct InfoPlist {
    private(set) var entries: [String: Any] = [:]

    subscript(key: String) -> Any? {
        get { entries[key] }
        set { entries[key] = newValue }
    }

    func write(to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: entries,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    func encode() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: entries,
            format: .xml,
            options: 0
        )
    }
}
