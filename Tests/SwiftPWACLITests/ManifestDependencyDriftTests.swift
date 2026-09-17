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

    // MARK: - One condition per target

    /// One dependency *edge* as the manifest spells it: which target it points
    /// at, and the platform condition on it (`nil` when there is none).
    private struct Edge {
        let target: String
        let condition: String?
        let line: Int
    }

    /// Keys that only a target *definition* carries. An edge is just a name, a
    /// package and a condition, so a span holding any of these is a definition
    /// and its own `name:` is not an edge.
    private static let definitionKeys = [
        "dependencies:", "path:", "swiftSettings:", "cSettings:", "cxxSettings:",
        "linkerSettings:", "exclude:", "sources:", "resources:", "publicHeadersPath:",
        "plugins:", "url:", "checksum:", "targets:", "type:"
    ]

    /// The manifest as logical lines: `(line number, text)`, with an edge that
    /// swiftformat wrapped over several lines joined back into one.
    ///
    /// Without the join, a wrapped edge is invisible to the scan below — and
    /// the wrapped ones are exactly the interesting ones, since a condition is
    /// what pushes an edge past the 120-column limit. Two of them disagreed
    /// when this check was written.
    private static func logicalLines(in manifest: String) -> [(number: Int, text: String)] {
        let raw = manifest.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [(number: Int, text: String)] = []
        var index = 0
        while index < raw.count {
            let line = raw[index].trimmingCharacters(in: .whitespaces)
            guard line == ".product(" || line == ".target(" else {
                result.append((index + 1, line))
                index += 1
                continue
            }
            var joined = line
            var scan = index + 1
            while scan < raw.count {
                let next = raw[scan].trimmingCharacters(in: .whitespaces)
                joined += next
                scan += 1
                if next.hasPrefix(")") { break }
            }
            if definitionKeys.contains(where: { joined.contains($0) }) {
                // A definition: leave its lines alone so the edges nested in
                // its `dependencies:` are seen individually.
                result.append((index + 1, line))
                index += 1
            } else {
                result.append((index + 1, joined))
                index = scan
            }
        }
        return result
    }

    /// Every edge in the manifest, by the three spellings it uses:
    /// `.target(name: "X", condition: …)`, `.product(name: "X", package: …)`,
    /// and a bare `"X"` on its own line.
    ///
    /// Coarse, like ``declarationBlock(for:in:)`` above. A *definition* spells
    /// `name:` on its own line under `.target(`, so it never looks like an edge.
    private static func edges(in manifest: String) -> [Edge] {
        var found: [Edge] = []
        for (number, line) in logicalLines(in: manifest) {
            guard !line.hasPrefix("//") else { continue }

            for prefix in [".target(name: \"", ".product(name: \""] where line.contains(prefix) {
                guard let nameStart = line.range(of: prefix)?.upperBound,
                      let nameEnd = line[nameStart...].firstIndex(of: "\"")
                else { continue }
                let name = String(line[nameStart ..< nameEnd])
                // The platform list, not the whole `condition:` clause: what
                // follows it on the line depends on whether the edge ends the
                // array, so the clause's tail is punctuation, not meaning.
                var condition: String?
                if let listStart = line.range(of: "platforms: ")?.upperBound,
                   let listEnd = line[listStart...].firstIndex(of: ")")
                {
                    condition = String(line[listStart ..< listEnd])
                }
                found.append(Edge(target: name, condition: condition, line: number))
            }

            // A bare `"X"` (or `"X",`) is an unconditional edge.
            let bare = line.hasSuffix(",") ? String(line.dropLast()) : line
            let inner = bare.dropFirst().dropLast()
            if bare.count > 2, bare.hasPrefix("\""), bare.hasSuffix("\""),
               !inner.contains(where: { $0 == "\"" || $0 == " " })
            {
                found.append(Edge(target: String(inner), condition: nil, line: number))
            }
        }
        return found
    }

    /// The one product whose edges knowingly disagree, and why.
    ///
    /// `Crypto` is `cryptoPlatforms` from the runtime (Apple omitted — there
    /// its consumers use CryptoKit, and an edge would compile BoringSSL into
    /// every Apple app linking `SwiftPWACore`) and unconditional from the CLI,
    /// which runs on macOS hosts and imports it outright. Neither side can
    /// take the other's spelling. What makes it safe is that the two never
    /// meet: no app graph contains `SwiftPWACLISupport`, and the CLI's own
    /// edge is the one its product reaches first. Verified by building the
    /// package and running this suite on macOS under 6.4.
    private static let deliberatelyDivergent: Set<String> = ["Crypto"]

    /// Two edges onto one target with different platform conditions is a link
    /// failure waiting on declaration order — see the rule above
    /// `zstdPlatforms` in `Package.swift`. It shipped once (#229): a
    /// `.when(.macOS)` edge onto `CZstd` was visited before the `.when(.linux)`
    /// one, and under Swift 6.4 every Linux app stopped linking.
    ///
    /// An unconditional edge counts as its own spelling: it does *not* rescue a
    /// target some other edge has filtered out (measured on 6.4.0), so mixing
    /// the two is the same bug.
    @Test("every edge onto a target spells the same platform condition")
    func conditionsAgreePerTarget() throws {
        let manifest = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8
        )
        var byTarget: [String: [Edge]] = [:]
        for edge in Self.edges(in: manifest) {
            byTarget[edge.target, default: []].append(edge)
        }
        var divergent: [String] = []
        for (target, edges) in byTarget.sorted(by: { $0.key < $1.key })
            where !Self.deliberatelyDivergent.contains(target)
        {
            let spellings = Set(edges.map { $0.condition ?? "<unconditional>" })
            guard spellings.count > 1 else { continue }
            let detail = edges
                .map { "line \($0.line): \($0.condition ?? "unconditional")" }
                .joined(separator: ", ")
            divergent.append("\(target) — \(detail)")
        }
        #expect(
            divergent.isEmpty,
            """
            Dependency edges onto one target disagree about platforms. \
            Give every edge the same condition (hoist it into a `let` if it \
            needs a name): \(divergent.joined(separator: "; "))
            """
        )
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
