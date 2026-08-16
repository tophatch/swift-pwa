import ArgumentParser
import Foundation

/// Build-time checks over `pwa.json`'s `permissions` block.
///
/// Two separate jobs, because they can run in different circumstances:
///
/// - ``validateNames(_:)`` catches a typo or an unsupported name. It needs
///   nothing but the manifest, so it runs for **every** target including
///   cross-compiled ones — which matters, since Android is the platform whose
///   artifact the declaration actually shapes.
/// - ``drift(declared:compiled:)`` compares the manifest against what the app
///   really declared at runtime. That needs a headless run, so it's host-only,
///   exactly like `agent.expose`.
enum PermissionCheck {
    /// The names each key accepts, split the way `DevicePermission` documents
    /// them: `web` is what a page can ask for on its own, `device` is what only
    /// a plugin can reach.
    ///
    /// Duplicated from Core rather than imported because the CLI must be able
    /// to validate a manifest for a platform whose runtime it can't link — and
    /// a mismatch here is caught by `PermissionCheckTests`.
    static let webNames = ["camera", "geolocation", "microphone", "notifications"]
    static let deviceNames = ["bluetooth"]
    static var knownNames: [String] {
        (webNames + deviceNames).sorted()
    }

    static func validateNames(_ manifest: PWAManifest) throws {
        try validate(manifest.permissions?.web, key: "web", accepted: webNames, otherKey: "device")
        try validate(manifest.permissions?.device, key: "device", accepted: deviceNames, otherKey: "web")
    }

    private static func validate(
        _ declarations: PWAManifest.PermissionDeclarations?,
        key: String,
        accepted: [String],
        otherKey: String
    ) throws {
        guard let declarations else { return }
        // A name that exists but under the other key gets its own message: the
        // fix is to move one line, and "isn't a permission this runtime knows"
        // would send the reader looking for a typo that isn't there.
        let misfiled = declarations.names.filter { !accepted.contains($0) && knownNames.contains($0) }
        guard misfiled.isEmpty else {
            throw ValidationError("""
            pwa.json's permissions.\(key) names \(list(misfiled)), which \(misfiled.count == 1 ? "belongs" : "belong") \
            under permissions.\(otherKey) instead. \(key == "web"
                ? "No webview here exposes it to a page — it's reached through a plugin."
                : "It's a permission a page asks for through an ordinary web API.")
            """)
        }
        let unknown = declarations.names.filter { !knownNames.contains($0) }
        guard unknown.isEmpty else {
            throw ValidationError("""
            pwa.json's permissions.\(key) names \(list(unknown)), which \(unknown.count == 1 ? "isn't a" : "aren't") \
            permission this runtime knows. Valid names: \(accepted.joined(separator: ", ")) \
            (permissions.\(key)); \(knownNames.joined(separator: ", ")) in total.
            """)
        }
        var seen = Set<String>()
        let duplicates = declarations.names.filter { !seen.insert($0).inserted }
        guard duplicates.isEmpty else {
            throw ValidationError("pwa.json's permissions.\(key) lists \(list(duplicates)) more than once.")
        }
    }

    /// Apple requires a human-readable purpose string per permission, shows it
    /// to the user verbatim, and rejects apps that ship without one — and on
    /// iOS the OS *terminates the process* when a permission is requested with
    /// no usage description. So an Apple build with a `reason` missing fails
    /// here rather than producing a bundle that dies on the device.
    ///
    /// Only for Apple targets: the other platforms have no equivalent, and
    /// demanding a purpose string from an app that only ships Linux would be
    /// make-work.
    static func validateAppleReasons(_ manifest: PWAManifest) throws {
        guard let declarations = manifest.permissions?.allDeclarations else { return }
        let missing = declarations.names
            .filter { InfoPlistGenerator.appleUsageDescriptionKeys[$0] != nil }
            .filter { (declarations.detail(for: $0)?.reason ?? "").isEmpty }
        guard missing.isEmpty else {
            throw ValidationError("""
            pwa.json declares \(list(missing)) with no `reason`, which an Apple build needs — the string \
            is shown in the system prompt and the App Store rejects apps without one (on iOS the app is \
            terminated when it asks). Use the object form:

              "permissions": { "\(deviceNames.contains(missing[0]) ? "device" : "web")": \
            { "\(missing[0])": { "reason": "…why your app needs this…" } } }
            """)
        }
    }

    /// The two ceilings disagreeing, or nil when they match.
    ///
    /// Both directions are a real bug, and they fail differently:
    ///
    /// - Declared in `pwa.json` but not in Swift ⇒ the artifact asks the user's
    ///   OS for a permission the app will then refuse to use. On Android that's
    ///   an install-screen entry (and a Play Store review question) for nothing.
    /// - Declared in Swift but not in `pwa.json` ⇒ the runtime says yes and the
    ///   platform says no, because the manifest entry or usage description was
    ///   never emitted. On Android the request is refused; on Apple, a missing
    ///   usage description **terminates the app**.
    static func drift(declared: PWAManifest.PermissionDeclarations?, compiled: [String]) -> String? {
        let manifestNames = Set(declared?.names ?? [])
        let compiledNames = Set(compiled)
        guard manifestNames != compiledNames else { return nil }

        var lines: [String] = []
        let manifestOnly = manifestNames.subtracting(compiledNames).sorted()
        if !manifestOnly.isEmpty {
            lines.append("""
              \(list(manifestOnly)) declared in pwa.json but never passed to `ctx.permissions.declare`, \
            so the app refuses \(manifestOnly.count == 1 ? "it" : "them") at runtime.
            """)
        }
        let compiledOnly = compiledNames.subtracting(manifestNames).sorted()
        if !compiledOnly.isEmpty {
            let keys = Set(compiledOnly.map { deviceNames.contains($0) ? "permissions.device" : "permissions.web" })
            lines.append("""
              \(list(compiledOnly)) declared in Swift but missing from pwa.json's \
            \(keys.sorted().joined(separator: " / ")), \
            so the platform artifact never asks for \(compiledOnly.count == 1 ? "it" : "them").
            """)
        }
        return """
        pwa.json and the app disagree about permissions:
        \(lines.joined(separator: "\n"))
        The two are separate on purpose — pwa.json shapes the platform artifact (Android manifest \
        entries, Apple usage descriptions), `ctx.permissions.declare` is the runtime ceiling — but \
        they have to name the same set.
        """
    }

    private static func list(_ names: [String]) -> String {
        names.map { "'\($0)'" }.joined(separator: ", ")
    }
}
