import Foundation

/// Delivery of OS "open this file with the app" events to the web app.
///
/// Every platform has some way to launch (or foreground) an app *with* a
/// document: macOS/iOS Launch Services (`application(_:open:)` /
/// `scene(_:openURLContexts:)`), and the desktop file-argument convention on
/// Linux (`.desktop` `Exec=… %F`) and Windows (file-association argv). Until
/// now swift-pwa could *declare* a file association (via the `info_plist`
/// passthrough) but dropped the file — there was no path from the OS open
/// event to JS. This routes them all through one event-bus channel.
///
/// The app subscribes from JS with
/// `__SWIFT_PWA__.on("app.openFile", ({ paths }) => …)`. Payloads are emitted
/// **retained**, so a file that *launched* the app (the open event fires
/// before the WebView has loaded and before any JS listener exists) is
/// replayed to the WebView as soon as it subscribes — the single most
/// important detail, since a naive emit-at-capture-time would lose every
/// double-click-to-launch. (A consequence of retention: a manual page reload
/// re-subscribes and so re-receives the launch file. Reopening the launched
/// document on reload is reasonable; apps that care can ignore a repeat.)
public enum OpenFile {
    /// The event-bus channel opened-file events are delivered on.
    public static let channel = "app.openFile"

    /// JSON payload `{ "paths": [...] }` for a set of opened file paths — the
    /// shape JS receives as the `on("app.openFile", …)` callback argument.
    public static func payload(paths: [String]) -> Data {
        (try? JSONEncoder().encode(["paths": paths])) ?? Data(#"{"paths":[]}"#.utf8)
    }

    /// Emit `paths` on the bus, retained so a WebView that subscribes after a
    /// cold launch still receives them. A no-op for an empty list, so callers
    /// can pass the result of ``launchFilePaths(_:)`` unconditionally.
    public static func emit(_ paths: [String], on events: EventBus) {
        guard !paths.isEmpty else { return }
        events.emit(channel, payload: payload(paths: paths), retain: true)
    }

    /// File paths among the process launch arguments — the desktop "open
    /// with" / file-association convention on Linux (`.desktop` `%F`) and
    /// Windows. Drops `argv[0]` and keeps only arguments that name a file that
    /// exists on disk, so flags (`--foo`) and non-file arguments are ignored.
    /// (macOS/iOS don't use argv for this — Launch Services delivers an Apple
    /// event / scene URL context instead.)
    public static func launchFilePaths(_ arguments: [String] = CommandLine.arguments) -> [String] {
        arguments.dropFirst().filter { arg in
            !arg.hasPrefix("-") && FileManager.default.fileExists(atPath: arg)
        }
    }
}
