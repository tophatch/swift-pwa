#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    // WebKitGTK routes *every* permission a page can ask for — camera,
    // microphone, location, notifications, device labels — through the one
    // `permission-request` signal. With no handler connected its default is to
    // refuse, silently and instantly, which is why all three failed on Linux
    // with an error a page can't tell apart from the user saying no. Answering
    // the signal from the app's policy is therefore the whole Linux fix, and
    // the cheapest of the three broken platforms.

    extension WebKitGTKAdapter {
        func connectPermissionHandler(policy: PermissionPolicy) {
            // Heap-boxed so the C callback can find the policy via user_data;
            // released by `permissionBoxDestroy` on disconnect.
            let box = Unmanaged.passRetained(PermissionBox(policy: policy)).toOpaque()
            "permission-request".withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(viewWidget),
                    name,
                    unsafeBitCast(permissionRequestTrampoline, to: GCallback.self),
                    box,
                    permissionBoxDestroy,
                    GConnectFlags(rawValue: 0)
                )
            }
        }
    }

    /// Heap box carrying the policy across the C boundary.
    ///
    /// `@unchecked Sendable` because it's only ever touched from the GTK main
    /// thread, where the signal fires.
    final class PermissionBox: @unchecked Sendable {
        private let policy: PermissionPolicy
        private var warnedUnrecognised = false

        init(policy: PermissionPolicy) { self.policy = policy }

        /// Returns true in every case: the signal is "handled" whether the
        /// answer is yes or no. Returning false would hand the request back to
        /// WebKit's default, which is the silent refusal this exists to remove.
        func handle(view: gpointer?, request: gpointer) -> Bool {
            let mask = swiftpwa_permission_request_kinds(request)
            let origin = Self.origin(of: view)

            let decision: PermissionDecision
            if mask == SWIFTPWA_PERM_DEVICE_INFO {
                // `enumerateDevices()` wanting labels. Either capture
                // permission justifies knowing what hardware exists — an
                // ungranted device is what shows up as `audioinput:(no label)`.
                decision = policy.decide(any: [.camera, .microphone], origin: origin)
            } else if let wanted = Self.permissions(in: mask) {
                decision = policy.decide(all: wanted, origin: origin)
            } else {
                // Screen capture, media-key system, pointer lock — types this
                // runtime doesn't model. Refusing keeps today's behaviour
                // rather than quietly widening the surface.
                warnUnrecognised(origin: origin)
                decision = .deny(.undeclared)
            }

            switch decision {
            case .allow: swiftpwa_permission_request_allow(request)
            case .deny: swiftpwa_permission_request_deny(request)
            }
            return true
        }

        /// The bits this runtime models, or nil if the mask carries none —
        /// which is a request type to refuse, not an empty grant.
        private static func permissions(in mask: UInt32) -> Set<WebPermission>? {
            var wanted: Set<WebPermission> = []
            if mask & SWIFTPWA_PERM_MICROPHONE != 0 { wanted.insert(.microphone) }
            if mask & SWIFTPWA_PERM_CAMERA != 0 { wanted.insert(.camera) }
            if mask & SWIFTPWA_PERM_GEOLOCATION != 0 { wanted.insert(.geolocation) }
            if mask & SWIFTPWA_PERM_NOTIFICATIONS != 0 { wanted.insert(.notifications) }
            return wanted.isEmpty ? nil : wanted
        }

        private static func origin(of view: gpointer?) -> String {
            guard let view, let uri = swiftpwa_web_view_uri_copy(view) else {
                return "the page"
            }
            defer { g_free(UnsafeMutableRawPointer(uri)) }
            return String(cString: uri)
        }

        private func warnUnrecognised(origin: String) {
            guard !warnedUnrecognised else { return }
            warnedUnrecognised = true
            FileHandle.standardError.writeQuietly(Data("""
            swift-pwa: refused a permission request from \(origin) of a kind this \
            runtime doesn't model (screen capture, pointer lock or an encrypted-media \
            key system). These have never been granted on any backend.\n
            """.utf8))
        }
    }

    /// `@convention(c)` trampoline for `permission-request`. Fires on the GTK
    /// main thread. The signal is `gboolean (*)(WebKitWebView *, ...)`, and a
    /// true return stops WebKit falling back to its own default.
    let permissionRequestTrampoline: @convention(c) (
        gpointer?, gpointer?, gpointer?
    ) -> gboolean = { view, request, userData in
        guard let request, let userData else { return gboolean(0) }
        let box = Unmanaged<PermissionBox>.fromOpaque(userData).takeUnretainedValue()
        return gboolean(box.handle(view: view, request: request) ? 1 : 0)
    }

    /// `@convention(c)` GClosureNotify releasing the boxed policy on disconnect.
    let permissionBoxDestroy: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        userData, _ in
        guard let userData else { return }
        Unmanaged<PermissionBox>.fromOpaque(userData).release()
    }
#endif
