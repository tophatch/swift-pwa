#if os(Android)
    import Foundation
    import SwiftPWACore

    /// ``DevicePermissionAuthority`` on Android, for the permissions no web API
    /// asks for.
    ///
    /// Only ``DevicePermission/allFiles`` is answered here. The rest —
    /// camera, microphone, location — are requested by Chromium at the moment
    /// the page uses them, through `WebChromeClient.onPermissionRequest` and
    /// the runtime-permission launcher behind it; answering them from here as
    /// well would mean two routes to one consent and a second place for it to
    /// go stale. `nil` falls back to the policy's own answer.
    ///
    /// All-files access is a **special** permission from API 30: there is no
    /// dialog for it, only a Settings screen the app sends the user to, so a
    /// request resolves whenever the user comes back — which may be minutes,
    /// or never. Below 30 the broad grant was the ordinary runtime pair and the
    /// Kotlin side asks for it with the usual launcher, so the app's Swift and
    /// JS don't branch on the OS version.
    public struct AndroidPermissionAuthority: DevicePermissionAuthority {
        public init() {}

        public func state(of permission: DevicePermission) async -> PermissionState? {
            guard permission == .allFiles else { return nil }
            return await call("permissions.allFilesState")
        }

        public func request(_ permission: DevicePermission) async -> PermissionState? {
            guard permission == .allFiles else { return nil }
            return await call("permissions.requestAllFiles")
        }

        private func call(_ method: String) async -> PermissionState {
            struct Result: Decodable { let state: String }
            do {
                let raw = try await AndroidRPC.call(method, EmptyArgs(), as: Result.self).state
                guard let state = PermissionState(rawValue: raw) else {
                    RuntimeDiagnostics.emit("swift-pwa: \(method) returned an unknown state '\(raw)'")
                    return .unavailable
                }
                return state
            } catch {
                // A failed RPC is a runtime fault, not a refusal — but the
                // caller asked a question with three answers and none of them
                // is "ask again". `unavailable` is the one that doesn't send
                // the app on to a hand-off that can't work.
                RuntimeDiagnostics.emit("swift-pwa: \(method) failed: \(error)")
                return .unavailable
            }
        }
    }
#endif
