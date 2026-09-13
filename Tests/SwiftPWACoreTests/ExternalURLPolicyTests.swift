import Foundation
@testable import SwiftPWACore
import Testing

@Suite("external URL policy")
struct ExternalURLPolicyTests {
    private let bundle = WebOrigin(scheme: "pwa", host: "localhost")

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    // MARK: - Which URLs may be handed to the OS

    @Test("the four web schemes need no declaration")
    func defaultSchemes() throws {
        let policy = ExternalURLPolicy()
        for spelling in [
            "https://example.com/a", "http://example.com", "mailto:someone@example.com", "tel:+3581234"
        ] {
            #expect(try policy.decide(url(spelling)) == .open, "\(spelling) should be openable")
        }
    }

    @Test("an undeclared scheme is refused, and declaring it is what changes that")
    func undeclaredScheme() throws {
        let policy = ExternalURLPolicy()
        let deepLink = try url("things:///add?title=Buy%20milk")
        #expect(policy.decide(deepLink) == .refuse(.undeclaredScheme))
        policy.declare(schemes: "things")
        #expect(policy.decide(deepLink) == .open)
    }

    /// The three spellings an adopter is equally likely to write in
    /// `pwa.json`. Getting this wrong is silent — the scheme simply never
    /// matches — so it is worth pinning.
    @Test("a declaration is case-insensitive and tolerates a trailing colon or slashes")
    func schemeNormalization() throws {
        for spelling in ["THINGS", "things:", "things://"] {
            let policy = ExternalURLPolicy()
            policy.declare(schemes: spelling)
            #expect(try policy.decide(url("things:///add")) == .open, "declared as \(spelling)")
        }
    }

    @Test("declarations accumulate rather than replace")
    func declarationsAccumulate() {
        let policy = ExternalURLPolicy()
        policy.declare(schemes: "things")
        policy.declare(schemes: ["obsidian", "shortcuts"])
        #expect(policy.allowedSchemes.isSuperset(of: ["things", "obsidian", "shortcuts"]))
        #expect(policy.allowedSchemes.isSuperset(of: ExternalURLPolicy.defaultSchemes))
    }

    // MARK: - Opting out of the allowlist

    /// The case the flag exists for: an app whose URLs are typed by the person
    /// using it can't enumerate the schemes, so the allowlist is a guess and
    /// the app they own that you didn't list is refused for good.
    @Test("allowAnyScheme opens a scheme nobody declared")
    func anySchemeOpensUndeclared() throws {
        let policy = ExternalURLPolicy()
        let deepLink = try url("x-devonthink-item://5B2C3F")
        #expect(policy.decide(deepLink) == .refuse(.undeclaredScheme))
        policy.allowAnyScheme = true
        #expect(policy.decide(deepLink) == .open)
    }

    /// The whole safety argument for the flag is that it moves exactly one
    /// step of `decide` and leaves the hard refusals either side of it — so
    /// those are what to pin, not the happy path.
    @Test("allowAnyScheme does not soften the never-openable schemes")
    func anySchemeKeepsHardRefusals() throws {
        let policy = ExternalURLPolicy()
        policy.allowAnyScheme = true
        for spelling in [
            "pwa://localhost/index.html", "file:///etc/passwd", "javascript:alert(1)",
            "about:blank", "data:text/html,<b>x</b>", "blob:https://example.com/abc"
        ] {
            #expect(try policy.decide(url(spelling)) == .refuse(.notOpenable), "\(spelling)")
        }
    }

    /// `https://swift-pwa.local` is the bundle origin on Windows and Android,
    /// where a scheme check can't tell app content from the web — the reason
    /// `registerAppOrigin` exists at all. A wildcard must not reach past it.
    @Test("allowAnyScheme still refuses the app's own registered origin")
    func anySchemeKeepsOwnOriginRefusal() throws {
        let policy = ExternalURLPolicy()
        policy.allowAnyScheme = true
        policy.registerAppOrigin(WebOrigin(scheme: "https", host: "swift-pwa.local"))
        #expect(try policy.decide(url("https://swift-pwa.local/index.html")) == .refuse(.notOpenable))
        #expect(try policy.decide(url("https://example.com")) == .open)
    }

    @Test("allowAnyScheme is off by default and reversible")
    func anySchemeDefaultsOff() throws {
        let policy = ExternalURLPolicy()
        #expect(policy.allowAnyScheme == false)
        policy.allowAnyScheme = true
        #expect(try policy.decide(url("things:///add")) == .open)
        policy.allowAnyScheme = false
        #expect(try policy.decide(url("things:///add")) == .refuse(.undeclaredScheme))
    }

