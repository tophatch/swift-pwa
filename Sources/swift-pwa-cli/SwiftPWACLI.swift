import ArgumentParser
import Foundation

@main
struct SwiftPWACLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-pwa",
        abstract: "Build, run, and bundle Swift-native PWA apps.",
        version: "0.1.0-dev",
        subcommands: [Init.self, Dev.self, Build.self],
        defaultSubcommand: nil
    )
}
