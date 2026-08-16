#if os(Android)
    import Foundation
    import SwiftPWACore

    /// Answers the WebView's camera / microphone / location requests from the
    /// app's ``PermissionPolicy``.
    ///
    /// Android is the one backend where the question can't be answered inline.
    /// `WebChromeClient.onPermissionRequest` fires on the JVM's UI thread, the
    /// policy lives in Swift, and a grant may additionally need Android's own
    /// runtime-permission dialog — which is asynchronous by construction. So
    /// the round trip runs over the two primitives the backend already has: a
    /// Kotlin→Swift host event carrying a request id, and a Swift→Kotlin RPC
    /// carrying the verdict back.
    ///
    /// Kotlin owns the OS half deliberately. By the time `onPermissionRequest`
    /// fires, Android has already established that the app doesn't hold
    /// `CAMERA` / `RECORD_AUDIO`, so *something* has to ask — and only an
    /// Activity can.
    enum AndroidWebPermissions {
        static let channel = "permissions.request"

        private struct Request: Decodable {
            let id: Int
            let kinds: [String]
            let origin: String
        }

        private struct Resolution: Encodable {
            let id: Int
            let allow: Bool
            let kinds: [String]
        }

        /// Subscribe to the Kotlin side's requests. Called during `run`,
        /// before `configure`, so a page that asks the instant it loads is
        /// still answered.
        static func install(policy: PermissionPolicy) {
            AndroidHostEventRouter.subscribe(channel: channel) { data in
                guard let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
                let permissions = Set(request.kinds.compactMap(WebPermission.init(rawValue:)))
                // A kind we don't model must not be waved through, and the
                // policy's all-of shape already refuses an empty set.
                let decision = permissions.count == request.kinds.count
                    ? policy.decide(all: permissions, origin: request.origin)
                    : .deny(.undeclared)

                let resolution = Resolution(
                    id: request.id,
                    allow: decision == .allow,
                    kinds: request.kinds
                )
                Task {
                    do {
                        try await AndroidRPC.call(
                            "permissions.resolve", resolution, as: NoResult.self
                        )
                    } catch {
                        // Leaving the request parked would hang the page's
                        // promise forever, so say what happened rather than
                        // letting it fail silently — the Kotlin side denies
                        // nothing it never hears about.
                        swiftPWALog("swift-pwa: permission resolve failed: \(error)")
                    }
                }
            }
        }
    }
#endif
