import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The driver handshake parse, and where a driven build's own output goes.
@Suite("drive launch plumbing")
struct DriveLaunchTests {
    /// Driving an iOS target needs `xcrun` and usbmuxd, so those paths — and
    /// the option validation guarding them — only exist on macOS.
    static var isMacOS: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    @Test("parses the announcement line")
    func parsesAnnouncement() throws {
        let parsed = try #require(
            HandshakeReader.parse("swift-pwa driver listening port=51234 token=deadbeef")
        )
        #expect(parsed.port == 51234)
        #expect(parsed.token == "deadbeef")
    }

    /// The iOS Simulator relays the app's stdout through a PTY, so the line
    /// arrives CRLF-terminated. A token carrying a trailing `\r` connects fine
    /// and then has every frame refused — "missing or incorrect token" — which
    /// reads like a driver bug rather than a line-ending one.
    @Test("tolerates the CRLF the simulator's console relay adds")
    func parsesCRLFLine() throws {
        let parsed = try #require(
            HandshakeReader.parse("swift-pwa driver listening port=51234 token=deadbeef\r")
        )
        #expect(parsed.token == "deadbeef")
        #expect(parsed.port == 51234)
    }

    @Test("ignores anything that isn't the announcement")
    func ignoresOtherOutput() {
        #expect(HandshakeReader.parse("some app log line") == nil)
        #expect(HandshakeReader.parse("swift-pwa driver listening port=51234") == nil)
    }

    /// A verb's result is the only thing allowed on stdout, so the build's own
    /// chatter goes to stderr — the same reason the app's output does. (Asserted
    /// by identity, not by file descriptor: `FileHandle.fileDescriptor` is
    /// unavailable on Windows, and the test targets compile there.)
    @Test("build progress never goes to stdout")
    func progressSinkAvoidsStdout() {
        #expect(LaunchedApp.progressSink === FileHandle.standardError)
    }

    /// `--target ios` means the *device* now, and the simulator is the one you
    /// ask for. Before device driving existed the two were the same thing, so a
    /// regression here would silently send a device run to the simulator (or the
    /// reverse) rather than failing.
    ///
    /// macOS-only because it goes through `parse`, which runs `validate()` —
    /// and validation refuses both iOS targets off-macOS, which is correct:
    /// neither `xcrun` nor usbmuxd exists there.
    @Test("--target ios picks the device, --simulator picks the simulator", .enabled(if: isMacOS))
    func iosTargetResolution() throws {
        let device = try DriveInfo.parse(["--target", "ios"])
        #expect(device.options.runsOnDevice)
        #expect(!device.options.runsOnSimulator)

        let simulator = try DriveInfo.parse(["--target", "ios", "--simulator"])
        #expect(simulator.options.runsOnSimulator)
        #expect(!simulator.options.runsOnDevice)

        let bare = try DriveInfo.parse(["--simulator"])
        #expect(bare.options.runsOnSimulator)
        #expect(!bare.options.runsOnDevice)

        let host = try DriveInfo.parse([])
        #expect(!host.options.runsOnDevice)
        #expect(!host.options.runsOnSimulator)
    }
}

#if os(macOS)

    /// The usbmux relay that reaches an app's control socket on a physical iOS
    /// device. Only the pure wire encoding is unit-testable — the rest needs a
    /// cabled device — but that encoding is the part it's easy to get silently
    /// wrong.
    @Suite("usbmux wire format")
    struct USBMuxTests {
        /// usbmuxd passes the port through to the device as a network-order
        /// `sin_port` without converting it, so it has to arrive byte-swapped.
        /// Getting this wrong asks for a *different, valid-looking* port, which
        /// is refused exactly the way a not-listening app is.
        @Test("a port is byte-swapped into network order")
        func portIsByteSwapped() {
            #expect(USBMux.wirePort(56456) == 35036) // 0xDC88 → 0x88DC
            #expect(USBMux.wirePort(62078) == 32498) // lockdownd, 0xF27E → 0x7EF2
            #expect(USBMux.wirePort(0x0100) == 0x0001)
            #expect(USBMux.wirePort(0x0001) == 0x0100)
        }

        /// Driving reaches the app through the device's own loopback, which only
        /// the USB transport relays into — a Wi-Fi-paired device shows up here
        /// but can't carry a driver session, and has to be told apart.
        @Test("only a USB-attached device can carry a driver session")
        func onlyUSBCounts() {
            #expect(USBMux.Device(id: 1, serial: "UDID", connectionType: "USB").isUSB)
            #expect(!USBMux.Device(id: 1, serial: "UDID", connectionType: "Network").isUSB)
            #expect(!USBMux.Device(id: 1, serial: "UDID", connectionType: "Unknown").isUSB)
        }
    }

#endif
