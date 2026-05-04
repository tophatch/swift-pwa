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

    func setPosition(_ point: Point)
    func position() -> Point

    func focus()
    func minimize()
    func maximize()
    func setFullscreen(_ on: Bool)
    func isFullscreen() -> Bool

    func close()
}
