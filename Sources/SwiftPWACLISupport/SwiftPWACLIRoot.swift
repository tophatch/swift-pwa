import ArgumentParser
import Foundation

/// Root command for the `swift-pwa` CLI. Lives in the
/// `SwiftPWACLISupport` library rather than the `swift-pwa-cli`
/// executable target so the test target can depend on the library
/// without dragging the executable's `main` entry point into its
/// link. (Swift on Windows otherwise emits an executable-level
/// `main` symbol that collides with the test runner's own `main`.)
public struct SwiftPWACLIRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swift-pwa",
        abstract: "Build, run, and bundle Swift-native PWA apps.",
        version: "0.1.0",
        subcommands: [Init.self, Dev.self, Build.self],
        defaultSubcommand: nil
    )

    public init() {}
}
