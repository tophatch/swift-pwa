import ArgumentParser
import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("pwa.json permissions build checks")
struct PermissionCheckTests {
    private func manifest(
        web: PWAManifest.PermissionDeclarations? = nil,
        device: PWAManifest.PermissionDeclarations? = nil
    ) throws -> PWAManifest {
        var pwa = try JSONDecoder().decode(PWAManifest.self, from: Data("""
        {"id": "com.example.app", "name": "App", "version": "1.0.0",
         "web": {"directory": "web", "entry": "index.html"},
         "window": {"title": "App", "width": 1024, "height": 768,
                    "resizable": true, "fullscreen": false}}
        """.utf8))
        pwa.permissions = (web == nil && device == nil)
            ? nil
            : PWAManifest.PermissionsSection(web: web, device: device)
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
        #expect(PermissionCheck.knownNames == ["bluetooth", "camera", "geolocation", "microphone", "notifications"])
        // And each name sits in exactly one bucket, so `allDeclarations` can
        // merge the two without a name meaning different things per key.
        #expect(Set(PermissionCheck.webNames).isDisjoint(with: PermissionCheck.deviceNames))
    }

    // MARK: - Which key a name belongs under

    @Test("bluetooth belongs under permissions.device")
    func bluetoothIsADevicePermission() throws {
        try PermissionCheck.validateNames(manifest(device: .init(names: ["bluetooth"])))
    }

    @Test("a misfiled name says which key to move it to, not that it's a typo")
    func misfiledNamesAreNamed() throws {
        // Two different mistakes with two different fixes, and "isn't a
        // permission this runtime knows" would send the reader hunting for a
        // spelling error that isn't there.
        do {
            try PermissionCheck.validateNames(manifest(web: .init(names: ["bluetooth"])))
            Issue.record("expected bluetooth under permissions.web to be refused")
        } catch let error as ValidationError {
            #expect("\(error)".contains("permissions.device"))
        }
        do {
            try PermissionCheck.validateNames(manifest(device: .init(names: ["camera"])))
            Issue.record("expected camera under permissions.device to be refused")
        } catch let error as ValidationError {
            #expect("\(error)".contains("permissions.web"))
        }
    }

    @Test("both keys merge into one list for everything downstream")
    func bucketsMerge() throws {
        let pwa = try manifest(
            web: .init(names: ["camera"], details: ["camera": .init(reason: "Snap.")]),
            device: .init(names: ["bluetooth"], details: ["bluetooth": .init(reason: "Talk to it.")])
        )
        let merged = try #require(pwa.permissions?.allDeclarations)
        #expect(Set(merged.names) == ["camera", "bluetooth"])
        #expect(merged.detail(for: "bluetooth")?.reason == "Talk to it.")
        // …including the drift check, which compares one set against the app.
        #expect(PermissionCheck.drift(declared: merged, compiled: ["bluetooth", "camera"]) == nil)
    }

    @Test("drift on a device permission points at permissions.device")
    func driftNamesTheRightKey() throws {
        let message = try #require(PermissionCheck.drift(declared: nil, compiled: ["bluetooth"]))
        #expect(message.contains("permissions.device"))
        #expect(!message.contains("permissions.web"))
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
        let declarations = PWAManifest.PermissionDeclarations(
            names: ["geolocation"],
            details: ["geolocation": .init(reason: "Show jobs near you.")]
        )
        let pwa = try manifest(web: declarations)
        try PermissionCheck.validateAppleReasons(pwa)
        let plist = InfoPlistGenerator.macOS(manifest: pwa, executableName: "App")
        #expect(plist["NSLocationWhenInUseUsageDescription"] as? String == "Show jobs near you.")
    }

    @Test("bluetooth needs a purpose string too, and gets Apple's Always key")
    func bluetoothReasonEmitted() throws {
        let pwa = try manifest(device: .init(
            names: ["bluetooth"], details: ["bluetooth": .init(reason: "Send jobs to your plotter.")]
        ))
        try PermissionCheck.validateAppleReasons(pwa)
        let plist = InfoPlistGenerator.macOS(manifest: pwa, executableName: "App")
        #expect(plist["NSBluetoothAlwaysUsageDescription"] as? String == "Send jobs to your plotter.")

        // And the message names the key it actually goes under, so following it
        // doesn't produce a manifest the *name* check then rejects.
        do {
            try PermissionCheck.validateAppleReasons(manifest(device: .init(names: ["bluetooth"])))
            Issue.record("expected a missing reason to be refused")
        } catch let error as ValidationError {
            #expect("\(error)".contains("\"device\""))
        }
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
