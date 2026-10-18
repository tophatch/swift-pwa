@testable import SwiftPWACore
import Testing

@Suite("SWIFT_PWA_WEB_DATA")
struct WebDataTests {
    @Test("unset, empty and persistent mean the shared persistent store")
    func persistent() {
        #expect(WebData.ephemeral(nil) == false)
        #expect(WebData.ephemeral("") == false)
        #expect(WebData.ephemeral("persistent") == false)
    }

    @Test("ephemeral asks for an in-memory store, whatever its case or padding")
    func ephemeral() {
        #expect(WebData.ephemeral("ephemeral") == true)
        #expect(WebData.ephemeral(" Ephemeral ") == true)
    }

    @Test("anything else isn't a setting, so it can be reported rather than guessed at")
    func unknown() {
        #expect(WebData.ephemeral("ephermeral") == nil)
        #expect(WebData.ephemeral("1") == nil)
        #expect(WebData.ephemeral("/tmp/web") == nil)
    }
}
