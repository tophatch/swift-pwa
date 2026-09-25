import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The install retry (#260), run against a stand-in `xcrun` that answers each
/// call with a scripted `devicectl` outcome — a real dropped connection can't be
/// produced on demand. It writes the document the way `devicectl` does, to the
/// path after `--json-output`, and counts its calls.
///
/// The stand-in is a shell script, so this doesn't run on Windows, where the
/// install never runs either.
@Suite("iOS device install", .enabled(if: !isWindowsHost))
struct DeviceInstallTests {
    private static let device = IOSDeviceResolver.Device(udid: "UDID", name: "iPad", connected: true)

    /// A fresh directory holding a fake `xcrun` that plays `outcomes` in order,
    /// one per call: a fixture document to fail with, or `nil` to succeed.
    private static func fakeXcrun(_ outcomes: [Data?]) throws -> (tool: URL, calls: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-fake-xcrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, outcome) in outcomes.enumerated() {
            let document = outcome ?? Data(#"{"info":{"outcome":"success"}}"#.utf8)
            try document.write(to: dir.appendingPathComponent("\(index + 1).json"))
            if outcome != nil {
                try Data().write(to: dir.appendingPathComponent("\(index + 1).fail"))
            }
        }
        let calls = dir.appendingPathComponent("calls")
        let tool = dir.appendingPathComponent("xcrun")
        try """
        #!/bin/sh
        n=$(( $(cat "\(calls.path)" 2>/dev/null || echo 0) + 1 ))
        echo $n > "\(calls.path)"
        out=""
        while [ $# -gt 0 ]; do [ "$1" = "--json-output" ] && out="$2"; shift; done
        cp "\(dir.path)/$n.json" "$out"
        [ -e "\(dir.path)/$n.fail" ] && exit 1
        exit 0
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool, calls)
    }

    private static func callCount(_ calls: URL) -> Int {
        Int((try? String(contentsOf: calls, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    private static let app = URL(fileURLWithPath: "/tmp/Example.app")

    @Test("a dropped connection is retried once, and the retry's success is the result")
    func droppedThenInstalled() async throws {
        let fake = try Self.fakeXcrun([DeviceCtlErrorTests.disconnectedAfterConnecting, nil])
        try await DeviceInstall.install(
            app: Self.app, on: Self.device, stdoutTo: FileHandle.nullDevice, xcrun: fake.tool.path
        )
        #expect(Self.callCount(fake.calls) == 2)
    }

    @Test("a connection that drops twice fails, saying it retried")
    func droppedTwice() async throws {
        let fake = try Self.fakeXcrun([
            DeviceCtlErrorTests.connectionReset, DeviceCtlErrorTests.disconnectedAfterConnecting
        ])
        await #expect {
            try await DeviceInstall.install(
                app: Self.app, on: Self.device, stdoutTo: FileHandle.nullDevice, xcrun: fake.tool.path
            )
        } throws: { error in
            let failure = error as? DeviceInstall.Failure
            return failure?.retried == true
                && failure?.reason == "The device disconnected immediately after connecting."
        }
        #expect(Self.callCount(fake.calls) == 2)
    }

    @Test("any other failure is reported on the first attempt")
    func otherFailureNotRetried() async throws {
        let fake = try Self.fakeXcrun([DeviceCtlErrorTests.lockedTunnel, nil])
        await #expect {
            try await DeviceInstall.install(
                app: Self.app, on: Self.device, stdoutTo: FileHandle.nullDevice, xcrun: fake.tool.path
            )
        } throws: { error in
            (error as? DeviceInstall.Failure)?.retried == false
        }
        #expect(Self.callCount(fake.calls) == 1)
    }
}

#if os(Windows)
    private let isWindowsHost = true
#else
    private let isWindowsHost = false
#endif
