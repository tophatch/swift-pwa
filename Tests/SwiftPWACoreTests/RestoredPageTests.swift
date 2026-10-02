import Foundation
@testable import SwiftPWACore
import Testing

/// A window iPadOS brings back is rebuilt from the app's main config and shown
/// the page it last showed (#287) — but only a page of the app's own.
@Suite("Restored page")
struct RestoredPageTests {
    private let web = URL(fileURLWithPath: "/app/web")
    private var bundled: WindowContent {
        .bundled(directory: web, entry: "index.html", spaFallback: true)
    }

    @Test("a bundled window comes back to its page, query and fragment included")
    func bundledPage() throws {
        let url = try #require(URL(string: "pwa://localhost/window2.html?doc=42#top"))
        #expect(RestoredPage.content(bundled, restoring: url)
            == .bundled(directory: web, entry: "window2.html?doc=42#top", spaFallback: true))
    }

    @Test("an SPA route survives, percent-encoding and all")
    func spaRoute() throws {
        let url = try #require(URL(string: "pwa://localhost/notes/a%20b"))
        #expect(RestoredPage.content(bundled, restoring: url)
            == .bundled(directory: web, entry: "notes/a%20b", spaFallback: true))
    }

    @Test("nothing recorded, the bundle root, or a page outside the app: the config's own content")
    func notTheAppsPage() {
        #expect(RestoredPage.content(bundled, restoring: nil) == bundled)
        for raw in ["pwa://localhost/", "about:blank", "https://example.com/x", "pwa://elsewhere/x.html"] {
            #expect(RestoredPage.content(bundled, restoring: URL(string: raw)) == bundled, "\(raw)")
        }
    }

    @Test("a remote window comes back on its own site, and only there")
    func remote() throws {
        let site = try WindowContent.remote(#require(URL(string: "https://app.example.com/")))
        let page = try #require(URL(string: "https://app.example.com/docs/7?x=1"))
        #expect(RestoredPage.content(site, restoring: page) == .remote(page))
        #expect(RestoredPage.content(site, restoring: URL(string: "https://other.example.com/")) == site)
        #expect(RestoredPage.content(site, restoring: URL(string: "pwa://localhost/index.html")) == site)
    }
}
