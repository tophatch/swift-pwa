import Foundation

/// Why an app's ``AppContext/beforeClose(_:)`` handlers are running.
public enum CloseReason: Sendable, Equatable {
    /// One window is closing and the app is staying up.
    case window(WindowID)
    /// The app is quitting: ⌘Q / Ctrl+Q, `app.quit`, or its last window closed.
    case quit
    /// The system is ending the app: logout, restart, shutdown, or SIGTERM.
    case system
    /// A mobile app is going to the background. There is no quit on iOS or
    /// Android; a suspended app can be killed without being told, so this is
    /// the last moment it is guaranteed to run.
    case backgrounded
}

public extension AppContext {
    /// Run `handler` before a window closes, the app quits, or a mobile app is
    /// backgrounded — the moment to flush anything batched (a debounced write,
    /// a sync queue).
    ///
    /// Handlers run concurrently, after the page has been through its own
    /// teardown (`visibilitychange` → `hidden`, then `pagehide`) and the
    /// invokes that teardown posted have finished. They share a fixed budget —
    /// ``CloseBudget`` — and a handler still running when it ends is logged and
    /// abandoned: the window closes, or the app quits, regardless. The budget
    /// is fixed rather than configurable because the operating system sets the
    /// real ceiling on the paths that matter most, and a knob that held on
    /// three platforms would be a gap on the other two.
    func beforeClose(_ handler: @escaping @Sendable (CloseReason) async -> Void) {
        CloseHandlers.shared.add(handler)
    }
}

/// How long a closing window, or a quitting app, waits for the page and the
/// ``AppContext/beforeClose(_:)`` handlers before going anyway.
public enum CloseBudget {
    /// A window closing while the app stays up. The window is hidden first,
    /// so this is time nobody watches.
    public static let window: Duration = .seconds(1)
    /// The app quitting. Under Windows' session-end budget (about 5s), and
    /// short enough that a hung handler doesn't read as a hung app.
    public static let quit: Duration = .seconds(3)
    /// A mobile app going to the background. iOS grants a background task
    /// more than this but may end it sooner; Android promises nothing after
    /// `onStop`.
    public static let backgrounded: Duration = .seconds(3)
}

/// The steps every backend's quit shares.
public enum Closing {
    /// Before the process exits: let every window's page finish, then run the
    /// ``AppContext/beforeClose(_:)`` handlers, all within one budget.
    @MainActor
    public static func beforeQuit(
        _ app: any AppContext,
        reason: CloseReason,
        budget: Duration = CloseBudget.quit
    ) async {
        let deadline = ContinuousClock.now + budget
        let windows = Array(app.windows.values)
        await withTaskGroup(of: Void.self) { group in
            for window in windows {
                group.addTask { await window.prepareToClose(until: deadline) }
            }
        }
        // Geometry is written on a debounce; a quit inside it would lose the
        // size the user just left.
        WindowStateStore.shared.flushNow()
        await CloseHandlers.shared.run(reason, until: deadline)
    }

    /// The `about:blank` a closing window's document is navigated to, so the
    /// page gets a genuine unload.
    public static let departureURL = URL(string: "about:blank")!
}

/// The process-wide list of ``AppContext/beforeClose(_:)`` handlers. One app
/// runs per process, so one list serves every backend's context.
public final class CloseHandlers: @unchecked Sendable {
    public static let shared = CloseHandlers()

    private let lock = NSLock()
    private var handlers: [@Sendable (CloseReason) async -> Void] = []

    init() {}

    func add(_ handler: @escaping @Sendable (CloseReason) async -> Void) {
        lock.withLock { handlers.append(handler) }
    }

    /// Run every handler concurrently and return when they have all finished
    /// or `deadline` passes, whichever is first.
    ///
    /// A handler that overruns is left running rather than awaited — the
    /// point of the deadline is that a hung handler can't hold the app open —
    /// so this can't be a task group, whose scope waits for every child.
    public func run(_ reason: CloseReason, until deadline: ContinuousClock.Instant) async {
        let handlers = lock.withLock { self.handlers }
        guard !handlers.isEmpty else { return }

        enum Outcome: Sendable { case finished(Int), deadline }
        let (outcomes, continuation) = AsyncStream.makeStream(of: Outcome.self)
        for (index, handler) in handlers.enumerated() {
            Task {
                await handler(reason)
                continuation.yield(.finished(index))
            }
        }
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            continuation.yield(.deadline)
        }
        defer { timer.cancel() }

        var pending = Set(handlers.indices)
        for await outcome in outcomes {
            switch outcome {
            case let .finished(index):
                pending.remove(index)
                if pending.isEmpty { return }
            case .deadline:
                FileHandle.standardError.writeQuietly(Data("""
                swift-pwa: \(pending.count) beforeClose handler(s) of \(handlers.count) still running \
                at the deadline (\(reason)); continuing without them\n
                """.utf8))
                return
            }
        }
    }

    /// Test hook: forget every registered handler.
    func removeAll() {
        lock.withLock { handlers.removeAll() }
    }
}
