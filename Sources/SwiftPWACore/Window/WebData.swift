import Foundation

/// Gives a launch web storage of its own that is gone when it quits:
/// `SWIFT_PWA_WEB_DATA=ephemeral`.
///
/// By default every launch of an app shares one persistent web data store —
/// `localStorage`, IndexedDB, cookies, caches — which is what a user's app
/// wants and what a test suite doesn't. A value one run writes is there in
/// every later run, and runs launched side by side read each other's writes,
/// so a test that reads storage back is flaky for reasons nothing in the test
/// can see. An ephemeral launch starts empty, keeps everything in memory, and
/// shares nothing with the persistent store or with any other launch. The
/// app's windows still share it with each other, as they share the persistent
/// one.
///
/// Only web storage. The app's own files (`app.documentsDir`, what `fs.*`
/// writes) aren't web data and are where they always are.
///
/// Each backend uses its engine's own in-memory store: a non-persistent
/// `WKWebsiteDataStore` on Apple, an ephemeral WebKitGTK context (GTK3) or
/// network session (GTK4) on Linux, and an InPrivate WebView2 profile on
/// Windows. Android's WebView has no in-memory store: there the generated
/// Activity reads the variable (a launch extra, in debug builds) and gives the
/// process a data directory of its own, which the next launch deletes.
public enum WebData {
    /// The env var a backend checks. `ephemeral` gives the launch its own
    /// in-memory store; unset, or `persistent`, is the normal shared one.
    public static let environmentVariable = "SWIFT_PWA_WEB_DATA"

    /// Whether this launch's web storage is ephemeral. Read once: every window
    /// of a launch must agree, or a second window would land in another store.
    public static let isEphemeral: Bool = {
        let raw = ProcessInfo.processInfo.environment[environmentVariable]
        guard let ephemeral = ephemeral(raw) else {
            // A misspelling would otherwise run the suite against the shared
            // store it set this to get away from, and nothing would say so.
            RuntimeDiagnostics.emit("""
            swift-pwa: \(environmentVariable)=\(raw ?? "") isn't a setting — use `ephemeral`, or unset it. \
            Web storage is persistent for this launch.
            """)
            return false
        }
        return ephemeral
    }()

    /// What a value of the variable asks for; `nil` for a value that isn't one.
    static func ephemeral(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "", "persistent": false
        case "ephemeral": true
        default: nil
        }
    }
}
