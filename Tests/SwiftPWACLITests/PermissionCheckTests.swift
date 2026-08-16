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
