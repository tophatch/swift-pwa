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
        applyUsageDescriptions(manifest, into: &plist)
        merge(manifest.macos?.infoPlist, into: &plist)
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
        // Universal by default (iPhone + iPad). Without UIDeviceFamily, iOS
        // treats the app as iPhone-only and runs it letterboxed on iPad; a
        // thin-client WebView app is device-agnostic, so universal is right.
        // Overridable via `ios.device_family` or the `info_plist` passthrough.
        plist["UIDeviceFamily"] = manifest.ios?.deviceFamily ?? [1, 2]

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
        applyUsageDescriptions(manifest, into: &plist)
        merge(manifest.ios?.infoPlist, into: &plist)
        return plist
    }

    /// The `NS…UsageDescription` string Apple requires for each declared
    /// permission, from `permissions.web`'s `reason`.
    ///
    /// Emitted before the `info_plist` passthrough so an app can still override
    /// a specific string by hand. A declaration with no `reason` emits nothing
    /// here — ``PermissionCheck`` is what refuses that, with a message, rather
    /// than this quietly inventing a purpose string on the developer's behalf.
    /// Apple shows it to the user verbatim and rejects apps that don't have one.
    static let appleUsageDescriptionKeys: [String: String] = [
        "camera": "NSCameraUsageDescription",
        "microphone": "NSMicrophoneUsageDescription",
        "geolocation": "NSLocationWhenInUseUsageDescription",
        // `NSBluetoothPeripheralUsageDescription` is the pre-iOS-13 spelling
        // and isn't emitted: the deployment targets here are iOS 18 / macOS 15.
        "bluetooth": "NSBluetoothAlwaysUsageDescription"
        // `notifications` has no usage-description key: UserNotifications
        // prompts without one.
    ]

    private static func applyUsageDescriptions(_ manifest: PWAManifest, into plist: inout InfoPlist) {
        guard let declarations = manifest.permissions?.allDeclarations else { return }
        for name in declarations.names {
            guard let key = appleUsageDescriptionKeys[name],
                  let reason = declarations.detail(for: name)?.reason,
                  !reason.isEmpty
            else { continue }
            plist[key] = reason
        }
    }

    /// Merge a `pwa.json` `info_plist` passthrough over the generated keys
    /// (passthrough wins on collision, so an app can override a default).
    /// Null leaves are dropped (no plist representation).
    private static func merge(_ passthrough: [String: JSONValue]?, into plist: inout InfoPlist) {
        guard let passthrough else { return }
        for (key, value) in passthrough {
            if let v = value.plistValue { plist[key] = v }
        }
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
