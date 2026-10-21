#if os(Android)
    import Foundation
    import SwiftPWACore

    /// ``AppIcons`` on Android: one launcher `<activity-alias>` per icon, the
    /// bundler's output for `alternate_icons`, switched by enabling one alias
    /// and disabling the rest. The Kotlin side reads the aliases from the
    /// installed package rather than from a list baked into the template, so
    /// what it reports is what the launcher actually has.
    ///
    /// An RPC rather than a direct call because `PackageManager` is a JVM API,
    /// like `system.openURL`'s `startActivity`.
    struct AndroidAppIcons: AppIcons {
        func state() async throws -> AppIconState {
            try await AndroidRPC.call("app.icon.state", EmptyArgs(), as: AppIconState.self)
        }

        func select(_ name: String?) async throws {
            _ = try await AndroidRPC.call("app.icon.set", AppIconSetArgs(name: name), as: EmptyResult.self)
        }
    }
#endif
