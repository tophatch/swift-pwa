import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// `SWIFT_PWA_INITIAL_ROUTE` normalization. The take-once behaviour itself
/// isn't exercised here: `InitialRoute.take` reads process-wide state, and a
/// test that consumed it would change the answer for every other test in the
/// same process depending on order. The per-backend wiring is verified by
/// launching an app with the variable set.
/// `.serialized` because every case here mutates one process-global
/// environment variable. Run in parallel — swift-testing's default — they
/// clobber each other's value and fail intermittently.
@Suite("InitialRoute", .serialized)
struct InitialRouteTests {
    private func withRoute<T>(_ value: String?, _ body: () throws -> T) rethrows -> T {
        let key = InitialRoute.environmentVariable
        let previous = ProcessInfo.processInfo.environment[key]
        setEnvironmentVariable(key, value)
        defer { setEnvironmentVariable(key, previous) }
        return try body()
    }

    @Test("unset means no route")
    func unset() {
        withRoute(nil) { #expect(InitialRoute.requested == nil) }
    }

    @Test("an empty or whitespace value is ignored rather than loading /")
    func empty() {
        withRoute("") { #expect(InitialRoute.requested == nil) }
        withRoute("   ") { #expect(InitialRoute.requested == nil) }
    }

    @Test("a leading slash is stripped so it can be joined onto the origin")
    func leadingSlash() {
        withRoute("/doc.html") { #expect(InitialRoute.requested == "doc.html") }
        withRoute("doc.html") { #expect(InitialRoute.requested == "doc.html") }
    }

    @Test("query and fragment survive — they're the point of a deep link")
    func queryAndFragment() {
        withRoute("/doc.html?id=42#page3") {
            #expect(InitialRoute.requested == "doc.html?id=42#page3")
        }
    }

    @Test("a nested route is fine")
    func nested() {
        withRoute("/reader/settings") { #expect(InitialRoute.requested == "reader/settings") }
    }

    @Test("a route that tries to climb out of the bundle is refused")
    func traversal() {
        withRoute("../../etc/passwd") { #expect(InitialRoute.requested == nil) }
        withRoute("/web/../../secrets") { #expect(InitialRoute.requested == nil) }
    }
}
