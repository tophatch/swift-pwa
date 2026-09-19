import Foundation

/// Built-in plugin exposing the runtime half of `ctx.permissions` to JS:
///
/// ```js
/// const { state } = await __SWIFT_PWA__.invoke('permissions.status', { name: 'allFiles' });
/// if (state === 'denied') {
///     await __SWIFT_PWA__.invoke('permissions.request', { name: 'allFiles' });
/// }
/// ```
///
/// **Not a replacement for the web's own consent.** `getUserMedia`,
/// `navigator.geolocation` and `Notification.requestPermission` still reach the
/// platform's prompt through their own seams; a page that wants the camera asks
/// for the camera. This is for a capability no web API asks for — today
/// `allFiles`, the way `ble.*` is for Bluetooth — and for the "should I even
/// show this button" read that has to happen before any of it.
///
/// Registered eagerly by every backend's `AppContext.init`, like `AppPlugin`.
/// It answers on all five: the policy's own two ceilings are platform-agnostic,
/// and a backend with nothing to ask reports `granted` for anything the app
/// declared.
public struct PermissionsPlugin: Plugin {
    public static let pluginName = "permissions"
    public init() {}

    public func register(into registry: CommandRegistry, app: any AppContext) {
        // Held for the app's lifetime, like `GeoPlugin`'s capture: the policy
        // is app-wide and outlives any window.
        let permissions = app.permissions

        registry.register(
            "permissions.status",
            typed: { (query: PermissionQuery, _) async throws -> PermissionStatusResult in
                try await PermissionStatusResult(state: permissions.status(Self.parse(query.name)))
            }
        )

        registry.register(
            "permissions.request",
            typed: { (query: PermissionQuery, _) async throws -> PermissionStatusResult in
                try await PermissionStatusResult(state: permissions.request(Self.parse(query.name)))
            }
        )
    }

    /// An unknown name is a typo in the page, and the fix is a list of what it
    /// could have been — the same shape `app.lastWindowClosed` uses for its
    /// enum.
    static func parse(_ name: String) throws -> DevicePermission {
        guard let permission = DevicePermission(rawValue: name) else {
            let valid = DevicePermission.allCases.map(\.rawValue).joined(separator: ", ")
            throw BridgeError(
                code: BridgeError.decode,
                message: "permissions: \"\(name)\" isn't one of: \(valid)"
            )
        }
        return permission
    }
}

public struct PermissionQuery: Codable, Sendable, Equatable {
    /// A ``DevicePermission`` raw value — `camera`, `microphone`,
    /// `geolocation`, `notifications`, `bluetooth`, `allFiles`.
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct PermissionStatusResult: Codable, Sendable, Equatable {
    public var state: PermissionState

    public init(state: PermissionState) {
        self.state = state
    }
}
