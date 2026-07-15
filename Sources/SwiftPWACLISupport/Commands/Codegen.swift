import ArgumentParser
import Foundation
import SwiftPWACore

/// Generates a typed TypeScript client for the bridge from a command catalog —
/// the `__bridge.describe` output (a `[CommandDescriptor]` JSON array).
///
/// This reads the catalog from a file (capture it once from a running app, e.g.
/// `await __SWIFT_PWA__.invoke('__bridge.describe')` in the devtools console, or
/// the forthcoming `SWIFT_PWA_DESCRIBE` headless dump) and writes `bridge.ts`.
/// `--check` regenerates in memory and diffs, failing if the committed file is
/// stale — the CI drift guard.
struct Codegen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codegen",
        abstract: "Generate a typed TypeScript client from the bridge command catalog.",
        discussion: """
        Turns the `__bridge.describe` catalog (a JSON array of CommandDescriptor) into a typed \
        client over `__SWIFT_PWA__` — typed command names, payloads, and results for invoke / \
        subscribe / session. Capture the catalog from a running app (invoke `__bridge.describe`) \
        into a file, then point this at it.
        """
    )

    @Option(name: .long, help: "Path to the command catalog JSON (the `__bridge.describe` output).")
    var catalog: String

    @Option(name: [.long, .customShort("o")], help: "Output .ts path. Defaults to ./bridge.ts.")
    var out: String?

    @Flag(help: "Don't write; fail if the existing output is stale (CI drift guard).")
    var check: Bool = false

    func run() async throws {
        let fm = FileManager.default
        let catalogURL = URL(fileURLWithPath: catalog)
        guard let data = fm.contents(atPath: catalogURL.path) else {
            throw ValidationError("Catalog not found: \(catalogURL.path)")
        }
        let descriptors: [CommandDescriptor]
        do {
            descriptors = try JSONDecoder().decode([CommandDescriptor].self, from: data)
        } catch {
            throw ValidationError("Couldn't parse \(catalogURL.path) as a [CommandDescriptor] JSON array: \(error)")
        }

        let generated = TypeScriptClientGenerator.generate(descriptors)
        let outURL = out.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("bridge.ts")

        if check {
            let existing = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
            if existing == generated {
                print("\(outURL.lastPathComponent) is up to date (\(descriptors.count) commands).")
            } else {
                throw ValidationError(
                    "\(outURL.path) is stale — re-run `swift-pwa codegen` and commit the result."
                )
            }
            return
        }

        try generated.write(to: outURL, atomically: true, encoding: .utf8)
        print("Wrote \(outURL.path) (\(descriptors.count) commands).")
    }
}
