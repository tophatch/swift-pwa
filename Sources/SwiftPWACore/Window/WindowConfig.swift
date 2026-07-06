import Foundation

/// Stable identifier for a window. Round-trippable to JS.
public struct WindowID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let raw: String

    public init(raw: String) { self.raw = raw }
    public init() { raw = UUID().uuidString }

    public var description: String {
        raw
    }
}

/// What a window's webview should load on creation.
public enum WindowContent: Sendable, Equatable {
    /// A `pwa://`-resolvable folder containing the web bundle. The
    /// `directory` is exposed as `pwa://localhost/...`; the index file
    /// is `pwa://localhost/<entry>` (default `index.html`).
    case bundled(directory: URL, entry: String)

    /// A remote URL. Used in development (`PWA_DEV_SERVER`) or for
    /// thin clients that wrap a hosted PWA.
    case remote(URL)

    public static func bundled(directory: URL) -> WindowContent {
        .bundled(directory: directory, entry: "index.html")
    }
}

/// Initial configuration for a new window.
public struct WindowConfig: Sendable {
    public var title: String
    public var size: Size
    public var minSize: Size?
    public var maxSize: Size?
    /// Initial top-left position. `nil` lets the platform place the window
    /// (macOS centres it, GTK defers to the window manager, Windows uses
    /// `CW_USEDEFAULT`). Best-effort, mirroring ``Window/setPosition(_:)``:
    /// GTK4 / Wayland ignore it. Chiefly populated by ``WindowStateStore``
    /// when ``rememberState`` restores a remembered location.
    public var origin: Point?
    public var resizable: Bool
    public var fullscreen: Bool
    public var visibleOnLaunch: Bool
    public var content: WindowContent
    /// Native surface background colour (hex, e.g. `"#F4F7F5"`), applied
    /// before the page's first paint so there's no white/black flash and
    /// the scroll overscroll area matches. `nil` keeps the platform default
    /// (opaque white). A single solid colour can only approximate a
    /// gradient page background — close, but not pixel-exact.
    public var backgroundColor: String?
    /// Persist this window's size — and, where the platform exposes it,
    /// position — across launches, restoring it the next time a window with
    /// the same ``stateKey`` is created. Off by default so an app opts in
    /// explicitly (the `swift-pwa init` scaffold sets it on for new apps).
    ///
    /// **Desktop only.** macOS / GTK3 / Windows restore both size and
    /// position; GTK4 / Wayland restore size only (the compositor owns
    /// placement). iOS / Android windows are full-screen, so there's nothing
    /// to remember — the flag is a no-op there. Geometry is written to a
    /// small `window-state.json` in the per-app data directory
    /// (``PlatformDirectories``), keyed by ``stateKey``.
    public var rememberState: Bool
    /// Identity used to persist / restore geometry when ``rememberState`` is
    /// on. Defaults to `"main"`. Give each window in a multi-window app its
    /// own key so their frames don't clobber one another; two live windows
    /// sharing a key will fight over the same saved geometry.
    public var stateKey: String

    public init(
        title: String,
        size: Size,
        minSize: Size? = nil,
        maxSize: Size? = nil,
        origin: Point? = nil,
        resizable: Bool = true,
        fullscreen: Bool = false,
        visibleOnLaunch: Bool = true,
        content: WindowContent,
        backgroundColor: String? = nil,
        rememberState: Bool = false,
        stateKey: String = "main"
    ) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.maxSize = maxSize
        self.origin = origin
        self.resizable = resizable
        self.fullscreen = fullscreen
        self.visibleOnLaunch = visibleOnLaunch
        self.content = content
        self.backgroundColor = backgroundColor
        self.rememberState = rememberState
        self.stateKey = stateKey
    }
}
