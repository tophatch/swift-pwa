import Foundation

/// What happens when the page tries to leave the app's own origin in the
/// window's main frame — a link to a website, `location.assign` to one, a
/// `target="_blank"`.
public enum OffOriginNavigation: String, Sendable, Codable, CaseIterable {
    /// Hand it to the system browser and leave the app where it was. The
    /// default, because the alternative strands the app: a swift-pwa window
    /// has no chrome, so a page that navigates to someone else's site has no
    /// back button and no address bar, and the app is gone for good.
    case system
    /// Load it in place, as a browser tab would. For an app that deliberately
    /// hosts third-party content in its own window and has its own way back.
    case inApp = "in-app"
}

/// Why the runtime refused to hand a URL to the OS.
public enum ExternalURLDenial: String, Sendable, Equatable {
    /// The app never declared this scheme. A build-time fix.
    case undeclaredScheme
    /// Not a URL the OS can be asked to open (no scheme, or a `pwa://` /
    /// `file://` URL that means something only inside this app).
    case notOpenable
}

public enum ExternalURLDecision: Sendable, Equatable {
    case open
    case refuse(ExternalURLDenial)
}

/// What a backend should do with a navigation the page has asked for.
public enum NavigationDisposition: Sendable, Equatable {
    /// Let the webview load it, as it always has.
    case allowInApp
    /// Cancel it and hand the URL to the OS instead.
    case openExternally
    /// Cancel it and go nowhere. The URL can neither be loaded usefully in
    /// this window nor handed to the system.
    case block(ExternalURLDenial)
}

/// The app-wide answer to "may this URL be handed to the operating system",
/// consulted by `system.openURL` and by each backend's navigation policy.
///
/// Opening a URL launches whatever app is registered for its scheme, so it is
/// a capability rather than a formatting concern — and the page asking is not
/// always the app's own code. `bridge.js` is injected into subframes as well
/// as the main frame, so an `<iframe>` of third-party content can invoke
/// commands, and a link in user-authored content is written by the user. Hence
/// the same shape as ``PermissionPolicy``: a build-time declaration, with the
/// common web schemes allowed out of the box because refusing those would make
/// every app declare the obvious.
///
/// ``defaultSchemes`` are the four that address a *document or a contact* —
/// they open a browser or a mail/dialler app, which is what a link in a page
/// means. Everything else — an app's own deep-link scheme (`things:`,
/// `obsidian:`), a conferencing handler, anything a machine happens to have
/// registered — has to be declared, so a page can't reach an arbitrary
/// installed app just by being able to build a string.
///
/// **Threading**: lock-guarded rather than actor-isolated, for the same reason
/// ``PermissionPolicy`` is — a navigation policy fires on whatever thread its
/// backend calls back on, none of which is pumping Swift's MainActor executor.
public final class ExternalURLPolicy: @unchecked Sendable {
    /// Schemes every app may open without declaring them: the web (`http`,
    /// `https`) and the two contact schemes every platform routes to a system
    /// app (`mailto`, `tel`).
    public static let defaultSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    private let lock = NSLock()
    private var declared: Set<String> = []
    private var appOrigins: Set<WebOrigin> = []
    private var navigation: OffOriginNavigation = .system
    private var diagnosed: Set<String> = []

    public init() {}

    /// Declare extra URL schemes this app may hand to the OS, beyond
    /// ``defaultSchemes``. Additive and case-insensitive; a trailing colon is
    /// accepted (`"things:"` and `"things"` are the same declaration).
    ///
    /// Call it from `configure`. Seeded from `pwa.json`'s
    /// `external_urls.schemes` by `swift-pwa init`.
    public func declare(schemes: some Sequence<String>) {
        let normalized = schemes.map(Self.normalize).filter { !$0.isEmpty }
        lock.lock()
        defer { lock.unlock() }
        declared.formUnion(normalized)
    }

    public func declare(schemes: String...) {
        declare(schemes: schemes)
    }

    /// Record an origin this app serves its own content on, so handing it to
    /// the OS is refused: the desktop would open a URL only this app can
    /// answer, and the user gets a browser error page.
    ///
    /// Backends call this as a window loads. It matters because two of them
    /// serve the bundle over **https** — `https://swift-pwa.local` on Windows
    /// and Android — where a scheme check can't tell app content from the
    /// web. Measured on a device before this existed: `system.openURL` on the
    /// bundle origin cheerfully opened Chrome on a page it can't fetch.
    public func registerAppOrigin(_ origin: WebOrigin?) {
        guard let origin else { return }
        lock.lock()
        defer { lock.unlock() }
        appOrigins.insert(origin)
    }

