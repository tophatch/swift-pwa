import Foundation
@testable import SwiftPWACore
import Testing
#if os(Windows)
    import WinSDK
#endif

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
        setEnvironment(key, value)
        defer { setEnvironment(key, previous) }
        return try body()
    }

    /// `setenv` / `unsetenv` aren't in scope on Windows. Go through
    /// `SetEnvironmentVariableW` there rather than the CRT's `_putenv_s`,
    /// because it's the Win32 environment *block* that
    /// `ProcessInfo.processInfo.environment` reads — the CRT keeps its own copy,
    /// which wouldn't be visible to the code under test.
    private func setEnvironment(_ key: String, _ value: String?) {
        #if os(Windows)
            key.withCString(encodedAs: UTF16.self) { name in
                if let value {
                    value.withCString(encodedAs: UTF16.self) { _ = SetEnvironmentVariableW(name, $0) }
                } else {
                    // A null value deletes the variable.
                    _ = SetEnvironmentVariableW(name, nil)
                }
            }
        #else
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        #endif
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
