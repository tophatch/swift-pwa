import Foundation
@testable import SwiftPWACore
import Testing

/// Pins the manifest-target key format for every supported `os` /
/// `arch` / package-format combination. The runtime computes one of
/// these strings at startup and uses it to look up its entry in the
/// publisher's `UpdateManifest.platforms` table; a drift between the
/// publisher's target name and the runtime's target name silently
/// breaks updates ("no update available" forever), so the values
/// here are *contracts* — not implementation details — and the test
/// is here to catch a rename before it ships.
@Suite("UpdaterTarget format")
struct UpdaterTargetTests {
    @Test("macOS has no package-format suffix (single first-class artifact)")
    func macOSFormat() {
        #expect(UpdaterTarget.make(os: "darwin", arch: "aarch64") == "darwin-aarch64")
        #expect(UpdaterTarget.make(os: "darwin", arch: "x86_64") == "darwin-x86_64")
    }

    @Test("iOS uses the 'enterprise' package suffix")
    func iOSFormat() {
        #expect(
            UpdaterTarget.make(os: "ios", arch: "aarch64", packageFormat: "enterprise")
                == "ios-aarch64-enterprise"
        )
    }

    @Test("Linux uses the 'appimage' package suffix")
    func linuxFormat() {
        #expect(
            UpdaterTarget.make(os: "linux", arch: "x86_64", packageFormat: "appimage")
                == "linux-x86_64-appimage"
        )
        #expect(
            UpdaterTarget.make(os: "linux", arch: "aarch64", packageFormat: "appimage")
                == "linux-aarch64-appimage"
        )
    }

    @Test("Windows uses 'msix' or 'portable' depending on the install mode")
    func windowsFormat() {
        #expect(
            UpdaterTarget.make(os: "windows", arch: "x86_64", packageFormat: "msix")
                == "windows-x86_64-msix"
        )
        #expect(
            UpdaterTarget.make(os: "windows", arch: "x86_64", packageFormat: "portable")
                == "windows-x86_64-portable"
        )
    }

    @Test("Android uses the 'apk' package suffix")
    func androidFormat() {
        #expect(
            UpdaterTarget.make(os: "android", arch: "aarch64", packageFormat: "apk")
                == "android-aarch64-apk"
        )
        #expect(
            UpdaterTarget.make(os: "android", arch: "x86_64", packageFormat: "apk")
                == "android-x86_64-apk"
        )
    }

    @Test("Empty package format drops the suffix entirely")
    func emptyPackageFormatDropped() {
        // A defensive guard against accidentally writing `darwin-aarch64-`
        // (note the trailing dash) for callers that pass an empty
        // string instead of nil.
        #expect(UpdaterTarget.make(os: "darwin", arch: "aarch64", packageFormat: "") == "darwin-aarch64")
    }

    @Test("Current host's target string is non-empty and uses the documented shape")
    func currentHostShape() {
        let target = UpdaterTarget.current(packageFormat: "apk")
        // We can't know the test host's OS / arch in advance, but the
        // shape contract (`<os>-<arch>-<pkg>`, hyphenated, no trailing
        // dash, at least three segments when a package format is
        // provided) holds regardless. A regression that returns "unknown"
        // for a supported host shows up here as a missing match against
        // the known platform identifier set.
        let segments = target.split(separator: "-")
        #expect(segments.count >= 3, "target should have at least <os>-<arch>-<pkg> segments, got '\(target)'")
        // The OS prefix must be one of the platforms we ship a
        // backend for — drift to "unknown" would mean the runtime
        // won't match its publisher's manifest entry.
        let knownOS = ["darwin", "ios", "linux", "windows", "android"]
        #expect(
            knownOS.contains(where: { target.hasPrefix("\($0)-") }),
            "current() returned unsupported OS prefix in '\(target)'"
        )
    }
}
