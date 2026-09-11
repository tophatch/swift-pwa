#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    // WebKitGTK allows every navigation by default, so an off-origin link in
    // the main frame **loaded in place** — and a swift-pwa window has no
    // address bar and no back button, so the app was simply gone. Answering
    // `decide-policy` from the app's own policy is the Linux counterpart of
    // the Apple backend's `WKNavigationDelegate`.
    //
    // The *dialogs* need no counterpart here: WebKitGTK ships its own
    // `script-dialog` implementation, and `alert()` / `confirm()` / `prompt()`
    // were measured working on both 4.1 and 6.0 before this was written.

    extension WebKitGTKAdapter {
        /// Consult `policy` for every navigation this view makes, handing an
        /// off-origin one to the desktop instead. Call before `load`, so the
        /// first navigation is policed too.
        func connectNavigationPolicy(policy: ExternalURLPolicy, opener: any URLOpener) {
            let box = Unmanaged.passRetained(NavigationBox(policy: policy, opener: opener)).toOpaque()
            navigationBox = box
            "decide-policy".withCString { name in
                _ = g_signal_connect_data(
                    UnsafeMutableRawPointer(viewWidget),
                    name,
                    unsafeBitCast(decidePolicyTrampoline, to: GCallback.self),
                    box,
                    navigationBoxDestroy,
                    GConnectFlags(rawValue: 0)
                )
            }
        }
    }

    /// Heap box carrying the policy across the C boundary.
    ///
    /// `@unchecked Sendable` because it is only ever touched from the GTK main
    /// thread, where the signal fires — the same reasoning as `PermissionBox`.
    final class NavigationBox: @unchecked Sendable {
        private let policy: ExternalURLPolicy
        private let opener: any URLOpener
        var appOrigin: WebOrigin?

        init(policy: ExternalURLPolicy, opener: any URLOpener) {
            self.policy = policy
            self.opener = opener
        }

        /// Returns true when it answered the decision, false to leave it to
        /// WebKit.
        ///
        /// Two mechanisms, because WebKitGTK's *navigation* decision carries
        /// no frame information — measured: a cross-origin `<iframe>`'s own
        /// load arrives here indistinguishable from the main frame navigating
        /// away, and `webkit_navigation_action_get_frame_name` is NULL for
        /// both. Treating them alike would hand every embedded map or video
        /// to the browser, which is worse than the bug this fixes.
        ///
        /// 1. **Navigation decisions** are acted on only for a *user-initiated*
        ///    navigation — a link click or a form submission — plus
        ///    `window.open`. Those are the cases worth catching before a
        ///    request is made, and a link clicked inside an embed opening in
        ///    the browser is the behaviour a user expects anyway.
        /// 2. **Response decisions** carry
        ///    `is_main_frame_main_resource`, which is exact, and catch what
        ///    the first can't: a programmatic `location.href = …` to another
        ///    site. The cost is that the request has already been sent by the
        ///    time we cancel; the alternative is not catching it at all.
        func handle(decision: gpointer, type: UInt32) -> Bool {
            switch type {
            case Self.navigationAction, Self.newWindowAction:
                handleNavigation(decision: decision, type: type)
            case Self.response:
                handleResponse(decision: decision)
            default:
                false
            }
        }

        /// `WebKitPolicyDecisionType`.
        private static let navigationAction: UInt32 = 0
        private static let newWindowAction: UInt32 = 1
        private static let response: UInt32 = 2

        /// `WebKitNavigationType` values that mean *the user asked for this*.
        private static let userInitiated: Set<Int32> = [
            0, // link clicked
            1, // form submitted
            4 // form resubmitted
        ]

        private func handleNavigation(decision: gpointer, type: UInt32) -> Bool {
            let navigationType = swiftpwa_policy_decision_navigation_type(decision, type)
            guard type == Self.newWindowAction || Self.userInitiated.contains(navigationType) else {
                return false
            }
            guard let raw = swiftpwa_policy_decision_uri_copy(decision, type) else { return false }
            defer { g_free(UnsafeMutableRawPointer(raw)) }
            guard let url = URL(string: String(cString: raw)) else { return false }
            return act(on: url, decision: decision)
        }

        private func handleResponse(decision: gpointer) -> Bool {
            guard swiftpwa_response_decision_is_main_frame(decision) == 1 else { return false }
            guard let raw = swiftpwa_response_decision_uri_copy(decision) else { return false }
            defer { g_free(UnsafeMutableRawPointer(raw)) }
            guard let url = URL(string: String(cString: raw)) else { return false }
            // Only *leaving* is interesting here; anything on the app's own
            // origin is left to WebKit, including a download it would offer.
            guard case .openExternally = policy.navigationDisposition(
                for: url, appOrigin: appOrigin, isMainFrame: true
            ) else { return false }
            return act(on: url, decision: decision)
        }

        private func act(on url: URL, decision: gpointer) -> Bool {
            switch policy.navigationDisposition(
                for: url, appOrigin: appOrigin, isMainFrame: true
            ) {
            case .allowInApp:
                swiftpwa_policy_decision_use(decision)
            case .openExternally:
                swiftpwa_policy_decision_ignore(decision)
                let opener = opener
                Task { _ = await opener.open(url) }
            case let .block(reason):
                swiftpwa_policy_decision_ignore(decision)
                if reason == .notOpenable {
                    RuntimeDiagnostics.emit(
                        "swift-pwa: blocked a navigation to '\(url.absoluteString)' — it can't be "
                            + "loaded here and the system can't open it, so allowing it would "
                            + "leave the window with no way back."
                    )
                }
            }
            return true
        }
    }

    /// `@convention(c)` trampoline for `decide-policy`, which is
    /// `gboolean (*)(WebKitWebView *, WebKitPolicyDecision *, WebKitPolicyDecisionType, gpointer)`.
    /// Returning true means "handled"; WebKit stops asking other handlers and
    /// doesn't apply its own default.
    let decidePolicyTrampoline: @convention(c) (
        gpointer?, gpointer?, UInt32, gpointer?
    ) -> gboolean = { _, decision, type, userData in
        guard let decision, let userData else { return gboolean(0) }
        let box = Unmanaged<NavigationBox>.fromOpaque(userData).takeUnretainedValue()
        return gboolean(box.handle(decision: decision, type: type) ? 1 : 0)
    }

    /// `@convention(c)` GClosureNotify releasing the boxed policy on disconnect.
    let navigationBoxDestroy: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
        userData, _ in
        guard let userData else { return }
        Unmanaged<NavigationBox>.fromOpaque(userData).release()
    }
#endif
