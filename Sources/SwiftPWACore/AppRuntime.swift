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

    /// What happens when the app's last window closes. **macOS only** — it is
    /// the one platform here where an app outlives its windows; see
    /// ``LastWindowClosedPolicy``, which documents why the other backends
    /// ignore it. Defaults to ``LastWindowClosedPolicy/reopen``.
    ///
    /// Seeded from `pwa.json`'s `macos.last_window_closed` at `swift-pwa init`
    /// time, like the `window` block: the value here is the running app's
    /// source of truth, and editing `pwa.json` later doesn't change it.
    var lastWindowClosed: LastWindowClosedPolicy { get set }

    /// Which URLs may be handed to the operating system, and what an
    /// off-origin navigation does. Consulted by `system.openURL` and by each
    /// backend's navigation policy, so one declaration governs both routes out
    /// of the app; see ``ExternalURLPolicy``.
    ///
    /// Seeded from `pwa.json`'s `external_urls` block at `swift-pwa init` time.
    var externalURLs: ExternalURLPolicy { get }

    /// How this backend hands a URL to the operating system, or `nil` where it
    /// has no way to.
    ///
    /// Every backend already builds one for `SystemPlugin`; exposing it here is
    /// what lets a plugin that needs a browser be registered with **one line
    /// that compiles on all five** — `ctx.use(AuthPlugin(networkClient: …))` —
    /// instead of an `#if os(…)` ladder naming `AppleURLOpener`,
    /// `GTKURLOpener`, `WindowsURLOpener` and `AndroidURLOpener` in turn. A
    /// per-platform branch in an adopter's shared `main.swift` is a branch that
    /// breaks on the platform its author can't test.
    ///
    /// Defaults to `nil` so a backend that hasn't wired one (and the headless
    /// catalog context) still conforms; consumers report `E_UNIMPLEMENTED`
    /// rather than appearing to work.
    var urlOpener: (any URLOpener)? { get }

    /// The OS's own authorization browser, where the platform has one —
    /// `ASWebAuthenticationSession` on macOS and iOS, `nil` elsewhere.
    ///
    /// Here rather than passed in for the same reason as ``urlOpener``, and
    /// more sharply: the concrete type lives in the Apple backend, so an app
    /// naming it directly cannot compile for Linux, Windows or Android at all.
    var authorizationSession: (any AuthorizationSessionPresenter)? { get }
}

public extension AppContext {
    /// No opener unless the backend supplies one.
    var urlOpener: (any URLOpener)? {
        nil
    }

    /// No OS authorization session unless the backend supplies one.
    var authorizationSession: (any AuthorizationSessionPresenter)? {
        nil
    }

    /// Serve `directory`'s contents on the bundle origin under `prefix`
    /// (e.g. `/packs`), so page JS can reference them with an origin-relative
    /// URL (`/packs/<id>/clip.webm`) on every backend. Read-only (GET); writes
    /// still go through `fs.*`. The prefix is app-chosen and must not be the
    /// bundle root `/`; remounting the same prefix replaces it. Safe to call
    /// before or after `createWindow` — handlers read the mount table live.
    ///
    /// Android's asset loader is built at Activity-init, before `configure`
    /// runs, so a mount that must exist before the first page load is still
    /// declared in `pwa.json`'s `build.serve`. A runtime call works there too
    /// (#213) — the backend asks this router for every request the WebView
    /// makes — with one platform limit: a `Range` request is served from the
    /// requested offset to the end of the file under a **200**, because the
    /// WebView rejects a `206` from an intercepted response outright. See the
    /// content-packs design doc.
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
