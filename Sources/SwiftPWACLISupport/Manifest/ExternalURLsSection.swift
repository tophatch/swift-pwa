import Foundation

public extension PWAManifest {
    /// `pwa.json`'s `external_urls` block — which URLs the app may hand to the
    /// operating system, and what happens when the page tries to leave the
    /// app's own origin.
    ///
    /// ```json
    /// "external_urls": {
    ///   "schemes": ["things", "obsidian"],
    ///   "off_origin_navigation": "system"
    /// }
    /// ```
    ///
    /// Both fields seed `ctx.externalURLs` in the generated `App.swift`, the
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

        /// `"system"` (the default) hands an off-origin main-frame navigation
        /// to the system browser and leaves the app where it was. `"in-app"`
        /// loads it in place, as a browser tab would — for an app that
        /// deliberately hosts other people's pages in its own window and has
        /// its own way back.
        public var offOriginNavigation: String?

        public init(schemes: [String]? = nil, offOriginNavigation: String? = nil) {
            self.schemes = schemes
            self.offOriginNavigation = offOriginNavigation
        }
    }
}
