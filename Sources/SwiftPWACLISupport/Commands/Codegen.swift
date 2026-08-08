import ArgumentParser
import Foundation
import SwiftPWACore

/// Generates a typed TypeScript client for the bridge from the command catalog —
/// the `[CommandDescriptor]` array `__bridge.describe` / `CommandRegistry`
/// produces.
///
/// By default it obtains the catalog **headlessly**: it builds the app and runs
/// it once with `SWIFT_PWA_DESCRIBE=<tmp>` set, which makes the backend register
/// every plugin (running the app's own `configure` closure — so dynamically
/// named commands are captured too), write the catalog to that file, and exit
/// before opening any window. No devtools round-trip required. Pass
/// `--catalog <json>` to skip the build and read a pre-captured catalog instead
/// (e.g. one saved from `await __SWIFT_PWA__.invoke('__bridge.describe')`).
///
/// `--check` regenerates in memory and diffs against the committed output,
/// failing if it's stale — the CI drift guard.
struct Codegen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codegen",
        abstract: "Generate a typed TypeScript client from the bridge command catalog.",
        discussion: """
        Emits a typed client over `__SWIFT_PWA__` — typed command names, payloads, and results for \
        invoke / subscribe / session. By default it builds the app and runs it headlessly \
        (SWIFT_PWA_DESCRIBE) to read the live catalog; the app's `configure` closure must be pure up \
        to registration, since it runs (createWindow is a no-op, but other side effects still fire). \
        Use `--catalog <json>` to read a pre-captured catalog instead of building.
        """
    )

    @Option(name: [.long, .customShort("o")], help: "Output .ts path. Defaults to ./bridge.ts.")
    var out: String?

    @Option(
        name: .long,
        help: "Read a pre-captured `__bridge.describe` catalog JSON instead of building+running the app."
    )
    var catalog: String?

    @Option(name: .long, help: "Path to pwa.json (used to resolve the executable to run). Defaults to ./pwa.json.")
    var manifest: String = "pwa.json"

    @Option(name: .long, help: "Build configuration for the headless dump: debug (default) or release.")
    var configuration: String = "debug"

    @Flag(help: "Don't write; fail if the existing output is stale (CI drift guard).")
    var check: Bool = false

    func run() async throws {
        let descriptors = try await loadDescriptors()

        let generated = TypeScriptClientGenerator.generate(descriptors)
        let fm = FileManager.default
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

    // MARK: - Catalog acquisition

    private func loadDescriptors() async throws -> [CommandDescriptor] {
        if let catalog {
            return try CommandCatalog.decode(at: URL(fileURLWithPath: catalog))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = cwd.appendingPathComponent(manifest)
        let pwa: PWAManifest
        do {
            pwa = try PWAManifest.load(from: manifestURL)
        } catch {
            throw ValidationError(
                "Couldn't read \(manifestURL.path): \(error). Run from your app's directory, or pass "
                    + "--catalog <json> to skip the build."
            )
        }
        return try await CommandCatalog.dump(projectRoot: cwd, manifest: pwa, configuration: configuration)
    }
}
