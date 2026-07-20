import Foundation

/// Mints a provisioning profile for a **free personal Apple team**, which has
/// no portal-generated profile for `IOSSigning.resolve` to find. Free teams can
/// only obtain a profile by building an app-typed target with automatic signing
/// against a specific device — Xcode then registers the device, creates the App
/// ID, and drops `embedded.mobileprovision` inside the built `.app`. A swift-pwa
/// app is a SwiftPM executable, not an app target, so this never fires for it;
/// the minter runs the same dance on a throwaway one-file app project sharing
/// the real app's bundle id, then hands the resulting profile + entitlements
/// back to the normal embed + re-sign path.
///
/// This is the CLI-internalised form of the shell "minter" free-team adopters
/// have maintained by hand. macOS-only in effect (it shells out to
/// `xcodebuild`); only reached on the iOS device build path, which already
/// requires a Mac.
///
/// The project-file generation is a pure function (`projectFiles`) so it's
/// unit-testable without a device or an Apple account, mirroring `IOSSigning`.
enum PersonalTeamProfileMinter {
    struct Minted {
        let profile: URL
        let entitlements: URL?
    }

    // MARK: - Pure: throwaway project files

    /// The files of the throwaway Xcode app project, keyed by path relative to
    /// the project root. A single-file SwiftUI app with the real app's bundle id
    /// and `CODE_SIGN_STYLE = Automatic` + the team — the minimum that makes
    /// Xcode mint a profile. Ships an explicit `.xcscheme` because Xcode 16
    /// dropped the implicit-scheme synthesis `xcodebuild -scheme` relied on.
    static func projectFiles(bundleID: String, team: String) -> [String: String] {
        [
            "App.swift": appSwift,
            "Minter.xcodeproj/project.pbxproj": pbxproj(bundleID: bundleID, team: team),
            "Minter.xcodeproj/xcshareddata/xcschemes/Minter.xcscheme": xcscheme
        ]
    }

    private static let appSwift = """
    import SwiftUI

    @main
    struct MinterApp: App {
        var body: some Scene {
            WindowGroup { Text("") }
        }
    }
    """

    // Stable, internally-consistent object ids (24 hex chars each). The native
    // target's id is referenced by the .xcscheme's BlueprintIdentifier.
    private static let idProject = "AA00000000000000000000A0"
    private static let idTarget = "AA00000000000000000000A1"
    private static let idMainGroup = "AA00000000000000000000A2"
    private static let idProductGroup = "AA00000000000000000000A3"
    private static let idSources = "AA00000000000000000000A4"
    private static let idFrameworks = "AA00000000000000000000A5"
    private static let idResources = "AA00000000000000000000A6"
    private static let idAppSwiftRef = "AA00000000000000000000A7"
    private static let idAppSwiftBuild = "AA00000000000000000000A8"
    private static let idProductRef = "AA00000000000000000000A9"
    private static let idProjectCfgList = "AA00000000000000000000B0"
    private static let idTargetCfgList = "AA00000000000000000000B1"
    private static let idProjectRelease = "AA00000000000000000000B2"
    private static let idTargetRelease = "AA00000000000000000000B3"

    private static func pbxproj(bundleID: String, team: String) -> String {
        """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 56;
        \tobjects = {

        /* Begin PBXBuildFile section */
        \t\t\(idAppSwiftBuild) /* App.swift in Sources */ = {isa = PBXBuildFile; fileRef = \(
            idAppSwiftRef
        ) /* App.swift */; };
        /* End PBXBuildFile section */

        /* Begin PBXFileReference section */
        \t\t\(
            idAppSwiftRef
        ) /* App.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; };
        \t\t\(
            idProductRef
        ) /* Minter.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Minter.app; sourceTree = BUILT_PRODUCTS_DIR; };
        /* End PBXFileReference section */

        /* Begin PBXFrameworksBuildPhase section */
        \t\t\(
            idFrameworks
        ) /* Frameworks */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        /* End PBXFrameworksBuildPhase section */

        /* Begin PBXGroup section */
        \t\t\(idMainGroup) = {isa = PBXGroup; children = (\(idAppSwiftRef) /* App.swift */, \(
            idProductGroup
        ) /* Products */, ); sourceTree = "<group>"; };
        \t\t\(idProductGroup) /* Products */ = {isa = PBXGroup; children = (\(
            idProductRef
        ) /* Minter.app */, ); name = Products; sourceTree = "<group>"; };
        /* End PBXGroup section */

        /* Begin PBXNativeTarget section */
        \t\t\(idTarget) /* Minter */ = {isa = PBXNativeTarget; buildConfigurationList = \(
            idTargetCfgList
        ) /* Build configuration list for PBXNativeTarget "Minter" */; buildPhases = (\(idSources) /* Sources */, \(
            idFrameworks
        ) /* Frameworks */, \(
            idResources
        ) /* Resources */, ); buildRules = (); dependencies = (); name = Minter; productName = Minter; productReference = \(
            idProductRef
        ) /* Minter.app */; productType = "com.apple.product-type.application"; };
        /* End PBXNativeTarget section */

        /* Begin PBXProject section */
        \t\t\(
            idProject
        ) /* Project object */ = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {\(
            idTarget
        ) = {CreatedOnToolsVersion = 16.0; }; }; }; buildConfigurationList = \(
            idProjectCfgList
        ) /* Build configuration list for PBXProject "Minter" */; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = \(
            idMainGroup
        ); productRefGroup = \(idProductGroup) /* Products */; projectDirPath = ""; projectRoot = ""; targets = (\(
            idTarget
        ) /* Minter */, ); };
        /* End PBXProject section */

        /* Begin PBXResourcesBuildPhase section */
        \t\t\(
            idResources
        ) /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        /* End PBXResourcesBuildPhase section */

        /* Begin PBXSourcesBuildPhase section */
        \t\t\(idSources) /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\(
            idAppSwiftBuild
        ) /* App.swift in Sources */, ); runOnlyForDeploymentPostprocessing = 0; };
        /* End PBXSourcesBuildPhase section */

        /* Begin XCBuildConfiguration section */
        \t\t\(
            idProjectRelease
        ) /* Release */ = {isa = XCBuildConfiguration; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; ENABLE_STRICT_OBJC_MSGSEND = YES; GCC_NO_COMMON_BLOCKS = YES; IPHONEOS_DEPLOYMENT_TARGET = 16.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; VALIDATE_PRODUCT = YES; }; name = Release; };
        \t\t\(
            idTargetRelease
        ) /* Release */ = {isa = XCBuildConfiguration; buildSettings = {ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS = NO; CODE_SIGN_IDENTITY = "Apple Development"; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; DEVELOPMENT_TEAM = \(
            team
        ); GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; MARKETING_VERSION = 1.0; PRODUCT_BUNDLE_IDENTIFIER = "\(
            bundleID
        )"; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = "1,2"; }; name = Release; };
        /* End XCBuildConfiguration section */

        /* Begin XCConfigurationList section */
        \t\t\(
            idProjectCfgList
        ) /* Build configuration list for PBXProject "Minter" */ = {isa = XCConfigurationList; buildConfigurations = (\(
            idProjectRelease
        ) /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        \t\t\(
            idTargetCfgList
        ) /* Build configuration list for PBXNativeTarget "Minter" */ = {isa = XCConfigurationList; buildConfigurations = (\(
            idTargetRelease
        ) /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        /* End XCConfigurationList section */
        \t};
        \trootObject = \(idProject) /* Project object */;
        }
        """
    }

