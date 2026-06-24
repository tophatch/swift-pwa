import ArgumentParser
import Foundation

/// Writes a ready-to-run GitHub Actions release workflow into an
/// existing project. `swift-pwa init` already does this for new / adopted
/// projects; this command is the path for a project that was scaffolded
/// before the workflow existed (or that opted out with `--no-ci-workflow`).
struct GenerateCI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-ci",
        abstract: "Add a GitHub Actions release workflow (.github/workflows/release.yml).",
        discussion: """
        Drops in a workflow that builds your app for macOS, Linux, and Windows in the cloud on a \
        tag push (`git tag v1.0.0 && git push --tags`) and attaches the artifacts to a GitHub \
        Release — no local Swift / MSVC / GTK toolchains needed. iOS and Android are included as \
        commented, opt-in stubs since they need signing material / a cross-compile SDK.
        """
    )

    @Option(help: "Directory to write into. Defaults to the current directory.")
    var path: String?

    @Flag(help: "Overwrite an existing .github/workflows/release.yml.")
    var force: Bool = false

    func run() async throws {
        let fm = FileManager.default
        let root = path.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        let workflow = root.appendingPathComponent(".github/workflows/release.yml")

        if fm.fileExists(atPath: workflow.path), !force {
            throw ValidationError(
                "\(workflow.path) already exists. Pass --force to overwrite it."
            )
        }
        try fm.createDirectory(at: workflow.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Templates.releaseWorkflowYml(version: SwiftPWAVersion.current)
            .write(to: workflow, atomically: true, encoding: .utf8)

        print("Wrote \(workflow.path)")
        print("Commit it, then `git tag v1.0.0 && git push --tags` to build all platforms in CI.")
    }
}
