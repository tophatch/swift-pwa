import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The driver handshake parse, and where a driven build's own output goes.
@Suite("drive launch plumbing")
struct DriveLaunchTests {
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
    /// chatter goes to stderr — the same reason the app's output does.
    @Test("build progress goes to stderr when lifecycle logging is stdout")
    func progressSinkAvoidsStdout() {
        #expect(
            LaunchedApp.progressSink(for: .standardOutput).fileDescriptor
                == FileHandle.standardError.fileDescriptor
        )
        // An explicit sink (the MCP server passes stderr) is used as given.
        #expect(
            LaunchedApp.progressSink(for: .standardError).fileDescriptor
                == FileHandle.standardError.fileDescriptor
        )
    }
}
