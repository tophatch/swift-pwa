import Foundation

/// The `Info.plist` keys Xcode writes into every app it builds, describing the
/// toolchain and SDK. We assemble bundles ourselves, so nothing wrote them, and
/// App Store Connect rejects an upload without them: a missing `DTPlatformName`
/// is ITMS-90507, and `DTXcode` / `DTSDKBuild` are what it checks the
/// minimum-SDK rule against.
struct AppleBuildEnvironment: Equatable {
    /// The SDK's short name: `iphoneos`, `iphonesimulator` or `macosx`.
    let platformName: String
    let sdkVersion: String
    let sdkBuild: String
    /// `nil` with only the Command Line Tools installed, which can still build
    /// a macOS app but has no `xcodebuild`.
    let xcodeVersion: String?
    let xcodeBuild: String?
    let machineBuild: String

    var plistKeys: [String: Any] {
        var keys: [String: Any] = [
            "BuildMachineOSBuild": machineBuild,
            "CFBundleSupportedPlatforms": [Self.supportedPlatform(platformName)],
            "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
            "DTPlatformBuild": sdkBuild,
            "DTPlatformName": platformName,
            "DTPlatformVersion": sdkVersion,
            "DTSDKBuild": sdkBuild,
            "DTSDKName": platformName + sdkVersion
        ]
        if let xcodeVersion { keys["DTXcode"] = Self.dtXcode(xcodeVersion) }
        if let xcodeBuild { keys["DTXcodeBuild"] = xcodeBuild }
        return keys
    }

    /// `CFBundleSupportedPlatforms` spells the platform differently from the SDK.
    static func supportedPlatform(_ platformName: String) -> String {
        switch platformName {
        case "iphoneos": "iPhoneOS"
        case "iphonesimulator": "iPhoneSimulator"
        default: "MacOSX"
        }
    }

    /// Xcode's own encoding of its version: two digits of major, then one each
    /// of minor and patch. `27.1` → `2710`, `16.4.1` → `1641`.
    static func dtXcode(_ version: String) -> String {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return String(format: "%02d%d%d", major, min(minor, 9), min(patch, 9))
    }

    /// `Xcode 27.1\nBuild version 27A9275` → (`27.1`, `27A9275`).
    static func parseXcodeVersion(_ output: String) -> (version: String, build: String)? {
        var version: String?
        var build: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Xcode ") { version = String(line.dropFirst("Xcode ".count)) }
            if line.hasPrefix("Build version ") { build = String(line.dropFirst("Build version ".count)) }
        }
        guard let version, let build else { return nil }
        return (version.trimmingCharacters(in: .whitespaces), build.trimmingCharacters(in: .whitespaces))
    }

    /// Read the values from the toolchain that is about to build: the SDK from
    /// `xcrun`, Xcode's version from `xcodebuild`, the host from `sw_vers`.
    static func probe(sdk: String) async throws -> AppleBuildEnvironment {
        func capture(_ args: [String]) async throws -> String {
            try await Shell.capture(args[0], Array(args.dropFirst()), discardStderr: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let xcode = try? await parseXcodeVersion(capture(["xcodebuild", "-version"]))
        if xcode == nil {
            print("swift-pwa: no xcodebuild (Command Line Tools only?) — Info.plist gets no DTXcode / DTXcodeBuild")
        }
        return try await AppleBuildEnvironment(
            platformName: sdk,
            sdkVersion: capture(["xcrun", "--sdk", sdk, "--show-sdk-version"]),
            sdkBuild: capture(["xcrun", "--sdk", sdk, "--show-sdk-build-version"]),
            xcodeVersion: xcode?.version,
            xcodeBuild: xcode?.build,
            machineBuild: capture(["sw_vers", "-buildVersion"])
        )
    }
}
