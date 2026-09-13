import Foundation

public extension PWAManifest {
    /// `pwa.json`'s `external_urls` block — which URLs the app may hand to the
    /// operating system, and what happens when the page tries to leave the
    /// app's own origin.
    ///
    /// ```json
    /// "external_urls": {
    ///   "schemes": ["things", "obsidian"],
    ///   "allow_any_scheme": false,
    ///   "off_origin_navigation": "system"
    /// }
    /// ```
    ///
    /// All three seed `ctx.externalURLs` in the generated `App.swift`, the
    /// way the `window` block seeds `WindowConfig`: the value in the running
    /// app is the source of truth, and editing `pwa.json` afterwards doesn't
    /// change a built app. Unlike `permissions`, nothing here reaches a
    /// platform artifact — there is no Info.plist or manifest entry for "may
    /// open a URL" — so it is a seed rather than a cross-checked declaration.
    ///
    /// > `ios.info_plist`'s `LSApplicationQueriesSchemes` is a *different*
    /// > list: it governs `canOpenURL`, which the runtime deliberately doesn't
    /// > call (see `AppleURLOpener`). Declaring a scheme here does not require
    /// > declaring it there.
    struct ExternalURLsSection: Codable, Sendable, Equatable {
        /// Extra schemes beyond the four every app may open
        /// (`http`, `https`, `mailto`, `tel`) — an app's own deep-link scheme,
        /// a conferencing handler. Case-insensitive, with or without the
        /// colon.
        public var schemes: [String]?

        /// Accept the OS's routing for **any** scheme instead of the
        /// allowlist above. Off by default.
        ///
        /// For an app whose URLs are written by the person using it — a note
        /// with whatever deep link they typed — `schemes` can only be a guess,
        /// and the app they own that you didn't list is refused with no fix
        /// short of a rebuild. This says "the OS decides", which it already
        /// does: an unhandled scheme answers `opened: false` either way.
        ///
        /// It softens nothing else — `pwa:`, `file:`, `javascript:` and the
        /// app's own origin stay refused. `bridge.js` runs in subframes too, so
        /// it is scoped to the app's own page **where the backend reports which
        /// frame called** (Apple today): content the page embeds keeps the
        /// declared allowlist. Where it can't — both GTK backends — the flag
        /// applies to any frame, so leave it off for an app that hosts other
        /// people's content there.
        public var allowAnyScheme: Bool?

        /// `"system"` (the default) hands an off-origin main-frame navigation
        /// to the system browser and leaves the app where it was. `"in-app"`
        /// loads it in place, as a browser tab would — for an app that
        /// deliberately hosts other people's pages in its own window and has
        /// its own way back.
        public var offOriginNavigation: String?

        public init(
            schemes: [String]? = nil,
            allowAnyScheme: Bool? = nil,
            offOriginNavigation: String? = nil
        ) {
            self.schemes = schemes
            self.allowAnyScheme = allowAnyScheme
            self.offOriginNavigation = offOriginNavigation
        }
    }
}
