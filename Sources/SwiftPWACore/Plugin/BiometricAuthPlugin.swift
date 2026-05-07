import Foundation

/// Optional plugin exposing `biometric.*` to JS. Not auto-installed —
/// the underlying frameworks (`LocalAuthentication` on Apple,
/// `Windows.Security.Credentials.UI` on Windows) shouldn't load for
/// apps that don't gate flows on biometrics.
///
/// ```swift
/// runtime.run { ctx in
///     ctx.use(BiometricAuthPlugin(SystemBiometricAuth()))
/// }
/// ```
public struct BiometricAuthPlugin: Plugin {
    public static let pluginName = "biometric"

    private let auth: any BiometricAuth

    public init(_ auth: any BiometricAuth) {
        self.auth = auth
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let auth = auth

        registry.register(
            "biometric.canAuthenticate",
            typed: { (_: EmptyArgs, _) async throws -> BiometricAvailability in
                try await auth.canAuthenticate()
            }
        )

        registry.register(
            "biometric.authenticate",
            typed: { (args: BiometricAuthArgs, _) async throws -> BiometricAuthResult in
                try await auth.authenticate(args)
            }
        )
    }
}
