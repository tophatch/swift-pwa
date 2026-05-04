#if os(Linux)
    import CGtk3Shim
    import Foundation
    import SwiftPWACore

    /// `Notifications` backed by the freedesktop.org notification
    /// service on the session bus, called directly through GIO from
    /// the C shim. Works on every modern Linux desktop without an
    /// extra `libnotify` / `libayatana-appindicator` runtime dep.
    ///
    /// `requestAuthorization` always reports `true`: the spec has no
    /// authorization step, the daemon either accepts the call or
    /// refuses it on each `send`. Returning `true` keeps the JS-side
    /// flow symmetric with Apple, where authorization is gated.
    public final class SystemNotifications: Notifications, @unchecked Sendable {
        public init() {}

        public func requestAuthorization() async throws -> Bool {
            true
        }

        public func send(_ request: NotificationRequest) async throws -> String {
            try await MainThread.run { try sendOnMainThread(request) }
        }

        /// The D-Bus call has its own internal main loop and is safe
        /// off-main, but we still hop because the rest of the GTK
        /// backend establishes a "Swift calls into the GLib world only
        /// on the main thread" invariant — easier to keep than to argue
        /// about per-call exceptions.
        private func sendOnMainThread(_ request: NotificationRequest) throws -> String {
            var idPtr: UnsafeMutablePointer<CChar>?
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = "swift-pwa".withCString { app in
                request.title.withCString { title in
                    let bodyOpt = request.body
                    func go(_ bodyPtr: UnsafePointer<CChar>?) -> Int32 {
                        swiftpwa_notify_send(
                            app, title, bodyPtr,
                            request.sound ? 1 : 0,
                            &idPtr, &errPtr
                        )
                    }
                    if let bodyOpt {
                        return bodyOpt.withCString { go($0) }
                    } else {
                        return go(nil)
                    }
                }
            }
            if rc != 0 {
                let msg = errPtr.map { String(cString: $0) } ?? "Notify call failed"
                if let p = errPtr { g_free(UnsafeMutableRawPointer(p)) }
                throw BridgeError(code: BridgeError.handler, message: msg)
            }
            guard let idPtr else {
                throw BridgeError(code: BridgeError.handler, message: "no id returned")
            }
            let id = String(cString: idPtr)
            g_free(UnsafeMutableRawPointer(idPtr))
            return id
        }
    }
#endif
