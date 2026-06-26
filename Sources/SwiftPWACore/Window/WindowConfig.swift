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

    public init(
        title: String,
        size: Size,
        minSize: Size? = nil,
        maxSize: Size? = nil,
        resizable: Bool = true,
        fullscreen: Bool = false,
        visibleOnLaunch: Bool = true,
        content: WindowContent,
        backgroundColor: String? = nil
    ) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.maxSize = maxSize
        self.resizable = resizable
        self.fullscreen = fullscreen
        self.visibleOnLaunch = visibleOnLaunch
        self.content = content
        self.backgroundColor = backgroundColor
    }
}
