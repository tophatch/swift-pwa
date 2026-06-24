import ArgumentParser
@testable import SwiftPWACLISupport
import Testing

@Suite("swift-pwa doctor")
struct DoctorTests {
    @Test("parses an explicit --target")
    func parsesTarget() throws {
        let cmd = try Doctor.parse(["--target", "ios"])
        #expect(cmd.target == .ios)
    }

    @Test("defaults --target to nil (resolved to the host at run time)")
    func defaultsToHost() throws {
        let cmd = try Doctor.parse([])
        #expect(cmd.target == nil)
    }

    @Test("reads the generated-shell version stamp")
    func readsStamp() {
        let stamped = "// swift-pwa-generated: v1.2.3\nimport SwiftPWA\n"
        #expect(Doctor.stampedVersion(in: stamped) == "1.2.3")
    }

    @Test("tolerates a stamp without the leading v")
    func stampWithoutV() {
        #expect(Doctor.stampedVersion(in: "// swift-pwa-generated: 0.9.0\n") == "0.9.0")
    }

    @Test("returns nil for an unstamped source")
    func noStamp() {
        #expect(Doctor.stampedVersion(in: "import SwiftPWA\nstruct App {}\n") == nil)
    }
}
