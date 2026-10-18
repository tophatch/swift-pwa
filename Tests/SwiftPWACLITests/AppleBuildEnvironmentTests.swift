import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("Apple build-environment Info.plist keys")
struct AppleBuildEnvironmentTests {
    @Test("DTXcode is Xcode's own encoding of its version")
    func dtXcode() {
        #expect(AppleBuildEnvironment.dtXcode("27.1") == "2710")
        #expect(AppleBuildEnvironment.dtXcode("26.6") == "2660")
        #expect(AppleBuildEnvironment.dtXcode("16.4.1") == "1641")
        #expect(AppleBuildEnvironment.dtXcode("9.4") == "0940")
    }

    @Test("xcodebuild -version parses into version and build")
    func parseXcodeVersion() throws {
        let parsed = try #require(AppleBuildEnvironment.parseXcodeVersion("Xcode 27.1\nBuild version 27A9275\n"))
        #expect(parsed.version == "27.1")
        #expect(parsed.build == "27A9275")
        #expect(AppleBuildEnvironment.parseXcodeVersion("xcode-select: error: tool 'xcodebuild' requires Xcode") == nil)
    }

    @Test("the keys match what Xcode writes for a device build")
    func deviceKeys() {
        let env = AppleBuildEnvironment(
            platformName: "iphoneos", sdkVersion: "27.1", sdkBuild: "24A94232",
            xcodeVersion: "27.1", xcodeBuild: "27A9275", machineBuild: "26A428"
        )
        let keys = env.plistKeys
        #expect(keys["DTPlatformName"] as? String == "iphoneos")
        #expect(keys["DTSDKName"] as? String == "iphoneos27.1")
        #expect(keys["DTPlatformVersion"] as? String == "27.1")
        #expect(keys["DTSDKBuild"] as? String == "24A94232")
        #expect(keys["DTXcode"] as? String == "2710")
        #expect(keys["DTXcodeBuild"] as? String == "27A9275")
        #expect(keys["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
        #expect(keys["BuildMachineOSBuild"] as? String == "26A428")
    }

    @Test("without xcodebuild the Xcode keys are left out, not invented")
    func commandLineToolsOnly() {
        let env = AppleBuildEnvironment(
            platformName: "macosx", sdkVersion: "27.1", sdkBuild: "26A428",
            xcodeVersion: nil, xcodeBuild: nil, machineBuild: "26A428"
        )
        #expect(env.plistKeys["DTXcode"] == nil)
        #expect(env.plistKeys["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"])
    }

    @Test("an info_plist passthrough still wins over a build key")
    func passthroughWins() {
        var plist = InfoPlist()
        plist["DTPlatformName"] = "custom"
        plist.addMissing(["DTPlatformName": "iphoneos", "DTSDKName": "iphoneos27.1"])
        #expect(plist["DTPlatformName"] as? String == "custom")
        #expect(plist["DTSDKName"] as? String == "iphoneos27.1")
    }
}
