#if os(Android)
    import CSwiftPWAAndroidJNI
    import Foundation
    import SwiftPWACore

    /// Answers `WebViewClient.shouldOverrideUrlLoading` from the app's
    /// ``ExternalURLPolicy``, so a main-frame navigation that leaves the
    /// app's origin is handed to the OS instead of loading in place — an
    /// Android app window has no address bar and no back button, so in place
    /// means the app is gone.
    ///
    /// **Synchronous, unlike every other Android seam here.** The WebView
    /// needs the answer before the load proceeds, so this can't go through
    /// the async RPC the rest of the backend uses. It is safe because the
    /// decision is a lock-guarded pure function in Core — no I/O, no actor
    /// hop. `request.isForMainFrame` is passed straight through, which is the
    /// distinction WebKitGTK makes an embedder work for.
    enum AndroidNavigationPolicy {
        /// Retained for the lifetime of the process: the C shim holds the
        /// pointer and the JVM calls back into it on every navigation.
        private nonisolated(unsafe) static var box: Unmanaged<PolicyBox>?

        static func install(policy: ExternalURLPolicy) {
            let retained = Unmanaged.passRetained(PolicyBox(policy: policy))
            box?.release()
            box = retained
            swiftpwa_android_set_navigation_handler(
                { uri, isMainFrame, user in
                    guard let uri, let user else { return Int32(SWIFTPWA_NAV_ALLOW) }
                    let box = Unmanaged<PolicyBox>.fromOpaque(user).takeUnretainedValue()
                    return box.decide(uri: String(cString: uri), isMainFrame: isMainFrame != 0)
                },
                retained.toOpaque()
            )
        }

        /// The origin this app's own content lives on. Set as content loads,
        /// because a `.remote` window's site *is* the app.
        static func setAppOrigin(_ origin: WebOrigin?) {
            guard let box else { return }
            box.takeUnretainedValue().appOrigin = origin
        }

        /// `@unchecked Sendable`: touched only from the JVM main thread,
        /// where both the navigation callback and `load` run.
        final class PolicyBox: @unchecked Sendable {
            private let policy: ExternalURLPolicy
            var appOrigin: WebOrigin? {
                didSet { policy.registerAppOrigin(appOrigin) }
            }

            init(policy: ExternalURLPolicy) { self.policy = policy }

            func decide(uri: String, isMainFrame: Bool) -> Int32 {
                guard let url = URL(string: uri) else { return Int32(SWIFTPWA_NAV_ALLOW) }
                switch policy.navigationDisposition(
                    for: url, appOrigin: appOrigin, isMainFrame: isMainFrame
                ) {
                case .allowInApp:
                    return Int32(SWIFTPWA_NAV_ALLOW)
                case .openExternally:
                    return Int32(SWIFTPWA_NAV_OPEN_EXTERNALLY)
                case let .block(reason):
                    if reason == .notOpenable {
                        RuntimeDiagnostics.emit(
                            "swift-pwa: blocked a navigation to '\(url.absoluteString)' — it "
                                + "can't be loaded here and the system can't open it, so allowing "
                                + "it would leave the window with no way back."
                        )
                    }
                    return Int32(SWIFTPWA_NAV_BLOCK)
                }
            }
        }
    }
#endif
