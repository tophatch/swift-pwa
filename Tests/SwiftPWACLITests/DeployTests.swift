import ArgumentParser
@testable import SwiftPWACLISupport
import Testing

@Suite("swift-pwa deploy")
struct DeployTests {
    // MARK: - adb devices parsing

    @Test("parses a single connected device")
    func singleDevice() {
        let out = """
        List of devices attached
        10.0.0.2:5555\tdevice
        """
        #expect(Deploy.parseAdbDeviceSerials(out) == ["10.0.0.2:5555"])
    }

    @Test("keeps an mDNS/TLS serial that contains a space (tab-separated, not whitespace)")
    func mdnsSerialWithSpace() {
        // Real `adb devices` output: the mDNS/TLS transport advertises a serial
        // with a space in it. A whitespace split would drop it and silently hide
        // a multi-device ambiguity — this is the bug the tab split fixes.
        let out = """
        List of devices attached
        10.0.0.2:5555\tdevice
        adb-SERIAL1234-AbCdEf (2)._adb-tls-connect._tcp\tdevice
        """
        #expect(Deploy.parseAdbDeviceSerials(out) == [
            "10.0.0.2:5555",
            "adb-SERIAL1234-AbCdEf (2)._adb-tls-connect._tcp"
        ])
    }

    @Test("excludes offline / unauthorized devices")
    func excludesNonReady() {
        let out = """
        List of devices attached
        emulator-5554\tdevice
        0123456789ABCDEF\toffline
        FEDCBA9876543210\tunauthorized
        """
        #expect(Deploy.parseAdbDeviceSerials(out) == ["emulator-5554"])
    }

    @Test("no devices → empty")
    func noDevices() {
        #expect(Deploy.parseAdbDeviceSerials("List of devices attached\n").isEmpty)
        #expect(Deploy.parseAdbDeviceSerials("").isEmpty)
    }

    // MARK: - argument surface

    @Test("registered as a subcommand and parses the deploy-specific flags")
    func parsesFlags() throws {
        let deploy = try Deploy.parse([
            "--target", "android", "--device", "192.168.0.5:5555",
            "--no-build", "--no-launch", "--no-reinstall", "--android-abis", "arm64-v8a"
        ])
        #expect(deploy.target == .android)
        #expect(deploy.device == "192.168.0.5:5555")
        #expect(deploy.noBuild)
        #expect(deploy.launch == false)
        #expect(deploy.reinstall == false)
        #expect(deploy.androidAbis == "arm64-v8a")
    }

    @Test("launch and reinstall default to true")
    func defaults() throws {
        let deploy = try Deploy.parse(["--target", "macos"])
        #expect(deploy.launch)
        #expect(deploy.reinstall)
        #expect(deploy.noBuild == false)
    }

    // MARK: - Android SDK → Swift version extraction (drives toolchain auto-select)

    #if os(macOS)
        @Test("extracts the Swift release from an Android SDK bundle name")
        func androidSDKVersion() {
            #expect(
                Build.swiftReleaseVersion(in: "swift-6.2-RELEASE-android-0.1", marker: "-RELEASE-android") == "6.2"
            )
            #expect(
                Build.swiftReleaseVersion(in: "swift-6.10-RELEASE-android-0.3", marker: "-RELEASE-android") == "6.10"
            )
        }

        @Test("ignores non-matching / malformed names")
        func androidSDKVersionRejects() {
            #expect(Build.swiftReleaseVersion(in: "swift-6.2-RELEASE.xctoolchain", marker: "-RELEASE-android") == nil)
            #expect(Build.swiftReleaseVersion(in: "some-other-bundle", marker: "-RELEASE-android") == nil)
            #expect(Build.swiftReleaseVersion(in: "swift-x.y-RELEASE-android", marker: "-RELEASE-android") == nil)
        }
    #endif
}
