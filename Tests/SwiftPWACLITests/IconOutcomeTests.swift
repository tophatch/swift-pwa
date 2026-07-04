@testable import SwiftPWACLISupport
import Testing

@Suite("icon outcome reporting")
struct IconOutcomeTests {
    @Test("a bundled icon shows the source, and the size detail when present")
    func bundled() {
        #expect(IconOutcome.bundled(source: "web/icon.png", detail: "7 sizes").line
            == "app icon ← web/icon.png (7 sizes)")
        #expect(IconOutcome.bundled(source: "icon.png", detail: nil).line
            == "app icon ← icon.png")
    }

    @Test("no icon set points at the platform default")
    func noneSet() {
        #expect(IconOutcome.noneSet.line == "no icon set in pwa.json — using the platform default")
    }

    @Test("a non-PNG icon distinguishes placeholder from platform-default")
    func notPNG() {
        #expect(IconOutcome.notPNG(source: "icon.svg", placeholder: true).line
            == "icon 'icon.svg' isn't a PNG — using a placeholder (convert to PNG for a real app icon)")
        #expect(IconOutcome.notPNG(source: "icon.svg", placeholder: false).line
            == "icon 'icon.svg' isn't a PNG — using the platform default (convert to PNG for a real app icon)")
    }

    @Test("a missing icon file reports not found")
    func notFound() {
        #expect(IconOutcome.notFound(source: "icon.png", placeholder: true).line
            == "icon 'icon.png' not found — using a placeholder")
        #expect(IconOutcome.notFound(source: "icon.png", placeholder: false).line
            == "icon 'icon.png' not found — using the platform default")
    }

    @Test("a tool failure notes the build is still fine")
    func toolFailed() {
        #expect(IconOutcome.toolFailed(source: "icon.png", reason: "actool unavailable").line
            == "app icon from 'icon.png' skipped (actool unavailable); the build is otherwise fine")
    }
}
