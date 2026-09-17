import ArgumentParser
import Foundation
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

/// The audio-session advisory. The pairing it checks — audio present, policy
/// absent — is the whole design: either half alone has to stay silent, or the
/// check becomes noise a developer learns to skip past.
@Suite("swift-pwa doctor — audio session policy")
struct DoctorAudioPolicyTests {
    private func project(web: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doctor-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("web"), withIntermediateDirectories: true
        )
        let manifest = """
        {"id":"com.example.a","name":"A","version":"1.0.0",
         "web":{"directory":"web","entry":"index.html"},
         "window":{"title":"A","width":800,"height":600,"resizable":true,"fullscreen":false}}
        """
        try manifest
            .write(to: root.appendingPathComponent("pwa.json"), atomically: true, encoding: .utf8)
        for (name, text) in web {
            let file = root.appendingPathComponent("web").appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("audio without a declared policy is advisory, and names its evidence")
    func flagsUndeclared() throws {
        let root = try project(web: ["index.html": "<audio src='/tone.mp3'></audio>"])
        defer { try? FileManager.default.removeItem(at: root) }
        let checks = Doctor.audioPolicy(in: root)
        #expect(checks.count == 1)
        #expect(checks.first?.ok == false)
        // Advisory, never a build failure: a bundled framework that merely
        // mentions AudioContext would otherwise wedge anyone's `doctor`.
        #expect(checks.first?.required == false)
        // The file is in the message so a false positive is dismissed at a
        // glance rather than investigated.
        #expect(checks.first?.detail.contains("index.html") == true)
    }

    @Test("a declared policy passes")
    func declaredPasses() throws {
        let root = try project(web: [
            "index.html": "<audio src='/tone.mp3'></audio>",
            "app.js": "navigator.audioSession.type = 'playback';"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Doctor.audioPolicy(in: root).first?.ok == true)
    }

    @Test("a page that makes no sound is not asked about audio at all")
    func silentAppSaysNothing() throws {
        let root = try project(web: ["index.html": "<h1>hello</h1><script>render();</script>"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Doctor.audioPolicy(in: root).isEmpty)
    }

    /// `.play()` matches a video element, a Web Animations call and half the
    /// game loops in existence, so it is deliberately not a signal.
    @Test("an unrelated .play() is not mistaken for audio")
    func playAloneIsNotAudio() throws {
        let root = try project(web: ["index.html": "<script>spriteAnimation.play();</script>"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Doctor.audioPolicy(in: root).isEmpty)
    }

    @Test("Web Audio counts as audio, not just media elements")
    func webAudioCounts() throws {
        let root = try project(web: ["game.js": "const ctx = new AudioContext();"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Doctor.audioPolicy(in: root).first?.ok == false)
    }

    @Test("no project means no opinion")
    func noProject() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doctor-audio-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Doctor.audioPolicy(in: root).isEmpty)
    }

    // MARK: - swiftly list scanning (the non-Apple half of the toolchain match)

    @Test("matches a swiftly-installed toolchain in the SDK's release line")
    func swiftlyListMatches() {
        // Real `swiftly list` output: one toolchain per line, with optional
        // trailing markers.
        #expect(Doctor.swiftlyLine("Swift 6.4.0", isRelease: "6.4"))
        #expect(Doctor.swiftlyLine("Swift 6.4.0 (in use) (default)", isRelease: "6.4"))
        #expect(Doctor.swiftlyLine("Swift 6.4", isRelease: "6.4"))
    }

    @Test("a different release line is not a match")
    func swiftlyListRejects() {
        // `Swift 6.40` must not answer for 6.4: the SDK's prebuilt modules
        // load only in their own release, so a prefix test alone would report
        // a toolchain that can't compile against the SDK.
        #expect(!Doctor.swiftlyLine("Swift 6.40.0", isRelease: "6.4"))
        #expect(!Doctor.swiftlyLine("Swift 6.2.0 (in use) (default)", isRelease: "6.4"))
        #expect(!Doctor.swiftlyLine("Installed release toolchains", isRelease: "6.4"))
        #expect(!Doctor.swiftlyLine("", isRelease: "6.4"))
    }
}
