#if os(Linux)
    import CGtk4Shim
    import Foundation
    import SwiftPWACore

    /// GTK4 `Notifications` — identical to the GTK3 implementation
    /// because the freedesktop notification spec is independent of GTK
    /// version. Both backends call `org.freedesktop.Notifications`
    /// directly through GIO; only the C shim header differs.
    public final class SystemNotifications: Notifications, @unchecked Sendable {
        public init() {}

        public func requestAuthorization() async throws -> Bool {
            true
        }

        public func send(_ request: NotificationRequest) async throws -> String {
            try await MainThread.run { try sendOnMainThread(request) }
        }

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
