import Foundation

/// Opens the app's first window at a chosen path inside the bundle instead of
/// its declared entry — `SWIFT_PWA_INITIAL_ROUTE=/doc.html?id=42`.
///
/// The problem it solves: to land on a specific screen without navigating there
/// by hand, people patch `location.replace(...)` into the **built bundle's**
/// `index.html`, which mutates the artifact under test. A launch-time route
/// makes that a property of the launch instead. It's the same idea as the file
/// association path an OS-launched app already receives on `app.openFile` — a
/// launch argument that says *where to start* — and it's useful well beyond
/// testing: reproducing a bug report, or a demo that opens mid-flow.
///
/// **First window only.** The override is consumed once per process, so a
/// multi-window app doesn't open every window on the same route. Later windows
/// (and a reload of the first) use their declared entry.
///
/// Bundled content only. An app pointed at a remote origin (`PWA_DEV_SERVER`)
/// should put the route in that URL, which is already a full URL and unambiguous
/// about what a path means.
public enum InitialRoute {
    /// The env var a backend checks. Set it to a bundle-relative path, with or
    /// without a leading `/`; a query string and fragment are preserved
    /// (`/doc.html?id=42#page3`). Unset — the normal case — every window opens
    /// at its declared entry.
    public static let environmentVariable = "SWIFT_PWA_INITIAL_ROUTE"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var consumed = false

    /// The path the next bundled window should load: the requested route the
    /// first time it's asked, `entry` every time after.
    ///
    /// Backends call this where they build the initial URL — *not* by rewriting
    /// `WindowContent` — so the declared entry still serves as the SPA-fallback
    /// document. A deep-linked route landing on a router-only path is exactly
    /// when that fallback matters.
    public static func take(declared entry: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard !consumed, let route = requested else { return entry }
        consumed = true
        return route
    }

    /// The requested route, normalized, or `nil` when none was asked for or the
    /// value isn't usable.
    static var requested: String? {
        guard let raw = ProcessInfo.processInfo.environment[environmentVariable] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // A route is a path *inside* the bundle. The scheme handlers guard
        // traversal anyway, but refusing here means the failure names the
        // launch argument rather than surfacing as a mysterious 404.
        guard !trimmed.contains("..") else {
            FileHandle.standardError.writeQuietly(Data("""
            swift-pwa: ignoring \(environmentVariable)=\(trimmed) — a route can't traverse out of the bundle.

            """.utf8))
            return nil
        }
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
    }
}
