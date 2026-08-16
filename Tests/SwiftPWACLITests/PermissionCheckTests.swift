import ArgumentParser
import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("permissions.web build checks")
struct PermissionCheckTests {
    private func manifest(web: PWAManifest.WebPermissionDeclarations?) throws -> PWAManifest {
        var pwa = try JSONDecoder().decode(PWAManifest.self, from: Data("""
        {"id": "com.example.app", "name": "App", "version": "1.0.0",
         "web": {"directory": "web", "entry": "index.html"},
         "window": {"title": "App", "width": 1024, "height": 768,
                    "resizable": true, "fullscreen": false}}
        """.utf8))
        pwa.permissions = web.map { PWAManifest.PermissionsSection(web: $0) }
        return pwa
    }

    // MARK: - Names

    @Test("a valid declaration passes")
    func validNames() throws {
        let pwa = try manifest(web: .init(names: ["camera", "geolocation"]))
        try PermissionCheck.validateNames(pwa)
    }

    @Test("a typo is refused, and the message lists what's valid")
    func typoIsRefused() throws {
        let pwa = try manifest(web: .init(names: ["microfone"]))
        #expect(throws: ValidationError.self) { try PermissionCheck.validateNames(pwa) }
        do {
            try PermissionCheck.validateNames(pwa)
        } catch let error as ValidationError {
            #expect("\(error)".contains("microfone"))
            #expect("\(error)".contains("microphone"))
        }
    }

    @Test("a repeated name is refused")
    func duplicateIsRefused() throws {
        let pwa = try manifest(web: .init(names: ["camera", "camera"]))
        #expect(throws: ValidationError.self) { try PermissionCheck.validateNames(pwa) }
    }

    @Test("no permissions block is fine")
    func absentIsFine() throws {
        try PermissionCheck.validateNames(manifest(web: nil))
    }

    @Test("the CLI's name list matches the runtime's")
    func namesMatchRuntime() {
        // PermissionCheck duplicates these so it can validate a manifest for a
        // platform whose runtime it can't link. This is the guard on that copy.
        #expect(PermissionCheck.knownNames == ["camera", "geolocation", "microphone", "notifications"])
    }

    // MARK: - Apple purpose strings

    @Test("an Apple build refuses a declaration with no reason")
    func appleNeedsReason() throws {
        let pwa = try manifest(web: .init(names: ["microphone"]))
        #expect(throws: ValidationError.self) { try PermissionCheck.validateAppleReasons(pwa) }
        do {
            try PermissionCheck.validateAppleReasons(pwa)
        } catch let error as ValidationError {
            // The message has to show the fix, since the object form isn't
            // guessable from the list form.
            #expect("\(error)".contains("reason"))
            #expect("\(error)".contains("microphone"))
        }
    }

    @Test("a reason satisfies it, and reaches the Info.plist")
    func appleReasonEmitted() throws {
        let declarations = PWAManifest.WebPermissionDeclarations(
            names: ["geolocation"],
            details: ["geolocation": .init(reason: "Show jobs near you.")]
        )
        let pwa = try manifest(web: declarations)
        try PermissionCheck.validateAppleReasons(pwa)
        let plist = InfoPlistGenerator.macOS(manifest: pwa, executableName: "App")
        #expect(plist["NSLocationWhenInUseUsageDescription"] as? String == "Show jobs near you.")
    }

    @Test("notifications needs no purpose string")
    func notificationsNeedNoReason() throws {
        // UserNotifications prompts without one, so demanding it would be
        // make-work that teaches adopters the rule wrong.
        try PermissionCheck.validateAppleReasons(manifest(web: .init(names: ["notifications"])))
    }

    @Test("an explicit info_plist override still wins over the generated string")
    func passthroughWins() throws {
        var pwa = try manifest(web: .init(
            names: ["camera"], details: ["camera": .init(reason: "Generated.")]
        ))
        // pwa.json is decoded with `.convertFromSnakeCase`, so `info_plist`
        // only reaches `infoPlist` through that strategy.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        pwa.macos = try decoder.decode(PWAManifest.MacOSSection.self, from: Data("""
        {"info_plist": {"NSCameraUsageDescription": "Hand-written."}}
        """.utf8))
        let plist = InfoPlistGenerator.macOS(manifest: pwa, executableName: "App")
        #expect(plist["NSCameraUsageDescription"] as? String == "Hand-written.")
    }

    // MARK: - Drift

    @Test("matching declarations don't drift")
    func noDrift() {
        #expect(PermissionCheck.drift(
            declared: .init(names: ["camera", "microphone"]),
            compiled: ["microphone", "camera"]
        ) == nil)
    }

    @Test("both empty is agreement, not drift")
    func bothEmpty() {
        #expect(PermissionCheck.drift(declared: nil, compiled: []) == nil)
    }

    @Test("declared in pwa.json only — the artifact asks for what the app refuses")
    func manifestOnly() throws {
        let message = try #require(PermissionCheck.drift(
            declared: .init(names: ["camera"]), compiled: []
        ))
        #expect(message.contains("'camera'"))
        #expect(message.contains("ctx.permissions.declare"))
    }

    @Test("declared in Swift only — the runtime says yes and the platform says no")
    func swiftOnly() throws {
        let message = try #require(PermissionCheck.drift(
            declared: .init(names: []), compiled: ["geolocation"]
        ))
        #expect(message.contains("'geolocation'"))
        #expect(message.contains("permissions.web"))
    }

    @Test("drift in both directions at once reports both")
    func bothDirections() throws {
        let message = try #require(PermissionCheck.drift(
            declared: .init(names: ["camera"]), compiled: ["microphone"]
        ))
        #expect(message.contains("'camera'"))
        #expect(message.contains("'microphone'"))
    }
}
