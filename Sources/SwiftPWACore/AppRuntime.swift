import Foundation

/// Top-level entry point. A backend (`SwiftPWAWebKit`, `SwiftPWAGTK`)
/// provides one of these; user code obtains it via `SwiftPWA.runtime()`
/// on the umbrella module.
public protocol AppRuntime: AnyObject, Sendable {
    /// Configure the app, then run the platform event loop. Does not
    /// return until the app exits.
    @MainActor
    func run(
        _ configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
    ) throws -> Never
}

/// Per-app, mutable context passed to the configure closure.
@MainActor
public protocol AppContext: AnyObject, Sendable {
    var registry: CommandRegistry { get }

    /// All windows currently alive in this app, keyed by id.
    var windows: [WindowID: any Window] { get }

    /// Create a new window. Backends implement this; the resulting
    /// window's webview is wired into the bridge runtime automatically.
    @discardableResult
    func createWindow(_ config: WindowConfig) throws -> any Window

    /// Install a plugin (registers its commands into the registry).
    func use(_ plugin: any Plugin)

    /// Look up a window by id. `O(1)`.
    func window(_ id: WindowID) -> (any Window)?

    /// Begin orderly shutdown of the platform event loop with the given exit code.
    func quit(exitCode: Int32)

    /// The shared asset router for this app. It serves the bundle (the `/`
    /// mount, installed by the first `.bundled` window) plus any directories
    /// added via ``serveDirectory(_:at:)``. Backends hand this single
    /// instance to every window's scheme handler, so a mount added at runtime
    /// (e.g. after extracting a content pack) takes effect for in-flight and
    /// future requests without re-registering anything.
    var assetProvider: AssetProvider { get }

    /// The app-wide server-push event bus. One instance per app, shared by
    /// every window, so a single ``EventBus/emit(_:payload:retain:)`` fans out
    /// to subscribers in all windows. The built-in `EventsPlugin` bridges it to
    /// the JS `on(channel, cb)` / `emit(channel, payload)` API. Prefer the
    /// typed ``emit(_:_:retain:)`` convenience for Swift-side pushes.
    var events: EventBus { get }

    /// Whether a page may use the camera, microphone or location — consulted
    /// by every backend at its own permission seam, so one declaration governs
    /// all five. Nothing is permitted until declared; see ``PermissionPolicy``.
    var permissions: PermissionPolicy { get }
}

public extension AppContext {
    /// Serve `directory`'s contents on the bundle origin under `prefix`
    /// (e.g. `/packs`), so page JS can reference them with an origin-relative
    /// URL (`/packs/<id>/clip.webm`) on every backend. Read-only (GET); writes
    /// still go through `fs.*`. The prefix is app-chosen and must not be the
    /// bundle root `/`; remounting the same prefix replaces it. Safe to call
    /// before or after `createWindow` — handlers read the mount table live.
    ///
    /// On Android the asset loader is built at Activity-init (before `configure`
    /// runs), so mounts that must exist at startup are declared in `pwa.json`'s
    /// `build.serve` instead; a runtime `serveDirectory` for an undeclared
    /// prefix is a desktop capability. See the content-packs design doc.
    func serveDirectory(_ directory: URL, at prefix: String) {
        assetProvider.mount(directory, at: prefix, writable: true)
    }

    /// Remove a mount previously added with ``serveDirectory(_:at:)``. The
    /// bundle `/` mount cannot be removed.
    func unserveDirectory(at prefix: String) {
        assetProvider.unmount(at: prefix)
    }

    /// Push an `Encodable` payload to JS subscribers of `channel` in every
    /// window — the Swift-side half of the server-push story. Sugar over
    /// ``EventBus/emit(_:_:retain:)`` on ``events``; JS receives it via
    /// `__SWIFT_PWA__.on(channel, cb)`.
    ///
    /// Set `retain: true` to remember this as the channel's latest value and
    /// replay it to windows/subscribers that connect later.
    ///
    /// `events` is `Sendable`, so to emit from a background thread (a file
    /// watcher, an import task) capture it once — `let bus = ctx.events` — and
    /// call `bus.emit(...)` off the main actor rather than hopping back here.
    func emit(_ channel: String, _ payload: some Encodable, retain: Bool = false) throws {
        try events.emit(channel, payload, retain: retain)
    }

    /// Push a payload-less signal to subscribers of `channel` (JS receives
    /// `null`). See ``emit(_:_:retain:)``.
    func emit(_ channel: String, retain: Bool = false) {
        events.signal(channel, retain: retain)
    }
}
