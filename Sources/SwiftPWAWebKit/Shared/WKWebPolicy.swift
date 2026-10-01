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
        /// ``WKWebViewAdapter/load(_:)``. Registering it with the policy is
        /// what stops `system.openURL` handing the app's own pages to the
        /// browser.
        var appOrigin: WebOrigin? {
            didSet { policy.registerAppOrigin(appOrigin) }
        }

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

        #if os(iOS)
            /// A document that should have safe-area insets and was never sent
            /// them gets them sent again (#282).
            ///
            /// WebKit can lose the update: a `viewport-fit=cover` page that
            /// navigates in its first few tens of milliseconds, while it is
            /// taller than the screen, leaves the next document laid out
            /// full-screen with every `env(safe-area-inset-*)` at 0 for good —
            /// measured 7 of 16 launches on an iPhone 17 Pro, with a header
            /// sitting under the Dynamic Island. Nothing native recovers it:
            /// re-running the web view's layout left 5 of 16 stuck, and
            /// `contentInsetAdjustmentBehavior = .never` made it worse. What
            /// does is the page's viewport changing, so WebKit recomputes: take
            /// `viewport-fit=cover` off the meta tag and put it back.
            ///
            /// Swift can tell a lost update from a real zero, which the page
            /// can't: the web view's own `safeAreaInsets` say what the page
            /// should have. So this only acts on a `cover` page reading all
            /// zero while the view's insets aren't, after the update has had
            /// time to arrive (it takes 25–60ms; this looks at 150ms).
            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak webView] in
                    guard let webView else { return }
                    let expected = webView.safeAreaInsets
                    guard expected.top > 0 || expected.bottom > 0 else { return }
                    webView.evaluateJavaScript(Self.lostSafeAreaRepair) { result, _ in
                        if (result as? String) == "repaired" {
                            RuntimeDiagnostics.emit(
                                "swift-pwa: the page lost its safe-area insets (WebKit, #282); sent them again"
                            )
                        }
                    }
                }
            }
        #endif

        /// The repair `webView(_:didFinish:)` runs on iOS: answers `repaired`
        /// when it found a `viewport-fit=cover` page with every inset at 0 and
        /// nudged it, `ok` or `not-cover` otherwise. Outside the `#if` so the
        /// script itself can be tested on macOS, where every inset is 0.
        static let lostSafeAreaRepair = """
        (() => {
          const meta = document.querySelector('meta[name="viewport"]');
          const content = meta && meta.getAttribute("content");
          if (!content || !/viewport-fit\\s*=\\s*cover/.test(content)) return "not-cover";
          const box = document.createElement("div");
          box.style.cssText = "position:fixed;top:0;left:0;visibility:hidden;pointer-events:none;"
            + "padding:env(safe-area-inset-top) env(safe-area-inset-right) "
            + "env(safe-area-inset-bottom) env(safe-area-inset-left)";
          document.documentElement.appendChild(box);
          const s = getComputedStyle(box);
          const zero = [s.paddingTop, s.paddingRight, s.paddingBottom, s.paddingLeft]
            .every((v) => parseFloat(v) === 0);
          box.remove();
          if (!zero) return "ok";
          meta.setAttribute("content", content.replace(/,?\\s*viewport-fit\\s*=\\s*cover/, ""));
          // Two frames later, so WebKit sees the change — or 100ms, if the
          // page isn't rendering frames, so it is never left without `cover`.
          let restored = false;
          const restore = () => { if (!restored) { restored = true; meta.setAttribute("content", content); } };
          requestAnimationFrame(() => requestAnimationFrame(restore));
          setTimeout(restore, 100);
          return "repaired";
        })()
        """

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
