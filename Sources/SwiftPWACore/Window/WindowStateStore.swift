import Dispatch
import Foundation

/// One window's remembered geometry. Position is optional so backends that
/// can restore size but not position (GTK4 / Wayland) persist a size-only
/// record, and so a window that's been resized but never moved doesn't
/// pin itself to a bogus `(0, 0)`.
public struct PersistedWindowState: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var x: Double?
    public var y: Double?

    public init(width: Double, height: Double, x: Double? = nil, y: Double? = nil) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}

/// Persists and restores window geometry across launches — the backing store
/// for ``WindowConfig/rememberState``.
///
/// Design notes:
/// - **Foundation-only.** State lives in a single `window-state.json` in the
///   per-app data directory (``PlatformDirectories``); there's no `UserDefaults`,
///   registry, or GSettings dependency, so every desktop backend shares one
///   code path.
/// - **Restore is synchronous** (``restore(_:)``): the file is read + cached in
///   memory on first touch, so a backend can seed a ``WindowConfig`` before it
///   constructs the native window with no `await`.
/// - **Writes are debounced off the main thread.** ``track(_:config:)``
///   subscribes to the window's ``Window/eventStream()`` (which is multicast, so
///   it doesn't disturb `window.subscribe`) and coalesces resize/move flurries
///   into at most one disk write every 0.4s, plus a synchronous flush on close.
///
/// The class is `@unchecked Sendable` (guarded by an `NSLock`, like
/// `CommandRegistry`) rather than an actor: ``restore(_:)`` must be callable
/// synchronously from the `@MainActor` `createWindow` path.
public final class WindowStateStore: @unchecked Sendable {
    /// Process-wide store rooted at the per-app data directory. The directory
    /// is resolved lazily on first use (not at static-init time), so the
    /// app's bundle id / name is available by the time a window is created.
    public static let shared = WindowStateStore()

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.swift-pwa.window-state")
    private let directoryProvider: @Sendable () -> URL
    private let fileName: String

    private var loaded = false
    private var states: [String: PersistedWindowState] = [:]
    /// Accessed only from `ioQueue`, so it needs no separate lock.
    private var pendingFlush: DispatchWorkItem?

    /// Test / embedding hook: a store rooted at an explicit directory.
    public init(directory: URL, fileName: String = "window-state.json") {
        directoryProvider = { directory }
        self.fileName = fileName
    }

    private init() {
        directoryProvider = { PlatformDirectories.dataDirectory(appID: AppPlugin.appID()) }
        fileName = "window-state.json"
    }

    private var fileURL: URL {
        directoryProvider().appendingPathComponent(fileName)
    }

    // MARK: - Restore

    /// Return `config` with a remembered size (and position, when one was
    /// saved) applied for its ``WindowConfig/stateKey``. A no-op when
    /// ``WindowConfig/rememberState`` is off or nothing is stored yet, so it's
    /// safe to call unconditionally from every backend's `createWindow`.
    public func restore(_ config: WindowConfig) -> WindowConfig {
        guard config.rememberState, let saved = state(for: config.stateKey) else { return config }
        var restored = config
        if saved.width > 0, saved.height > 0 {
            restored.size = Size(width: saved.width, height: saved.height)
        }
        if let x = saved.x, let y = saved.y {
            restored.origin = Point(x: x, y: y)
        }
        return restored
    }

    /// The stored geometry for `key`, or `nil` if none has been recorded.
    public func state(for key: String) -> PersistedWindowState? {
        lock.lock(); defer { lock.unlock() }
        ensureLoadedLocked()
        return states[key]
    }

    // MARK: - Track

    /// Begin persisting `window`'s geometry under its ``WindowConfig/stateKey``.
    /// A no-op when ``WindowConfig/rememberState`` is off. Seeds the current
    /// size immediately (so a resize-less session still records a sane size),
    /// then mirrors `.didResize` / `.didMove` into the store until the window
    /// closes. Holds no strong reference to the window — the subscription ends
    /// when the window (and its event stream) is deallocated.
    @MainActor
    public func track(_ window: any Window, config: WindowConfig) {
        guard config.rememberState else { return }
        let key = config.stateKey
        // Seed size from the (already-restored) config so we don't rely on
        // reading the window's geometry before it's mapped — that yields
        // (0, 0) on GTK. Position is captured on the first real `.didMove`.
        recordSize(config.size, for: key)
        let stream = window.eventStream()
        Task { [self] in
            for await event in stream {
                switch event {
                case let .didResize(size): recordSize(size, for: key)
                case let .didMove(point): recordPosition(point, for: key)
                case .didClose: flushNow()
                default: break
                }
            }
        }
    }

    // MARK: - Record

    /// Update the remembered size for `key`, leaving any saved position intact.
    /// Ignores non-positive sizes (some backends report a transient `0×0`
    /// during teardown).
    public func recordSize(_ size: Size, for key: String) {
        guard size.width > 0, size.height > 0 else { return }
        lock.lock()
        ensureLoadedLocked()
        var state = states[key] ?? PersistedWindowState(width: size.width, height: size.height)
        state.width = size.width
        state.height = size.height
        states[key] = state
        lock.unlock()
        scheduleFlush()
    }

    /// Update the remembered position for `key`, leaving the saved size intact.
    /// Skips keys with no size on record yet (``track(_:config:)`` seeds one
    /// first, so in practice there always is).
    public func recordPosition(_ point: Point, for key: String) {
        lock.lock()
        ensureLoadedLocked()
        guard var state = states[key] else {
            lock.unlock()
            return
        }
        state.x = point.x
        state.y = point.y
        states[key] = state
        lock.unlock()
        scheduleFlush()
    }

    // MARK: - Persistence

    private func ensureLoadedLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: PersistedWindowState].self, from: data)
        else { return }
        states = decoded
    }

    /// Coalesce rapid changes into one write ~0.4s after the last change.
    private func scheduleFlush() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            pendingFlush?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.writeNow() }
            pendingFlush = work
            ioQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// Write the current snapshot immediately, cancelling any pending debounce.
    /// Synchronous so a window closing right after a resize doesn't lose it.
    public func flushNow() {
        ioQueue.sync {
            pendingFlush?.cancel()
            pendingFlush = nil
            writeNow()
        }
    }

    /// Serialize + atomically write the snapshot. Runs on `ioQueue`.
    private func writeNow() {
        lock.lock()
        ensureLoadedLocked()
        let snapshot = states
        lock.unlock()
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
