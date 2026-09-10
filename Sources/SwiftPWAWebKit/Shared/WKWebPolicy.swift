#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import SwiftPWACore
    import WebKit

    /// The `WKWebView` delegate pair the runtime installs on every window:
    /// where a navigation may go, and what `alert()` / `confirm()` /
    /// `prompt()` do.
    ///
    /// Both were previously unset, and both failed silently. An off-origin
    /// link loaded **in place** — a swift-pwa window has no chrome, so the app
    /// was simply gone, with no back button and no address bar — and the three
    /// JavaScript panels are served by `WKWebView` *only* through
    /// `WKUIDelegate`, so with none installed all three returned instantly
    /// with nothing on screen while `typeof alert` stayed `"function"`.
    ///
    /// A separate object rather than more conformances on ``WKWebViewAdapter``:
    /// the adapter is deliberately `nonisolated` throughout (see its class
    /// comment — `NSObject` + `WKScriptMessageHandler` would otherwise infer
    /// `@MainActor` and break `inboundFrames()`), whereas everything here is
    /// main-actor UI work WebKit already calls on the main thread. Keeping them
    /// apart means neither has to compromise.
    ///
    /// The *rule* lives in ``ExternalURLPolicy/navigationDisposition(for:appOrigin:isMainFrame:)``
    /// rather than here, so all five backends can share one answer.
    @MainActor
    final class WKWebPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
        let policy: ExternalURLPolicy
        private let opener: any URLOpener

        /// The origin this window's own content lives on, set from
        /// ``WKWebViewAdapter/load(_:)``.
        var appOrigin: WebOrigin?

        init(policy: ExternalURLPolicy, opener: any URLOpener) {
            self.policy = policy
            self.opener = opener
            super.init()
        }

        // MARK: - WKNavigationDelegate

        /// The **async** spelling deliberately: WebKit's header marks the
        /// decision handler `WK_SWIFT_ASYNC` and its block `WK_SWIFT_UI_ACTOR`,
        /// so the completion-handler form only matches if the closure is typed
        /// `@MainActor` too. Get that wrong and the method still compiles,
        /// still "conforms" (these are optional Objective-C requirements) and
        /// is simply never called — which is indistinguishable from having no
        /// delegate at all, the bug this fixes. `WKWebPolicyTests` pins the
        /// selectors for exactly that reason.
        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            switch policy.navigationDisposition(
                for: url,
                appOrigin: appOrigin,
                // A `nil` target frame is a new-window navigation, which
                // `createWebViewWith` handles; treat it as main-frame here so
                // it can't slip through as a subframe load.
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true
            ) {
            case .allowInApp:
                return .allow
            case .openExternally:
                hand(url)
                return .cancel
            case let .block(reason):
                if reason == .notOpenable {
                    // An undeclared scheme already logged its own diagnostic,
                    // naming the fix; this case has no fix to name.
                    RuntimeDiagnostics.emit(
                        "swift-pwa: blocked a main-frame navigation to '\(url.absoluteString)' — "
                            + "it can't be loaded here and the system can't open it, so allowing "
                            + "it would leave the window with no way back."
                    )
                }
                return .cancel
            }
        }

        // MARK: - WKUIDelegate

        /// `target="_blank"` and `window.open`. There is no second webview to
        /// give the page, so an off-origin one goes to the system browser —
        /// which is what a new-window link means to a user — and `window.open`
        /// keeps returning `null`. A *same-origin* `_blank` loads in the
        /// current webview instead of vanishing: it is the app's own content,
        /// and dropping it is how an "open in new tab" link inside an app
        /// becomes a dead click.
        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            switch policy.navigationDisposition(for: url, appOrigin: appOrigin, isMainFrame: true) {
            case .allowInApp:
                webView.load(URLRequest(url: url))
            case .openExternally:
                hand(url)
            case .block:
                break
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async {
            _ = await panel(.alert, message: message, origin: frame, in: webView)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async -> Bool {
            await panel(.confirm, message: message, origin: frame, in: webView) != nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo
        ) async -> String? {
            await panel(
                .prompt(defaultText: defaultText ?? ""),
                message: prompt, origin: frame, in: webView
            )
        }

        // MARK: - Helpers

        private func panel(
            _ kind: JSPanel, message: String, origin frame: WKFrameInfo, in webView: WKWebView
        ) async -> String? {
            await withCheckedContinuation { continuation in
                present(kind, message: message, origin: frame, in: webView) {
                    continuation.resume(returning: $0)
                }
            }
        }

        /// Fire-and-forget: the navigation decision has already been returned, and a
        /// handoff the OS declines is not something the page can be told about
        /// (there is no navigation left to fail).
        private func hand(_ url: URL) {
            let opener = opener
            Task { _ = await opener.open(url) }
        }
    }
#endif