    /// An off-origin navigation and an explicit `system.openURL` go through
    /// the same `decide`, so the flag has to reach both — otherwise a link the
    /// page opens works while the identical one the user clicks is blocked.
    @Test("allowAnyScheme reaches the navigation path too")
    func anySchemeAppliesToNavigation() throws {
        let policy = ExternalURLPolicy()
        let deepLink = try url("obsidian://open?vault=notes")
        #expect(
            policy.navigationDisposition(for: deepLink, appOrigin: bundle, isMainFrame: true)
                == .block(.undeclaredScheme)
        )
        policy.allowAnyScheme = true
        #expect(
            policy.navigationDisposition(for: deepLink, appOrigin: bundle, isMainFrame: true)
                == .openExternally
        )
    }

    // MARK: - Who asked

    /// The point of the opt-out is the app's *own* links. An `<iframe>` of
    /// someone else's content invokes commands through the same bridge, and an
    /// app that stopped enumerating its schemes didn't thereby hand that reach
    /// to content it embedded.
    @Test("allowAnyScheme covers the app's own page, not an embedded frame")
    func anySchemeIsScopedToTheMainFrame() throws {
        let policy = ExternalURLPolicy()
        policy.allowAnyScheme = true
        let deepLink = try url("things:///add?title=x")

        #expect(policy.decide(deepLink, from: .main) == .open)
        #expect(
            policy.decide(deepLink, from: .subframe(origin: WebOrigin(scheme: "https", host: "ads.example")))
                == .refuse(.undeclaredScheme)
        )
        // A scheme the app *did* declare is openable from anywhere, exactly as
        // before — the frame check narrows the wildcard, not the allowlist.
        policy.declare(schemes: "things")
        #expect(policy.decide(deepLink, from: .subframe(origin: nil)) == .open)
    }

    /// Both GTK backends can't report frame identity, so `.unknown` has to mean
    /// something deliberate. It keeps the opt-out: the alternative makes
    /// `allow_any_scheme` silently do nothing on one platform, which is a worse
    /// failure than the one it guards — and an app would have no way to tell.
    @Test("an unknown frame keeps the opt-out rather than silently disabling it")
    func unknownFrameKeepsTheOptOut() throws {
        let policy = ExternalURLPolicy()
        let deepLink = try url("obsidian://open?vault=notes")
        #expect(policy.decide(deepLink, from: .unknown) == .refuse(.undeclaredScheme))
        policy.allowAnyScheme = true
        #expect(policy.decide(deepLink, from: .unknown) == .open)
    }

    /// Without the opt-out the frame is irrelevant — the allowlist already
    /// answers, and nothing about this change may widen the default.
    @Test("the frame changes nothing when the allowlist is in force")
    func frameIsIrrelevantWithoutTheOptOut() throws {
        let policy = ExternalURLPolicy()
        let deepLink = try url("things:///add")
        for frame: CallerFrame in [.main, .unknown, .subframe(origin: nil)] {
            #expect(policy.decide(deepLink, from: frame) == .refuse(.undeclaredScheme), "\(frame)")
        }
        #expect(try policy.decide(url("https://example.com"), from: .subframe(origin: nil)) == .open)
    }

    /// These address the app's own content or the machine it runs on. Handing
    /// one to the desktop asks it to open something only this app can serve —
    /// and `javascript:` handed to a browser is a script-execution vector, not
    /// a link.
    @Test("the app's own schemes can't be opened, even if declared")
    func inAppSchemesAreNeverOpenable() throws {
        let policy = ExternalURLPolicy()
        policy.declare(schemes: "pwa", "file", "javascript", "data", "blob", "about")
        for spelling in [
            "pwa://localhost/index.html",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<h1>hi",
            "about:blank"
        ] {
            #expect(try policy.decide(url(spelling)) == .refuse(.notOpenable), "\(spelling)")
        }
    }

    /// Two backends serve the bundle over **https** (`swift-pwa.local` on
    /// Windows and Android), where the scheme check above can't tell app
    /// content from the web. Found on a device: `system.openURL` on the app's
    /// own page opened Chrome on a URL only the app can answer.
    @Test("the app's own origin can't be handed to the OS, even over https")
    func ownOriginIsNeverOpenable() throws {
        let policy = ExternalURLPolicy()
        let own = try url("https://swift-pwa.local/index.html")
        // Before the backend says where it serves from, there is nothing to
        // recognise — an ordinary https URL is openable.
        #expect(policy.decide(own) == .open)

        policy.registerAppOrigin(WebOrigin(scheme: "https", host: "swift-pwa.local"))
        #expect(policy.decide(own) == .refuse(.notOpenable))
        // A different path on the same origin is equally the app's own.
        #expect(try policy.decide(url("https://swift-pwa.local/deep/page.html"))
            == .refuse(.notOpenable))
        // Everything else still opens.
        #expect(try policy.decide(url("https://example.com/")) == .open)
    }

    @Test("registering an origin doesn't stop the app navigating within it")
    func ownOriginStillNavigable() throws {
        let policy = ExternalURLPolicy()
        let origin = WebOrigin(scheme: "https", host: "swift-pwa.local")
        policy.registerAppOrigin(origin)
        #expect(try policy.navigationDisposition(
            for: url("https://swift-pwa.local/next.html"),
            appOrigin: origin, isMainFrame: true
        ) == .allowInApp)
    }

    @Test("a string with no scheme isn't openable")
    func schemelessIsRefused() throws {
        #expect(try ExternalURLPolicy().decide(url("/settings")) == .refuse(.notOpenable))
    }

    // MARK: - What a navigation does

    @Test("same-origin navigation is allowed, off-origin goes to the system")
    func offOriginGoesToTheSystem() throws {
        let policy = ExternalURLPolicy()
        #expect(try policy.navigationDisposition(
            for: url("pwa://localhost/settings.html"), appOrigin: bundle, isMainFrame: true
        ) == .allowInApp)
        #expect(try policy.navigationDisposition(
            for: url("https://example.com/"), appOrigin: bundle, isMainFrame: true
        ) == .openExternally)
    }

    /// The bug this whole policy exists for: with no interception, a link to
    /// someone else's site loaded in place, and a chrome-less window has no
    /// way back.
    @Test("a subframe keeps its old behaviour — only the main frame can strand the app")
    func subframesAreUntouched() throws {
        let policy = ExternalURLPolicy()
        #expect(try policy.navigationDisposition(
            for: url("https://example.com/embed"), appOrigin: bundle, isMainFrame: false
        ) == .allowInApp)
    }

    /// `blob:` can't even be origin-compared — its URL is `blob:` followed by
    /// the inner origin, so there is no host to read — and a page navigating
    /// to a blob it generated is an ordinary pattern.
    @Test("about:, blob: and data: navigate in place rather than being handed out")
    func inAppNavigationSchemes() throws {
        let policy = ExternalURLPolicy()
        for spelling in ["about:blank", "blob:pwa://localhost/9f1c", "data:text/html,<h1>hi"] {
            #expect(try policy.navigationDisposition(
                for: url(spelling), appOrigin: bundle, isMainFrame: true
            ) == .allowInApp, "\(spelling)")
        }
    }

    @Test("in-app mode restores the old behaviour for an app that wants it")
    func inAppMode() throws {
        let policy = ExternalURLPolicy()
        policy.offOriginNavigation = .inApp
        #expect(try policy.navigationDisposition(
            for: url("https://example.com/"), appOrigin: bundle, isMainFrame: true
        ) == .allowInApp)
    }

    /// A `.remote` window is its own origin: an app pointed at a web app has
    /// to be able to navigate around that site, and only leaving *it* is
    /// leaving the app.
    @Test("a remote window's origin is the site it loaded, not the bundle's")
    func remoteWindowOrigin() throws {
        let policy = ExternalURLPolicy()
        let site = WebOrigin(scheme: "https", host: "app.example.com")
        #expect(try policy.navigationDisposition(
            for: url("https://app.example.com/inbox"), appOrigin: site, isMainFrame: true
        ) == .allowInApp)
        #expect(try policy.navigationDisposition(
            for: url("https://elsewhere.example.com/"), appOrigin: site, isMainFrame: true
        ) == .openExternally)
    }

    @Test("an undeclared scheme is blocked rather than loaded")
    func undeclaredNavigationIsBlocked() throws {
        let policy = ExternalURLPolicy()
        #expect(try policy.navigationDisposition(
            for: url("things:///add"), appOrigin: bundle, isMainFrame: true
        ) == .block(.undeclaredScheme))
    }

    /// Until a window has loaded anything there is no origin to measure
    /// against, and the first load itself must not be cancelled.
    @Test("with no known origin, everything is allowed through")
    func noOriginAllows() throws {
        let policy = ExternalURLPolicy()
        #expect(try policy.navigationDisposition(
            for: url("https://example.com/"), appOrigin: nil, isMainFrame: true
        ) == .allowInApp)
    }
}

@Suite("web origin")
struct WebOriginTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test("origin is scheme, host and port")
    func comparison() throws {
        let origin = try #require(WebOrigin(url("https://example.com/a/b?c=d")))
        #expect(origin == WebOrigin(scheme: "https", host: "example.com"))
        #expect(try origin.covers(url("https://example.com/other")))
        // Scheme, host and port each matter.
        #expect(try !origin.covers(url("http://example.com/a")))
        #expect(try !origin.covers(url("https://other.example.com/a")))
        #expect(try !origin.covers(url("https://example.com:8443/a")))
    }

    @Test("case doesn't matter in a scheme or host")
    func caseInsensitive() throws {
        let origin = try #require(WebOrigin(url("HTTPS://Example.COM/")))
        #expect(try origin.covers(url("https://example.com/x")))
    }

    @Test("a URL with no host is no origin")
    func hostlessIsNil() throws {
        #expect(try WebOrigin(url("data:text/plain,hi")) == nil)
        #expect(try WebOrigin(url("mailto:a@example.com")) == nil)
    }
}