    /// Every scheme this app may open, defaults included.
    public var allowedSchemes: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Self.defaultSchemes.union(declared)
    }

    /// What an off-origin main-frame navigation does. Defaults to
    /// ``OffOriginNavigation/system``; seeded from `pwa.json`'s
    /// `external_urls.off_origin_navigation`.
    public var offOriginNavigation: OffOriginNavigation {
        get {
            lock.lock()
            defer { lock.unlock() }
            return navigation
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            navigation = newValue
        }
    }

    /// Whether `url` may be handed to the OS.
    ///
    /// Logs a one-off diagnostic for an undeclared scheme, naming the
    /// `pwa.json` key — the refusal otherwise reaches the page as a bridge
    /// error the app author reads as "opening URLs is broken" rather than
    /// "this scheme needs declaring". Once per scheme, so a page that retries
    /// doesn't bury the rest of the output.
    public func decide(_ url: URL) -> ExternalURLDecision {
        guard let scheme = url.scheme.map(Self.normalize), !scheme.isEmpty else {
            return .refuse(.notOpenable)
        }
        // `pwa` / `swift-pwa.local` is this app's own bundle origin and `file`
        // is its container: handing either to the OS would ask the desktop to
        // open something only the app can serve.
        guard !["pwa", "file", "about", "javascript", "data", "blob"].contains(scheme) else {
            return .refuse(.notOpenable)
        }
        guard allowedSchemes.contains(scheme) else {
            diagnoseUndeclared(scheme)
            return .refuse(.undeclaredScheme)
        }
        // The app's own content, reached over a scheme the OS *would* accept.
        lock.lock()
        let isOwnContent = appOrigins.contains { $0.covers(url) }
        lock.unlock()
        if isOwnContent { return .refuse(.notOpenable) }
        return .open
    }

    /// Schemes a main-frame navigation keeps in the app. None of them can
    /// reach another site, and blocking them would break real patterns — a
    /// page navigating to a `blob:` it generated, or clearing the frame with
    /// `about:blank`. `blob:` also can't be origin-compared: its URL is
    /// `blob:` followed by the *inner* origin, so ``WebOrigin`` reads no host
    /// from it.
    private static let inAppSchemes: Set<String> = ["about", "blob", "data", "javascript"]

    /// What to do with a navigation to `url` in a window whose own content is
    /// on `appOrigin`.
    ///
    /// This is the whole rule, in Core rather than in a backend, so all five
    /// behave identically and it can be tested without a webview. A backend's
    /// navigation delegate is then a translation of three cases into whatever
    /// its own callback expects.
    ///
    /// `isMainFrame: false` is always ``NavigationDisposition/allowInApp``. An
    /// iframe of third-party content is the page's own composition decision
    /// and doesn't take the window with it, so there is nothing to strand;
    /// only a main-frame navigation can lose the app.
    public func navigationDisposition(
        for url: URL, appOrigin: WebOrigin?, isMainFrame: Bool
    ) -> NavigationDisposition {
        guard isMainFrame else { return .allowInApp }
        guard let appOrigin else { return .allowInApp }
        if appOrigin.covers(url) { return .allowInApp }
        if let scheme = url.scheme?.lowercased(), Self.inAppSchemes.contains(scheme) {
            return .allowInApp
        }
        guard offOriginNavigation == .system else { return .allowInApp }
        switch decide(url) {
        case .open: return .openExternally
        case let .refuse(reason): return .block(reason)
        }
    }

    private func diagnoseUndeclared(_ scheme: String) {
        lock.lock()
        let isNew = diagnosed.insert(scheme).inserted
        lock.unlock()
        guard isNew else { return }
        // Through the sink rather than straight to stderr: on Android stderr
        // goes to /dev/null, and a message explaining a refusal the page
        // reports as a bare error code must not itself be silent.
        RuntimeDiagnostics.emit("""
        swift-pwa: refused to open a '\(scheme):' URL because this app has not declared \
        the scheme. Add `ctx.externalURLs.declare(schemes: "\(scheme)")` to your configure \
        closure, and `"\(scheme)"` to `external_urls.schemes` in pwa.json so the two agree.
        """)
    }

    /// Lower-cased, colon- and slash-stripped, so `"THINGS:"`, `"things://"`
    /// and `"things"` all name the same scheme.
    private static func normalize(_ scheme: String) -> String {
        scheme.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":/ "))
    }
}