    private static let xcscheme = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="1600" version="1.7">
       <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
          <BuildActionEntries>
             <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
                <BuildableReference
                   BuildableIdentifier="primary"
                   BlueprintIdentifier="\(idTarget)"
                   BuildableName="Minter.app"
                   BlueprintName="Minter"
                   ReferencedContainer="container:Minter.xcodeproj">
                </BuildableReference>
             </BuildActionEntry>
          </BuildActionEntries>
       </BuildAction>
       <LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
          <BuildableProductRunnable runnableDebuggingMode="0">
             <BuildableReference
                BuildableIdentifier="primary"
                BlueprintIdentifier="\(idTarget)"
                BuildableName="Minter.app"
                BlueprintName="Minter"
                ReferencedContainer="container:Minter.xcodeproj">
             </BuildableReference>
          </BuildableProductRunnable>
       </LaunchAction>
       <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES">
       </ArchiveAction>
    </Scheme>
    """

    // MARK: - IO: build the project + extract the profile

    /// Build the throwaway project against `deviceUDID` with device
    /// registration, then pull the minted `embedded.mobileprovision` (and its
    /// entitlements) out of the built `.app`, copying both into `scratch` so
    /// they outlive the temp project. Streams `xcodebuild` output live.
    static func mint(bundleID: String, team: String, deviceUDID: String, scratch: URL) async throws -> Minted {
        let fm = FileManager.default
        let projectRoot = fm.temporaryDirectory.appendingPathComponent("swift-pwa-minter-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: projectRoot) }

        for (relativePath, contents) in projectFiles(bundleID: bundleID, team: team) {
            let dest = projectRoot.appendingPathComponent(relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: dest, atomically: true, encoding: .utf8)
        }

        let derivedData = projectRoot.appendingPathComponent("DerivedData")
        print("swift-pwa: minting a provisioning profile for team \(team) on device \(deviceUDID) …")
        try await Shell.run("/usr/bin/env", [
            "xcodebuild",
            "-project", projectRoot.appendingPathComponent("Minter.xcodeproj").path,
            "-scheme", "Minter",
            "-configuration", "Release",
            "-destination", "id=\(deviceUDID)",
            "-derivedDataPath", derivedData.path,
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "build"
        ])

        let builtApp = derivedData
            .appendingPathComponent("Build/Products/Release-iphoneos/Minter.app")
        let embedded = builtApp.appendingPathComponent("embedded.mobileprovision")
        guard fm.fileExists(atPath: embedded.path) else {
            throw BundlerError.profileMintFailed(bundleID: bundleID, team: team)
        }

        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let profileDest = scratch.appendingPathComponent("swift-pwa-minted-\(bundleID).mobileprovision")
        if fm.fileExists(atPath: profileDest.path) { try fm.removeItem(at: profileDest) }
        try fm.copyItem(at: embedded, to: profileDest)

        // Extract the entitlements the same way IOSSigning.resolve does, so the
        // re-sign step signs with the profile's own entitlements.
        var entitlementsURL: URL?
        if let xml = try? await Shell.capture(
            "/usr/bin/env", ["security", "cms", "-D", "-i", profileDest.path], discardStderr: true
        ),
            let data = xml.data(using: .utf8),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let ent = IOSSigning.entitlements(from: plist),
            let entData = try? PropertyListSerialization.data(fromPropertyList: ent, format: .xml, options: 0)
        {
            let dest = scratch.appendingPathComponent("swift-pwa-minted-\(bundleID).entitlements")
            try? entData.write(to: dest)
            entitlementsURL = dest
        }

        return Minted(profile: profileDest, entitlements: entitlementsURL)
    }
}
