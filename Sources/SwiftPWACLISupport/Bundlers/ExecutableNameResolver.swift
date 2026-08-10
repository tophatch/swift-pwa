import Foundation

/// Resolves the name of the built executable the bundlers should look
/// for under `.build/release/` (and use as `CFBundleExecutable`, the
/// `.app` / `.exe` basename, the xcodebuild `-scheme`, the Android
/// `lib<name>.so`, etc.).
///
/// The name lives in `Package.swift` as the SwiftPM target / product
/// name — a fact the bundler doesn't own. Rather than *guess* it by
/// sanitizing the human-facing `name` (which breaks the moment the real
/// target name differs, e.g. a hand-edited `Package.swift`), we ask
/// SwiftPM directly via `swift package describe`. Resolution order:
///
///   1. An explicit `pwa.json` `executable_name` — the override for
///      multi-executable packages or unusual layouts.
///   2. The package's sole executable product (from `swift package
///      describe --type json`). This is the common case and means an
///      `init`-generated project needs no `executable_name` at all.
///   3. Fall back to `name` (`PWAManifest.binaryName`) if the probe
///      can't run or is ambiguous — preserves the historical behavior.
enum ExecutableNameResolver {
    static func resolve(projectRoot: URL, manifest: PWAManifest) async -> String {
        // 1. Explicit override always wins.
        if let explicit = manifest.executableName, !explicit.isEmpty {
            return explicit
        }
        // 2. Ask SwiftPM for the real product name.
        if let probed = await soleExecutable(projectRoot: projectRoot) {
            return probed
        }
        // 3. Historical fallback.
        return manifest.binaryName
    }

    /// Returns the single executable the root package builds, or `nil`
    /// if the probe fails or the package declares zero / more than one
    /// (ambiguous — defer to `executable_name` / `name`).
    private static func soleExecutable(projectRoot: URL) async -> String? {
        let json: String
        do {
            // Bare `swift` rather than `/usr/bin/env swift` — see the note in
            // `Drive.build`. This one failed *quietly* on Windows: the throw is
            // caught below and the resolver falls back to the manifest's
            // `binaryName`, so auto-discovery silently stopped working there
            // rather than reporting anything.
            json = try await Shell.capture(
                "swift",
                ["package", "describe", "--type", "json"],
                cwd: projectRoot
            )
        } catch {
            return nil
        }
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Prefer products (the binary is named after the executable
        // product); fall back to executable targets, which an
        // executableTarget synthesizes a product from anyway.
        let fromProducts = (root["products"] as? [[String: Any]] ?? []).compactMap { product -> String? in
            guard let type = product["type"] as? [String: Any], type.keys.contains("executable") else { return nil }
            return product["name"] as? String
        }
        let executables = !fromProducts.isEmpty
            ? fromProducts
            : (root["targets"] as? [[String: Any]] ?? []).compactMap { target -> String? in
                (target["type"] as? String) == "executable" ? target["name"] as? String : nil
            }

        let unique = Set(executables)
        return unique.count == 1 ? unique.first : nil
    }
}
