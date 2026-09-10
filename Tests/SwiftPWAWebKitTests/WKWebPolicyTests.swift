#if canImport(WebKit) && (os(macOS) || os(iOS))
    import _SwiftPWATestSupport
    import Foundation
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing
    import WebKit

    private final class StubOpener: URLOpener, @unchecked Sendable {
        private let lock = NSLock()
        private var _opened: [URL] = []
        var opened: [URL] {
            lock.withLock { _opened }
        }

        func open(_ url: URL) async -> Bool {
            lock.withLock { _opened.append(url) }
            return true
        }
    }

    /// Holds the pieces of a loaded page together — chiefly so the policy
    /// delegate stays alive for the length of a test: `WKWebView` references
    /// its delegates weakly, and a dropped one silently un-polices every
    /// navigation, which is the bug these tests exist to catch.
    @MainActor
    private struct Page {
        let adapter: WKWebViewAdapter
        let delegate: WKWebPolicy
        let opener: StubOpener
        let home: URL
    }

    @Suite("WKWebPolicy")
    @MainActor
    struct WKWebPolicyTests {
        private func makeDelegate() -> (WKWebPolicy, StubOpener, ExternalURLPolicy) {
            let opener = StubOpener()
            let policy = ExternalURLPolicy()
            let delegate = WKWebPolicy(policy: policy, opener: opener)
            return (delegate, opener, policy)
        }

        /// `WKUIDelegate` and `WKNavigationDelegate` are almost entirely
        /// **optional** Objective-C methods matched by selector, so a
        /// signature that drifts by one parameter name compiles, conforms, and
        /// is never called — which is indistinguishable from the bug this all
        /// fixes (no delegate at all). Pin the selectors.
        @Test("the delegate actually implements the selectors WebKit looks for")
        func selectorsAreImplemented() {
            let (delegate, _, _) = makeDelegate()
            let required = [
                "webView:decidePolicyForNavigationAction:decisionHandler:",
                "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
                "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
                "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
                "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:"
            ]
            for name in required {
                #expect(
                    delegate.responds(to: Selector(name)),
                    "WKWebPolicy doesn't implement \(name) — WebKit would silently skip it"
                )
            }
        }

        @Test("attachWebPolicy installs both delegates on the webview")
        func attachInstallsDelegates() throws {
            let adapter = try WKWebViewAdapter(configuration: WKWebViewConfiguration())
            #expect(adapter.webView.navigationDelegate == nil)
            #expect(adapter.webView.uiDelegate == nil)
            adapter.attachWebPolicy(policy: ExternalURLPolicy(), opener: StubOpener())
            let installed = try #require(adapter.webView.navigationDelegate)
            #expect(adapter.webView.uiDelegate === installed)
            // Held by the adapter: `WKWebView` keeps its delegates weakly, so
            // without that the policy would deallocate immediately and every
            // navigation would go back to being unpoliced.
            #expect(installed is WKWebPolicy)
        }

        /// The whole bug, end to end in a real `WKWebView`: a click on an
        /// off-origin link used to load in place and take the app with it.
        @Test("clicking an off-origin link hands it to the OS and leaves the page where it was")
        func offOriginLinkIsHandedOff() async throws {
            let page = try await loadPage(
                #"<!doctype html><a id="out" href="https://other.example.com/page">out</a>"#
            )
            try await page.adapter.evaluateJavaScript("document.getElementById('out').click()")

            try await waitUntil { !page.opener.opened.isEmpty }
            #expect(page.opener.opened.map(\.absoluteString) == ["https://other.example.com/page"])
            // Still on the app's own document — the navigation was cancelled,
            // not merely mirrored to the browser.
            #expect(page.adapter.webView.url == page.home)
        }

        /// A `target="_blank"` used to be a dead click: `window.open` returns
        /// `null` with no `WKUIDelegate`, so nothing happened at all.
        @Test("a target=_blank to another site opens externally instead of doing nothing")
        func blankTargetOpensExternally() async throws {
            let page = try await loadPage(
                #"<!doctype html><a id="out" target="_blank" href="https://other.example.com/x">out</a>"#
            )
            try await page.adapter.evaluateJavaScript("document.getElementById('out').click()")

            try await waitUntil { !page.opener.opened.isEmpty }
            #expect(page.opener.opened.map(\.absoluteString) == ["https://other.example.com/x"])
            #expect(page.adapter.webView.url == page.home)
        }

        /// Same-origin has to keep working, and it is what a
        /// cancel-everything policy would break most visibly. Driven with a
        /// **fragment** link: WebKit consults the same policy for it, and it
        /// completes without a network fetch, so the assertion doesn't race a
        /// load that can never finish in a test.
        @Test("a same-origin navigation is still allowed through")
        func sameOriginStillNavigates() async throws {
            let page = try await loadPage(
                #"<!doctype html><a id="in" href='#next'>in</a>"#
            )
            try await page.adapter.evaluateJavaScript("document.getElementById('in').click()")
            try await waitUntil {
                try await page.adapter.evaluateJavaScript("location.hash") == "\"#next\""
            }
            #expect(page.opener.opened.isEmpty)
        }

        /// An undeclared scheme is refused rather than handed on — the point
        /// of the declaration is that a page can't reach an arbitrary
        /// installed app just by naming it.
        @Test("an undeclared scheme is neither loaded nor opened")
        func undeclaredSchemeGoesNowhere() async throws {
            let page = try await loadPage(
                #"<!doctype html><a id="deep" href="things:///add?title=x">deep</a>"#
            )
            try await page.adapter.evaluateJavaScript("document.getElementById('deep').click()")
            // Settle: the failure mode is a *late* handoff, so give it room to
            // happen rather than asserting on an empty list immediately.
            try await Task.sleep(for: .milliseconds(300))
            #expect(page.opener.opened.isEmpty)
            #expect(page.adapter.webView.url == page.home)

            // Declaring it is what changes the answer — same page, same click.
            page.delegate.policy.declare(schemes: "things")
            try await page.adapter.evaluateJavaScript("document.getElementById('deep').click()")
            try await waitUntil { !page.opener.opened.isEmpty }
            #expect(page.opener.opened.map(\.absoluteString) == ["things:///add?title=x"])
        }

        /// Loads `html` on `https://app.example.com/index.html` with a real
        /// policy attached, and returns once the DOM exists — `webView.url` is
        /// set when the *provisional* navigation starts, which is before the
        /// document a test wants to script has been parsed.
        private func loadPage(_ html: String) async throws -> Page {
            let adapter = try WKWebViewAdapter(configuration: WKWebViewConfiguration())
            let (delegate, opener, _) = makeDelegate()
            let home = try #require(URL(string: "https://app.example.com/index.html"))
            delegate.appOrigin = WebOrigin(home)
            adapter.webView.navigationDelegate = delegate
            adapter.webView.uiDelegate = delegate
            adapter.webView.loadHTMLString(html, baseURL: home)
            try await waitUntil {
                let ready = try? await adapter.evaluateJavaScript("!!document.querySelector('a')")
                return ready == "true"
            }
            return Page(adapter: adapter, delegate: delegate, opener: opener, home: home)
        }

        /// Polls rather than sleeping a fixed interval: WebKit's navigation
        /// callbacks are asynchronous and a fixed wait is either flaky or slow.
        private func waitUntil(
            timeout: Duration = .seconds(5),
            _ condition: () async throws -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            Issue.record("condition never became true within \(timeout)")
        }
    }
#endif
