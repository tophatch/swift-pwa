import Foundation
import SwiftPWACore

/// In-memory `Window` for unit testing.
///
/// All mutations are recorded in `events` and reflected in the public
/// state properties so tests can assert either by snapshotting the
/// event log or by reading the current state.
@MainActor
public final class MockWindow: Window {
    public let id: WindowID
    public let webView: any PWAWebView

    public private(set) var currentTitle: String
    public private(set) var currentSize: Size
    public private(set) var currentPosition: Point
    public private(set) var currentFullscreen: Bool = false
    public private(set) var isClosed: Bool = false
    public private(set) var receivedActions: [Action] = []

    public enum Action: Equatable, Sendable {
        case setTitle(String)
        case setSize(Size, animated: Bool)
        case setPosition(Point)
        case focus, minimize, maximize
        case setFullscreen(Bool)
        case close
    }

    private var continuations: [UUID: AsyncStream<WindowEvent>.Continuation] = [:]

    public init(
        id: WindowID = WindowID(),
        title: String = "Mock",
        size: Size = .init(width: 800, height: 600),
        position: Point = .zero,
        webView: (any PWAWebView)? = nil
    ) {
        self.id = id
        self.webView = webView ?? MockWebView()
        self.currentTitle = title
        self.currentSize = size
        self.currentPosition = position
    }

    public func eventStream() -> AsyncStream<WindowEvent> {
        let key = UUID()
        return AsyncStream { continuation in
            self.continuations[key] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in self.continuations.removeValue(forKey: key) }
            }
        }
    }

    /// Manually push an event to all current subscribers.
    public func emit(_ event: WindowEvent) {
        for c in continuations.values { c.yield(event) }
    }

    // MARK: - Window

    public func setTitle(_ title: String) {
        receivedActions.append(.setTitle(title))
        currentTitle = title
    }
    public func title() -> String { currentTitle }

    public func setSize(_ size: Size, animated: Bool) {
        receivedActions.append(.setSize(size, animated: animated))
        currentSize = size
        emit(.didResize(size))
    }
    public func size() -> Size { currentSize }

    public func setPosition(_ point: Point) {
        receivedActions.append(.setPosition(point))
        currentPosition = point
        emit(.didMove(point))
    }
    public func position() -> Point { currentPosition }

    public func focus() {
        receivedActions.append(.focus)
        emit(.didFocus)
    }

    public func minimize() {
        receivedActions.append(.minimize)
        emit(.didMinimize)
    }

    public func maximize() {
        receivedActions.append(.maximize)
    }

    public func setFullscreen(_ on: Bool) {
        receivedActions.append(.setFullscreen(on))
        currentFullscreen = on
        emit(on ? .didEnterFullscreen : .didExitFullscreen)
    }
    public func isFullscreen() -> Bool { currentFullscreen }

    public func close() {
        receivedActions.append(.close)
        isClosed = true
        emit(.willClose)
        emit(.didClose)
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }
}
