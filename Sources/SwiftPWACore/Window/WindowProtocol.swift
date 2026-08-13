import Foundation

/// Cross-platform window contract. Each backend (`SwiftPWAWebKit`,
/// `SwiftPWAGTK`) provides a concrete type conforming to this protocol;
/// `WindowPlugin` calls these methods in response to JS commands.
@MainActor
public protocol Window: AnyObject, Sendable {
    var id: WindowID { get }
    var webView: any PWAWebView { get }

    /// Lifecycle / state events, multicast. Each call returns a fresh
    /// stream subscribed to the same underlying source.
    func eventStream() -> AsyncStream<WindowEvent>

    func setTitle(_ title: String)
    func title() -> String

    func setSize(_ size: Size, animated: Bool)
    func size() -> Size

    /// Move the window. **Best-effort** — backends running on display
    /// servers that own positioning (Wayland, GTK4) may silently
    /// no-op. Use `position()` to read back the actual location.
    func setPosition(_ point: Point)

    /// Current window position. Returns `.zero` on backends that don't
    /// expose position (Wayland, GTK4).
    func position() -> Point

    func focus()
    func minimize()
    func maximize()
    func setFullscreen(_ on: Bool)
    func isFullscreen() -> Bool

    /// Whether the compositor is actually showing this window.
    ///
    /// Not cosmetic: a webview whose window isn't being shown gets its
    /// `requestAnimationFrame` callbacks **throttled or stopped**, so a page that
    /// draws (or restores its state) in a rAF callback silently does nothing while
    /// it's covered — and a driver screenshot of that window returns a perfectly
    /// clean image of the stale content, which reads as an app bug. It cost an
    /// adopter an hour twice before they knew to look, so the driver reports it
    /// (`drive windows`) and warns.
    ///
    /// Default-implemented as ``WindowVisibility/unknown`` so an existing external
    /// conformance keeps compiling; see the per-backend notes on the enum for who
    /// answers what.
    func visibility() -> WindowVisibility

    func close()
}

public extension Window {
    func visibility() -> WindowVisibility { .unknown }
}

/// Whether a window is on screen, per the platform's own answer.
///
/// Three cases rather than a `Bool` because "we can't tell" is the truth on some
/// backends and worth saying out loud: X11/Wayland expose no occlusion query, so
/// a GTK backend answering `visible` would be guessing.
///
/// - `visible`: on screen, and as far as the platform will say, not covered.
/// - `hidden`: minimized, or occluded — the compositor isn't showing it, so
///   expect `requestAnimationFrame` to be throttled or stopped.
/// - `unknown`: the platform doesn't say. **macOS** answers properly
///   (`NSWindow.occlusionState`); **Windows** detects minimized only; **Linux**
///   and **Android** report `unknown`.
public enum WindowVisibility: String, Sendable, Codable {
    case visible
    case hidden
    case unknown
}
