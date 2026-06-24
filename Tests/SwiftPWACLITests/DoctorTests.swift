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
}
