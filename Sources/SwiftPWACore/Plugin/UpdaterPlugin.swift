import Foundation

/// Optional plugin exposing `updater.*` to JS. Not auto-installed
/// because most apps want to control update timing (and because some
/// apps update through stores rather than swift-pwa's built-in
/// channel). Users opt in:
///
/// ```swift
/// runtime.run { ctx in
///     ctx.use(UpdaterPlugin(MacUpdater(
///         endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
///         publicKey: "RWQf6...",
///         currentVersion: "0.3.0"
///     )))
/// }
/// ```
///
/// JS surface:
///
/// ```js
/// // One-shot probe — useful for "Check for updates…" menu items.
/// const info = await __SWIFT_PWA__.invoke("updater.check");
/// if (info) console.log(`Update available: ${info.version}`);
///
/// // Streaming run — the typical "show progress UI" flow. Composes
/// // check + download under one subscription so the UI doesn't have
/// // to coordinate two calls.
/// const unsub = __SWIFT_PWA__.subscribe("updater.run", null, (event) => {
///     switch (event.type) {
///         case "checking": /* show spinner */ break;
///         case "available": /* show "Update to vX" */ break;
///         case "upToDate": /* hide spinner */ break;
///         case "downloadProgress":
///             progress(event.bytesDownloaded, event.contentLength); break;
///         case "readyToInstall":
///             // typically prompt the user, then:
///             __SWIFT_PWA__.invoke("updater.installAndRelaunch");
///             break;
///         case "error": /* surface event.code + event.message */ break;
///     }
/// });
///
/// // Streaming install variant — gives Android apps a hook into the
/// // `PackageInstaller.STATUS_*` broadcasts. On other backends the
/// // stream finishes silently (the process is replaced before any
/// // event could be observed).
/// const unsubInstall = __SWIFT_PWA__.subscribe("updater.install", null, (event) => {
///     switch (event.type) {
///         case "installCommitted": /* system prompt visible */ break;
///         case "installSucceeded": /* never observed in practice */ break;
///         case "installFailed":    /* event.code + event.message */ break;
///         case "error":            /* commit itself failed */ break;
///     }
/// });
///
/// // Auto-check (opt in with UpdaterPlugin(updater, autoCheck: true)).
/// // The runtime polls on a timer and pushes any available update here;
/// // the payload is retained so a late subscriber still gets the latest.
/// __SWIFT_PWA__.on("updater.updateAvailable", (info) => {
///     if (info.mandatory) forceUpdateGate(info);
///     else showUpdateBanner(info);   // then invoke updater.run to apply
/// });
/// ```
public struct UpdaterPlugin: Plugin {
    public static let pluginName = "updater"

    /// Event-bus channel the auto-check poller emits an available
    /// `UpdateInfo` on. JS subscribes with
    /// `__SWIFT_PWA__.on("updater.updateAvailable", info => …)`; the
    /// payload is retained, so a late subscriber still receives the
    /// most recent available update.
    public static let updateAvailableChannel = "updater.updateAvailable"

    private let updater: any Updater
    private let autoCheck: Bool
    private let checkInterval: TimeInterval

    /// - Parameters:
    ///   - updater: the platform `Updater` backend.
    ///   - autoCheck: when `true`, poll `updater.check()` on a timer and
    ///     emit any available update on `updateAvailableChannel` (mirrors
    ///     `pwa.json`'s `updater.auto_check` — pass that value through).
    ///     Default `false` (on-demand only, unchanged behaviour).
    ///   - checkInterval: seconds between polls when `autoCheck` is on
    ///     (mirrors `updater.check_interval_seconds`). Default 6 hours.
    ///     Clamped to a 60-second floor so a misconfigured `0` doesn't
    ///     hammer the endpoint.
    public init(
        _ updater: any Updater,
        autoCheck: Bool = false,
        checkInterval: TimeInterval = 21600
    ) {
        self.updater = updater
        self.autoCheck = autoCheck
        self.checkInterval = max(60, checkInterval)
    }

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let updater = updater

        if autoCheck {
            let events = app.events
            let interval = checkInterval
            // App-lifetime poller on the cooperative pool. The first
            // check fires promptly (retained emit closes the "JS
            // subscribed late" gap); subsequent checks every `interval`.
            // Transient check failures (offline, endpoint blip) are
            // swallowed — the next tick retries.
            Task.detached {
                while !Task.isCancelled {
                    await Self.checkAndEmit(updater, to: events)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
        }

        registry.register(
            "updater.check",
            typed: { (_: EmptyArgs, _) async throws -> UpdateInfo? in
                try await updater.check()
            }
        )

        registry.registerStream(
            "updater.run",
            typed: { (args: UpdaterRunArgs, _) -> AsyncThrowingStream<UpdaterEvent, any Error> in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            // 1. resolve the UpdateInfo (use what the
                            //    caller passed if present; otherwise
                            //    do our own check).
                            let info: UpdateInfo?
                            if let caller = args.info {
                                info = caller
                            } else {
                                continuation.yield(.checking)
                                info = try await updater.check()
                            }

                            guard let info else {
                                continuation.yield(.upToDate)
                                continuation.finish()
                                return
                            }
                            continuation.yield(.available(info))

                            // 2. forward download events.
                            for try await event in updater.download(info) {
                                if Task.isCancelled { break }
                                continuation.yield(event)
                            }
                            continuation.finish()
                        } catch let bridge as BridgeError {
                            continuation.yield(.error(code: bridge.code, message: bridge.message))
                            continuation.finish(throwing: bridge)
                        } catch {
                            continuation.yield(.error(code: BridgeError.handler, message: "\(error)"))
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )

        registry.register(
            "updater.installAndRelaunch",
            typed: { (_: EmptyArgs, _) async throws -> EmptyResult in
                try await updater.installAndRelaunch()
                return EmptyResult()
            }
        )

        registry.registerStream(
            "updater.install",
            typed: { (_: EmptyArgs, _) -> AsyncThrowingStream<UpdaterEvent, any Error> in
                updater.install()
            }
        )
    }

    /// One auto-check iteration: probe `updater.check()` and, if an
    /// update is available, emit it (retained) on
    /// `updateAvailableChannel`. Transient errors are swallowed so the
    /// polling loop keeps ticking. `package`-visible so tests can drive
    /// a single iteration without spinning up the timer loop.
    package static func checkAndEmit(_ updater: any Updater, to events: EventBus) async {
        do {
            if let info = try await updater.check() {
                try? events.emit(updateAvailableChannel, info, retain: true)
            }
        } catch {
            // Offline / endpoint blip — the next tick retries.
        }
    }
}

/// Args for the streaming `updater.run` command. The optional `info`
/// lets a caller chain `updater.check` → user prompt → `updater.run`
/// without re-fetching the manifest; pass `null` to have `run` do its
/// own check first.
public struct UpdaterRunArgs: Sendable, Codable, Equatable {
    public var info: UpdateInfo?
    public init(info: UpdateInfo? = nil) { self.info = info }
}
