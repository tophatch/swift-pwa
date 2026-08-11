import Foundation
@testable import SwiftPWACore
import Testing

/// `bridge.js` is base64-embedded into the binary (`BridgeJSData`) rather than
/// shipped as a SwiftPM resource, so an app bundle carries it without a resource
/// bundle beside it. These guard that embedded copy.
@Suite("bridge.js embed")
struct BridgeJSEmbedTests {
    @Test("the embedded bridge decodes to the runtime contract")
    func decodes() throws {
        let js = try BridgeScript.source()
        #expect(!js.isEmpty)
        #expect(js.contains("__SWIFT_PWA__"))
        #expect(js.contains("invoke"))
    }

    /// Drift guard: the embedded copy must match the canonical
    /// `Sources/SwiftPWACore/Resources/bridge.js`. If this fails, bridge.js was
    /// edited without re-running `Scripts/regenerate-bridge-js.sh`, so the
    /// runtime (and every app built from it) would ship the stale bridge.
    @Test("the embedded bridge matches the canonical bridge.js")
    func matchesCanonical() throws {
        let repoRoot = URL(fileURLWithPath: #filePath) // …/Tests/SwiftPWACoreTests/<this>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let canonical = repoRoot
            .appendingPathComponent("Sources/SwiftPWACore/Resources/bridge.js")
        let onDisk = try String(contentsOf: canonical, encoding: .utf8)
        #expect(try BridgeScript.source() == onDisk)
    }
}
