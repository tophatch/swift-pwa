import Foundation

/// Delivery of OS "open this URL with the app" events to the web app — the
/// receiving end of a deep link.
///
/// This is the inbound counterpart to ``ExternalURLPolicy`` / `system.openURL`:
/// an app can hand a URL to the desktop, and this is how one arrives. A URL the
/// OS routes to the app — a `myapp://…` link clicked in Mail, `open myapp://x`,
/// an Android `ACTION_VIEW` intent — reaches every backend's launch path and is
/// re-emitted here.
///
/// The app subscribes from JS with
/// `__SWIFT_PWA__.on("app.openURL", ({ url }) => …)`. Payloads are emitted
/// **retained**, so a URL that *launched* the app (the open event fires before
/// the WebView has loaded and before any JS listener exists) is replayed as
/// soon as the page subscribes — the same reason ``OpenFile`` retains.
///
/// **A separate channel from ``OpenFile``, deliberately.** The payloads mean
/// different things: a path to read with `fs.readBinary` versus a URL to route.
/// An app that handles documents shouldn't start receiving deep links it never
/// declared, and a custom-scheme URL has no path to put on `app.openFile` in
/// the first place.
///
/// **Batched, because retention keeps only the latest value.** One OS event can
/// carry several URLs (`open myapp://a myapp://b`, iOS's `Set<UIOpenURLContext>`),
/// and emitting them as separate retained events would replay only the last to a
/// late subscriber. So the payload carries `urls` *and* `url` (the first) — the
/// `{ list, first }` shape `dialog.openDirectory` already uses — which keeps the
/// one-URL case, the overwhelmingly common one, a plain destructure.
public enum OpenURL {
    /// The event-bus channel opened-URL events are delivered on.
    public static let channel = "app.openURL"

    /// JSON payload `{ "urls": [...], "url": "..." }` for a set of opened URLs
    /// — the shape JS receives as the `on("app.openURL", …)` callback argument.
    /// `url` is the first entry, so a router can destructure it directly.
    public static func payload(urls: [String]) -> Data {
        struct Payload: Encodable {
            let urls: [String]
            let url: String?
        }
        let value = Payload(urls: urls, url: urls.first)
        return (try? JSONEncoder().encode(value)) ?? Data(#"{"urls":[],"url":null}"#.utf8)
    }

    /// Emit `urls` on the bus, retained so a WebView that subscribes after a
    /// cold launch still receives them. A no-op for an empty list, so callers
    /// can pass the result of ``launchURLs(_:)`` unconditionally.
    public static func emit(_ urls: [String], on events: EventBus) {
        guard !urls.isEmpty else { return }
        events.emit(channel, payload: payload(urls: urls), retain: true)
    }

    /// Deep-link URLs among the process launch arguments — the desktop
    /// URL-handler convention on Linux (`.desktop` `Exec=… %U`) and Windows
    /// (the `shell\open\command` registered for the scheme). macOS/iOS don't
    /// use argv for this; Launch Services delivers an Apple event / scheme URL
    /// context instead.
    ///
    /// Drops `argv[0]`, flags, existing file paths (those are ``OpenFile``'s),
    /// and `file:` URLs (a document, not a deep link — ``OpenFile`` takes those
    /// too). A scheme must be at least two characters so a Windows drive path
    /// (`C:\Users\…`) isn't mistaken for a `c:` URL.
    public static func launchURLs(_ arguments: [String] = CommandLine.arguments) -> [String] {
        arguments.dropFirst().filter { arg in
            guard !arg.hasPrefix("-"), !FileManager.default.fileExists(atPath: arg) else { return false }
            guard let scheme = URL(string: arg)?.scheme?.lowercased() else { return false }
            return scheme.count >= 2 && scheme != "file"
        }
    }
}
