import ArgumentParser
import Foundation

/// Builds an iOS `.app` (simulator) or `.ipa` (device).
///
/// Uses `xcodebuild` rather than `swift build --triple` because Apple
/// does not ship an iOS Swift SDK that SwiftPM can cross-compile against
/// directly — the manifest needs to compile for the host (macOS) while
/// targets compile for iOS, and only Xcode handles that split cleanly.
///
/// Prerequisites:
///   - Xcode 16+ with the iOS Simulator platform installed.
///   - For `--simulator`: an iOS Simulator runtime matching the SDK
///     installed via `Xcode > Settings > Platforms`.
///   - For device: a provisioning profile and `--sign <identity>`.
struct IPABundler {
    let manifest: PWAManifest
    let projectRoot: URL
    let outputDir: URL
    let signIdentity: String?
    let simulator: Bool

    func build() async throws -> URL {
        let derived = outputDir.appendingPathComponent("ios-derived")
        let destination = simulator
            ? "generic/platform=iOS Simulator"
            : "generic/platform=iOS"
        let configuration = "Release"

        var args = [
            "xcodebuild",
            "-scheme", manifest.name,
            "-workspace", projectRoot.path,
            "-destination", destination,
            "-configuration", configuration,
            "-derivedDataPath", derived.path
        ]
        if simulator {
            args.append(contentsOf: [
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGNING_ALLOWED=NO"
            ])
        } else if let identity = signIdentity {
            args.append("CODE_SIGN_IDENTITY=\(identity)")
        }
        args.append("build")

        try await Shell.run("/usr/bin/env", args)

        // SwiftPM executable targets compile to a bare Mach-O, not an .app —
        // xcodebuild puts it (plus any SwiftPM resource bundles) in:
        //   <derived>/Build/Products/<Configuration>-iphonesimulator/
        // We assemble the .app ourselves from those pieces.
        let suffix = simulator ? "iphonesimulator" : "iphoneos"
        let productsDir = derived
            .appendingPathComponent("Build/Products")
            .appendingPathComponent("\(configuration)-\(suffix)")
        let binary = productsDir.appendingPathComponent(manifest.name)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BundlerError.binaryMissing(binary)
        }

        let app = try await assembleApp(binary: binary, productsDir: productsDir)

        if simulator {
            // Adhoc-sign so the simulator will accept it.
            try await Shell.run("/usr/bin/env", ["codesign", "--force", "--sign", "-", app.path])
            print("""
            note: install + launch with:
              xcrun simctl boot "iPhone 16" 2>/dev/null || true
              xcrun simctl install booted "\(app.path)"
              xcrun simctl launch booted \(manifest.ios?.bundleIdentifier ?? manifest.id)
            """)
            return app
        }

