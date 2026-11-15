import Foundation

/// One item a page adds to the platform's own text-selection menu — the
/// iOS edit menu, Android's floating selection toolbar, and the right-click
/// menu on a selection on the desktop (`selection.setActions`).
public struct SelectionAction: Sendable, Codable, Equatable {
    /// Comes back unchanged in the `action` event when the item is chosen.
    public var id: String
    /// The label the menu shows.
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Whether a finger the platform took for text selection has gone down or
/// lifted — see ``WebViewSelection/gesture(_:)``.
public enum SelectionGesturePhase: String, Sendable, Codable {
    case began
    case ended
}

/// What `selection.subscribe` delivers to the page.
///
/// On the wire, `{type: "action", id}` or `{type: "gesture", phase}`.
public enum SelectionEvent: Sendable, Equatable, Encodable {
    /// The user chose one of the page's ``SelectionAction``s. The selection is
    /// still in place, so the page reads it from the DOM as it would anywhere
    /// else.
    case action(id: String)
    case gesture(SelectionGesturePhase)

    private enum CodingKeys: String, CodingKey { case type, id, phase }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .action(id):
            try container.encode("action", forKey: .type)
            try container.encode(id, forKey: .id)
        case let .gesture(phase):
            try container.encode("gesture", forKey: .type)
            try container.encode(phase, forKey: .phase)
        }
    }
}

/// A webview's text-selection state shared between the page and the backend:
/// the actions the page asked for, and the events going back to it.
///
/// Each backend owns one per webview. Its native menu hook reads ``actions``
/// each time the platform builds the menu, which is why nothing has to be
/// pushed into a menu that is already on screen; and its selection-gesture
/// hooks call ``gesture(_:)``, which reports a *change* only, so a backend
/// with two sources for the same finger (Android's long press and its handle
/// views) can't report it twice.
///
/// Lock-guarded and callable from any thread: the hooks fire on each
/// platform's UI thread, and the plugin reads from the cooperative pool.
public final class WebViewSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [SelectionAction] = []
    private var gestureActive = false
    private var subscribers: [UUID: AsyncStream<SelectionEvent>.Continuation] = [:]
    private let actionsChanged: (@Sendable ([SelectionAction]) async throws -> Void)?

    /// - Parameter actionsChanged: Called by ``setActions(_:)`` for a backend
    ///   whose menu is built somewhere Swift can't read from at the time —
    ///   Android's, in Kotlin. A failure there fails the page's call. Backends
    ///   that read ``actions`` when the menu is built pass nothing.
    public init(actionsChanged: (@Sendable ([SelectionAction]) async throws -> Void)? = nil) {
        self.actionsChanged = actionsChanged
    }

    /// The page's actions, in the order the menu shows them.
    public var actions: [SelectionAction] {
        lock.withLock { current }
    }

    /// Replace the page's actions. An empty list puts the menu back as the
    /// platform builds it.
    ///
    /// Refused rather than tidied: an empty id or title, or an id used twice,
    /// is a page bug that would otherwise surface as a blank menu item or a
    /// choice the page can't tell apart.
    public func setActions(_ actions: [SelectionAction]) async throws {
        var seen = Set<String>()
        for action in actions {
            guard !action.id.isEmpty, !action.title.isEmpty else {
                throw BridgeError(
                    code: BridgeError.decode,
                    message: "a selection action needs a non-empty id and title"
                )
            }
            guard seen.insert(action.id).inserted else {
                throw BridgeError(
                    code: BridgeError.decode,
                    message: "selection action id '\(action.id)' is used twice"
                )
            }
        }
        lock.withLock { current = actions }
        try await actionsChanged?(actions)
    }

    /// A stream of this webview's selection events. Several may be open at
    /// once; each gets every event.
    public func events() -> AsyncStream<SelectionEvent> {
        let key = UUID()
        return AsyncStream { continuation in
            lock.withLock { subscribers[key] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = lock.withLock { self.subscribers.removeValue(forKey: key) }
            }
        }
    }

    /// Open ``events()`` streams — for tests that must not emit before the
    /// stream they're reading has attached.
    var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    /// The user chose the page action `id`.
    public func actionChosen(_ id: String) {
        send(.action(id: id))
    }

    /// A finger the platform took for text selection went down or lifted.
    /// Repeats of the current phase are dropped.
    public func gesture(_ phase: SelectionGesturePhase) {
        let changed: Bool = lock.withLock {
            let active = phase == .began
            guard active != gestureActive else { return false }
            gestureActive = active
            return true
        }
        if changed { send(.gesture(phase)) }
    }

    private func send(_ event: SelectionEvent) {
        let sinks = lock.withLock { Array(subscribers.values) }
        for sink in sinks { sink.yield(event) }
    }
}
