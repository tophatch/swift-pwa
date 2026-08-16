import Foundation

/// Optional plugin exposing `geo.*` to JS:
///
/// ```js
/// const fix = await __SWIFT_PWA__.invoke('geo.current', { accuracy: 'high' });
/// const stop = __SWIFT_PWA__.subscribe('geo.watch', { accuracy: 'balanced' }, (fix) => { … });
/// ```
///
/// Opt-in, like every plugin that touches a sensor: an app that never asks for
/// a location shouldn't load CoreLocation or open a D-Bus connection to
/// GeoClue.
///
/// ```swift
/// ctx.permissions.declare(.geolocation)
/// ctx.use(GeoPlugin(SystemGeolocation()))
/// ```
///
/// **It goes through the same gate as the web API.** `geo.current` on an app
/// that hasn't declared `geolocation` fails `E_GEO_DENIED`, and an app-level
/// veto refuses it without asking the user — otherwise the plugin would be a
/// way around the policy, and a privacy switch with a documented bypass is
/// worse than none.
public struct GeoPlugin: Plugin {
    public static let pluginName = "geo"

    private let provider: any GeolocationProvider

    public init(_ provider: any GeolocationProvider) {
        self.provider = provider
    }

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let provider = provider
        // Held for the app's lifetime, like `WindowPlugin`'s capture: the
        // policy is app-wide and the plugin outlives any window.
        let permissions = app.permissions

        registry.register(
            "geo.current",
            typed: { (request: GeoRequest, _) async throws -> GeoFix in
                try Self.checkPermitted(permissions)
                do {
                    return try await provider.current(request)
                } catch let error as GeoError {
                    throw error.bridgeError
                }
            }
        )

        registry.registerStream(
            "geo.watch",
            typed: { (request: GeoRequest, _) -> AsyncThrowingStream<GeoFix, any Error> in
                AsyncThrowingStream { continuation in
                    do {
                        try Self.checkPermitted(permissions)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    let task = Task {
                        do {
                            for try await fix in provider.watch(request) {
                                continuation.yield(fix)
                            }
                            continuation.finish()
                        } catch let error as GeoError {
                            continuation.finish(throwing: error.bridgeError)
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    // Unsubscribing has to stop the hardware, not just the
                    // delivery — a watch left running is a battery drain the
                    // page can no longer see.
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }

    /// The `geolocation` permission, checked before the provider is touched so
    /// a refusal costs nothing and never spins up the hardware.
    ///
    /// The origin is the app itself rather than a page URL: a Swift-side plugin
    /// call has no document behind it, and inventing one would make the veto's
    /// origin argument lie.
    private static func checkPermitted(_ permissions: PermissionPolicy) throws {
        switch permissions.decide(.geolocation, origin: "geo.*") {
        case .allow:
            return
        case let .deny(reason):
            throw GeoError.denied(
                reason == .vetoed
                    ? "this app has turned location off"
                    : "this app has not declared the 'geolocation' permission"
            ).bridgeError
        }
    }
}