        // Device build: codesign, then assemble Payload/ → .ipa.
        if let identity = signIdentity {
            try await Shell.run("/usr/bin/env", ["codesign", "--force", "--sign", identity, app.path])
        } else {
            print("note: not signed. Pass --sign <identity> for an installable build.")
        }
        let payload = outputDir.appendingPathComponent("Payload")
        if FileManager.default.fileExists(atPath: payload.path) {
            try FileManager.default.removeItem(at: payload)
        }
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: app,
            to: payload.appendingPathComponent("\(manifest.name).app")
        )
        let ipa = outputDir.appendingPathComponent("\(manifest.name).ipa")
        if FileManager.default.fileExists(atPath: ipa.path) {
            try FileManager.default.removeItem(at: ipa)
        }
        try await Shell.run("/usr/bin/env", ["zip", "-r", ipa.path, "Payload"], cwd: outputDir)
        return ipa
    }

    /// Lay out the `.app` from xcodebuild's loose products: copy the binary,
    /// the SwiftPM resource bundles (e.g. `bridge.js`), the project's `web/`
    /// directory, and write `Info.plist`. iOS bundles are flat — no
    /// `Contents/MacOS` wrapper.
    private func assembleApp(binary: URL, productsDir: URL) async throws -> URL {
        let fm = FileManager.default
        let app = outputDir.appendingPathComponent("\(manifest.name).app")
        if fm.fileExists(atPath: app.path) {
            try fm.removeItem(at: app)
        }
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try fm.copyItem(at: binary, to: app.appendingPathComponent(manifest.name))

        // Launch screen: if the manifest has a PNG icon, compile a
        // storyboard that centers it on a black background. Otherwise
        // fall back to the system-default empty UILaunchScreen.
        let storyboardName = await compileLaunchScreen(into: app)

        try InfoPlistGenerator.iOS(manifest: manifest, launchStoryboardName: storyboardName)
            .write(to: app.appendingPathComponent("Info.plist"))

        // SwiftPM resource bundles (e.g. swift-pwa_SwiftPWACore.bundle holding bridge.js).
        for entry in (try? fm.contentsOfDirectory(atPath: productsDir.path)) ?? []
            where entry.hasSuffix(".bundle")
        {
            try fm.copyItem(
                at: productsDir.appendingPathComponent(entry),
                to: app.appendingPathComponent(entry)
            )
        }

        // Project's web/ directory.
        let webSrc = projectRoot.appendingPathComponent(manifest.web.directory)
        if fm.fileExists(atPath: webSrc.path) {
            try fm.copyItem(at: webSrc, to: app.appendingPathComponent("web"))
        }
        return app
    }

    /// Best-effort: build a launch storyboard from `manifest.icon` if it's a
    /// PNG. Drops `LaunchIcon.png` into the bundle root so the storyboard's
    /// `image="LaunchIcon"` reference resolves via `UIImage(named:)` without
    /// needing a compiled asset catalog. Returns the storyboard name to
    /// write into `UILaunchStoryboardName`, or `nil` to fall back to the
    /// system-default launch screen.
    private func compileLaunchScreen(into app: URL) async -> String? {
        guard let iconPath = manifest.icon else { return nil }
        let iconURL = projectRoot.appendingPathComponent(iconPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: iconURL.path),
              iconURL.pathExtension.lowercased() == "png"
        else { return nil }

        let bundledIcon = app.appendingPathComponent("LaunchIcon.png")
        do {
            try fm.copyItem(at: iconURL, to: bundledIcon)

            let tmp = fm.temporaryDirectory
                .appendingPathComponent("swift-pwa-storyboard-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let sbInput = tmp.appendingPathComponent("LaunchScreen.storyboard")
            try Self.launchStoryboardXML.write(to: sbInput, atomically: true, encoding: .utf8)
            let sbOutput = app.appendingPathComponent("LaunchScreen.storyboardc")

            try await Shell.run(
                "/usr/bin/env",
                ["xcrun", "ibtool", "--compile", sbOutput.path, sbInput.path]
            )
            return "LaunchScreen"
        } catch {
            try? fm.removeItem(at: bundledIcon)
            print("note: launch screen build failed (\(error)); using system default.")
            return nil
        }
    }

    /// Black background, centered `UIImageView` referencing the loose
    /// `LaunchIcon.png` we drop next to the bundle. Sized to 40 % of the
    /// view's width, with a 1:1 aspect ratio. The format is the standard
    /// IB launch-screen XML — Xcode emits something near-identical.
    private static let launchStoryboardXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" \
    toolsVersion="22689" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" \
    useAutolayout="YES" launchScreen="YES" useTraitCollections="YES" useSafeAreas="YES" \
    colorMatched="YES" initialViewController="VC1">
        <dependencies>
            <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="22689"/>
            <capability name="Safe area layout guides" minToolsVersion="9.0"/>
        </dependencies>
        <scenes>
            <scene sceneID="SC1">
                <objects>
                    <viewController id="VC1" sceneMemberID="viewController">
                        <view key="view" contentMode="scaleToFill" id="V1">
                            <rect key="frame" x="0.0" y="0.0" width="402" height="874"/>
                            <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                            <subviews>
                                <imageView clipsSubviews="YES" userInteractionEnabled="NO" \
    contentMode="scaleAspectFit" image="LaunchIcon" \
    translatesAutoresizingMaskIntoConstraints="NO" id="ICON1"/>
                            </subviews>
                            <viewLayoutGuide key="safeArea" id="SA1"/>
                            <color key="backgroundColor" red="0.0" green="0.0" blue="0.0" alpha="1" \
    colorSpace="custom" customColorSpace="sRGB"/>
                            <constraints>
                                <constraint firstItem="ICON1" firstAttribute="centerX" \
    secondItem="V1" secondAttribute="centerX" id="cx"/>
                                <constraint firstItem="ICON1" firstAttribute="centerY" \
    secondItem="V1" secondAttribute="centerY" id="cy"/>
                                <constraint firstItem="ICON1" firstAttribute="width" \
    secondItem="V1" secondAttribute="width" multiplier="0.4" id="w"/>
                                <constraint firstItem="ICON1" firstAttribute="height" \
    secondItem="ICON1" secondAttribute="width" id="h"/>
                            </constraints>
                        </view>
                    </viewController>
                    <placeholder placeholderIdentifier="IBFirstResponder" id="FR1" \
    userLabel="First Responder" sceneMemberID="firstResponder"/>
                </objects>
            </scene>
        </scenes>
    </document>
    """
}
