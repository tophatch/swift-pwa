import Foundation

/// Detects drift between `pwa.json`'s Android `package_id` and the hand-
/// written JNI entry-point symbol in the generated `AndroidEntry.swift`.
///
/// The entry point is `@_cdecl("Java_<mangled-package>_MainActivity_swiftPwaMain")`
/// where `<mangled-package>` is the package id with dots → underscores. The
/// Kotlin `MainActivity` is generated under the *current* package id, so if
/// the user changes `android.package_id` after `init`, the (user-owned)
/// `AndroidEntry.swift` still names the old package and the app dies at
/// launch with `UnsatisfiedLinkError: Native method not found`. Nothing
/// catches that until runtime — so the bundler and `doctor` warn on it.
enum AndroidEntryDrift {
    /// The effective Android package id, mirroring `AndroidBundler`'s
    /// default resolution (explicit `android.package_id`, else the
    /// top-level `id` if it looks like a package, else `dev.swiftpwa.<id>`).
    static func resolvePackageId(_ manifest: PWAManifest) -> String {
        if let configured = manifest.android?.packageId, !configured.isEmpty {
            return configured
        }
        let id = manifest.id
        if id.contains(".") { return id }
        let cleaned = id.unicodeScalars.compactMap { sc -> Character? in
            CharacterSet.alphanumerics.contains(sc) ? Character(sc) : nil
        }
        return "dev.swiftpwa." + String(cleaned).lowercased()
    }

    struct Mismatch {
        /// Project-relative path of the offending file.
        let file: String
        /// The package the `@_cdecl` currently encodes (mangled form).
        let declared: String
        /// The package the manifest implies (mangled form).
        let expected: String
    }

    /// Scan `Sources/*/AndroidEntry.swift` for a JNI symbol whose package
    /// disagrees with `packageId`. Returns the first mismatch, or `nil` when
    /// everything matches (or no entry file exists — nothing to check).
    static func detect(projectRoot: URL, packageId: String) -> Mismatch? {
        let expected = mangle(packageId)
        let sources = projectRoot.appendingPathComponent("Sources")
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil
        ) else { return nil }
        for dir in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let entry = dir.appendingPathComponent("AndroidEntry.swift")
            guard let source = try? String(contentsOf: entry, encoding: .utf8),
                  let declared = declaredPackage(in: source)
            else { continue }
            if declared != expected {
                return Mismatch(
                    file: "Sources/\(dir.lastPathComponent)/AndroidEntry.swift",
                    declared: declared, expected: expected
                )
            }
        }
        return nil
    }

    /// JNI mangling as the scaffold emits it (dots → underscores). The
    /// scaffold uses this simple form; full JNI escaping isn't needed
    /// because the Kotlin side is generated from the same string.
    static func mangle(_ packageId: String) -> String {
        packageId.replacingOccurrences(of: ".", with: "_")
    }

    /// Extract `<X>` from `@_cdecl("Java_<X>_MainActivity_swiftPwaMain")`.
    static func declaredPackage(in source: String) -> String? {
        let marker = "_MainActivity_swiftPwaMain"
        for line in source.split(separator: "\n") where line.contains("@_cdecl") {
            guard let start = line.range(of: "Java_"),
                  let end = line.range(of: marker, range: start.upperBound ..< line.endIndex)
            else { continue }
            return String(line[start.upperBound ..< end.lowerBound])
        }
        return nil
    }

    /// A human-facing explanation + fix for a detected mismatch.
    static func message(for m: Mismatch, packageId: String) -> String {
        """
        Android JNI entry point is stale — the app will crash at launch with \
        UnsatisfiedLinkError. pwa.json's package_id ('\(packageId)') needs \
        `@_cdecl("Java_\(m.expected)_MainActivity_swiftPwaMain")`, but \(m.file) declares \
        `Java_\(m.declared)_MainActivity_swiftPwaMain`. Update the @_cdecl string to match \
        (or delete the file and re-run `swift-pwa init <name> --in-place`).
        """
    }
}
