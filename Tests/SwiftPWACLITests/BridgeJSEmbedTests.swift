import Foundation
@testable import SwiftPWACLISupport
import SwiftPWACore
import Testing

/// `BridgeJSData` is bridge.js base64-embedded into the CLI so the Android
/// bundler can stage it without `SwiftPWACore.Bundle.module` (which traps in a
/// prebuilt single-file binary). These guard that embedded copy.
@Suite("bridge.js CLI embed")
struct BridgeJSEmbedTests {
    @Test("embedded bridge.js decodes to the runtime contract")
    func decodes() {
        let js = BridgeJSData.source
        #expect(!js.isEmpty)
        #expect(js.contains("__SWIFT_PWA__"))
        #expect(js.contains("invoke"))
    }

    /// Drift guard: the embedded copy must match the canonical
    /// SwiftPWACore/Resources/bridge.js. If this fails, bridge.js was edited
    /// without re-running Scripts/regenerate-bridge-js.sh — otherwise a prebuilt
    /// CLI would stage a stale bridge into Android APKs while the runtime uses
    /// the fresh one. (Runs in `swift test`, where Core's bundle is present, so
    /// BridgeScript.source() resolves.)
    @Test("embedded bridge.js matches the canonical Core resource")
    func matchesCanonical() throws {
        #expect(try BridgeJSData.source == BridgeScript.source())
    }
}
