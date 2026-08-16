import ArgumentParser
import Foundation

/// Build-time checks over `pwa.json`'s `permissions.web`.
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
    /// The names `WebPermission` accepts. Duplicated from Core rather than
    /// imported because the CLI must be able to validate a manifest for a
    /// platform whose runtime it can't link — and a mismatch here is caught by
    /// `PermissionCheckTests`.
    static let knownNames = ["camera", "geolocation", "microphone", "notifications"]

    static func validateNames(_ manifest: PWAManifest) throws {
        guard let declarations = manifest.permissions?.web else { return }
        let unknown = declarations.names.filter { !knownNames.contains($0) }
        guard unknown.isEmpty else {
            throw ValidationError("""
            pwa.json's permissions.web names \(list(unknown)), which \(unknown.count == 1 ? "isn't a" : "aren't") \
            permission this runtime knows. Valid names: \(knownNames.joined(separator: ", ")).
            """)
        }
        var seen = Set<String>()
        let duplicates = declarations.names.filter { !seen.insert($0).inserted }
        guard duplicates.isEmpty else {
            throw ValidationError("pwa.json's permissions.web lists \(list(duplicates)) more than once.")
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
    static func drift(declared: PWAManifest.WebPermissionDeclarations?, compiled: [String]) -> String? {
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
            lines.append("""
              \(list(compiledOnly)) declared in Swift but missing from pwa.json's permissions.web, \
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
