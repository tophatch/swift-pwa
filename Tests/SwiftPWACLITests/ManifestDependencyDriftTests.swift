import Foundation
import Testing

/// A target that *imports* a package module must *declare* it in `Package.swift`.
///
/// Swift lets you get away with not doing that: `canImport(Crypto)` succeeds
/// whenever any target in the build graph has already pulled the module in, so
/// the code compiles, and the classic SwiftPM build system linked the whole
/// package together so it ran too. `SwiftPWACore` imported `Crypto` this way
/// for years with no edge in the manifest.
///
/// Swift 6.4's `swiftbuild` engine builds each product's link list from the
/// *declared* edges instead. An undeclared one means the importing target's
/// objects are linked while the module's are not — and on Android, where the
/// app's product is linked `-shared` (undefined symbols are legal in a shared
/// object), the build stays green and the app dies at load with `cannot locate
/// symbol "$s6Crypto0A8KitErrorON"`.
///
/// The Android bundler now passes `-Xlinker --no-undefined`, which catches this
/// at link time — but only for an Android build, on a machine with the SDK
/// installed. CI has neither. This does, from the manifest alone.
@Suite("Manifest dependency drift")
struct ManifestDependencyDriftTests {
    /// Package modules whose absence from a link is silent rather than loud.
    /// `CryptoKit` is deliberately not here: it's an Apple framework, not a
    /// package product, so there is no edge to declare.
    private static let packageModules = ["Crypto", "ZIPFoundation", "ArgumentParser"]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/SwiftPWACLITests/<this>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Source-target directories under `Sources/`, skipping the C shims (which
    /// have no Swift imports) and generated smoke targets.
    private static func swiftTargets() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: repoRoot.appendingPathComponent("Sources").path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Every module in ``packageModules`` that `target` reaches for, by either
    /// spelling: a plain `import X` or a `canImport(X)`-guarded one.
    private static func modulesImported(by target: String) throws -> Set<String> {
        let dir = repoRoot.appendingPathComponent("Sources/\(target)")
        guard let walker = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        var found: Set<String> = []
        for case let path as String in walker where path.hasSuffix(".swift") {
            let source = (try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)) ?? ""
            for module in packageModules
                where source.contains("import \(module)\n") || source.contains("canImport(\(module))")
            {
                found.insert(module)
            }
        }
        return found
    }

    /// The manifest text for one target's `dependencies:` list.
    ///
    /// `name: "X"` appears in the manifest for a *product* and for every
    /// *reference* to a target as well as for its definition, so the match has
    /// to be anchored on a preceding `target(` — anchoring on the first
    /// occurrence instead reported two targets as undeclared that declare
    /// their dependency perfectly well.
    ///
    /// Coarse on purpose beyond that: this only has to answer "is the product
    /// named in here", and a real parser over the manifest would be a bigger
    /// thing to keep correct than the check it serves.
    private static func declarationBlock(for target: String, in manifest: String) -> String? {
        var searchFrom = manifest.startIndex
        while let hit = manifest.range(of: "name: \"\(target)\"", range: searchFrom ..< manifest.endIndex) {
            searchFrom = hit.upperBound
            // Look back far enough to see the constructor this name belongs to,
            // but not so far as to cross into the previous declaration.
            let lookbackStart = manifest.index(hit.lowerBound, offsetBy: -40, limitedBy: manifest.startIndex)
                ?? manifest.startIndex
            let lookback = manifest[lookbackStart ..< hit.lowerBound]
            // A *definition* spells the name on its own line under
            // `.target(`; a *reference* is `.target(name: "X", condition: …)`
            // all on one line. Requiring the newline is what separates them,
            // and references come first in this manifest.
            guard let ctor = lookback.range(of: "target(", options: .backwards),
                  lookback[ctor.upperBound...].contains("\n")
            else { continue }
            let rest = manifest[hit.upperBound...]
            guard let depsStart = rest.range(of: "dependencies: [") else { return nil }
            guard let depsEnd = rest[depsStart.upperBound...].range(of: "\n            ]") else { return nil }
            return String(rest[depsStart.upperBound ..< depsEnd.lowerBound])
        }
        return nil
    }

    @Test("every target that imports a package module declares it")
    func importsAreDeclared() throws {
        let manifest = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8
        )
        var undeclared: [String] = []
        for target in try Self.swiftTargets() {
            let imported = try Self.modulesImported(by: target)
            guard !imported.isEmpty else { continue }
            guard let block = Self.declarationBlock(for: target, in: manifest) else { continue }
            for module in imported.sorted() where !block.contains("name: \"\(module)\"") {
                undeclared.append("\(target) imports \(module) but does not declare it")
            }
        }
        #expect(undeclared.isEmpty, "\(undeclared.joined(separator: "; "))")
    }
}
