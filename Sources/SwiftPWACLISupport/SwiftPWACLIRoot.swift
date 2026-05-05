import ArgumentParser
import Foundation

/// Root command for the `swift-pwa` CLI. Lives in the
/// `SwiftPWACLISupport` library rather than the `swift-pwa-cli`
/// executable target so the test target can depend on the library
/// without dragging the executable's `main` entry point into its
/// link. (Swift on Windows otherwise emits an executable-level
/// `main` symbol that collides with the test runner's own `main`.)
///
/// `@available` annotation is required by SwiftArgumentParser when
/// the root command is `AsyncParsableCommand` — its runtime check
/// fires on platforms without a package-level minimum (Windows,
/// Linux), refusing to dispatch into an async `run()` without proof
/// that `_Concurrency` is available. The package's `platforms:` clause
/// already pins macOS / iOS above the bar; this annotation extends the
/// guarantee to the host-tools platforms the CLI also runs on.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
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
