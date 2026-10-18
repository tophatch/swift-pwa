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
/// `__SWIFT_PWA__.on("app.openFile", ({ paths, names, mimeTypes }) => …)`.
/// The three arrays are index-aligned. `names[i]` is the file's display name:
/// on Android the path is a `content://` URI whose last segment is often an
/// id, so the name comes from the provider; elsewhere it's the path's last
/// component. `mimeTypes[i]` is the type the sending app or provider declared,
/// or `null` when none was, which is every desktop open, where the name
/// already says what the file is. Payloads are emitted
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

    private struct Payload: Encodable {
        let paths: [String]
        let names: [String]
        let mimeTypes: [String?]

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(paths, forKey: .paths)
            try c.encode(names, forKey: .names)
            // Encoded as an array of nullable strings, so a `null` stays in
            // its slot and the arrays keep their alignment.
            var types = c.nestedUnkeyedContainer(forKey: .mimeTypes)
            for type in mimeTypes {
                if let type { try types.encode(type) } else { try types.encodeNil() }
            }
        }

        enum CodingKeys: String, CodingKey { case paths, names, mimeTypes }
    }

    /// JSON payload `{ "paths", "names", "mimeTypes" }` for a set of opened
    /// files — the shape JS receives as the `on("app.openFile", …)` callback
    /// argument. `names` and `mimeTypes` are used only when they line up with
    /// `paths`; otherwise each name is the path's last component and each type
    /// `null`.
    public static func payload(paths: [String], names: [String]? = nil, mimeTypes: [String?]? = nil) -> Data {
        let body = Payload(
            paths: paths,
            names: names?.count == paths.count ? names! : paths.map(displayName(of:)),
            mimeTypes: mimeTypes?.count == paths.count ? mimeTypes! : paths.map { _ in nil }
        )
        return (try? JSONEncoder().encode(body)) ?? Data(#"{"paths":[],"names":[],"mimeTypes":[]}"#.utf8)
    }

    /// Emit `paths` on the bus, retained so a WebView that subscribes after a
    /// cold launch still receives them. A no-op for an empty list, so callers
    /// can pass the result of ``launchFilePaths(_:)`` unconditionally.
    public static func emit(
        _ paths: [String], names: [String]? = nil, mimeTypes: [String?]? = nil, on events: EventBus
    ) {
        guard !paths.isEmpty else { return }
        events.emit(channel, payload: payload(paths: paths, names: names, mimeTypes: mimeTypes), retain: true)
    }

    /// The last component of a path or `file:` URL, percent-decoded. Only a
    /// `file:` prefix is read as a URL: a Windows path such as `C:\a.pdf`
    /// would otherwise parse as one with the scheme `c`.
    static func displayName(of path: String) -> String {
        if path.lowercased().hasPrefix("file:"), let url = URL(string: path), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// File paths among the process launch arguments — the desktop "open
    /// with" / file-association convention on Linux (`.desktop` `%F` / `%U`)
    /// and Windows. Drops `argv[0]` and keeps only arguments that name a file
    /// that exists on disk, so flags (`--foo`) and non-file arguments are
    /// ignored. (macOS/iOS don't use argv for this — Launch Services delivers
    /// an Apple event / scene URL context instead.)
    ///
    /// A `file:` URL counts as a path: an app that also declares a URL scheme
    /// gets `Exec=… %U` rather than `%F`, and the desktop then hands local
    /// files over as `file:///…` URIs instead of bare paths. Percent-decoding
    /// is `URL`'s, so a name with a space survives the round trip.
    public static func launchFilePaths(_ arguments: [String] = CommandLine.arguments) -> [String] {
        arguments.dropFirst().compactMap { arg -> String? in
            guard !arg.hasPrefix("-") else { return nil }
            if FileManager.default.fileExists(atPath: arg) { return arg }
            guard let url = URL(string: arg), url.isFileURL else { return nil }
            let path = url.path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
    }
}
