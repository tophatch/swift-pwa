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
/// ```
public struct UpdaterPlugin: Plugin {
    public static let pluginName = "updater"

    private let updater: any Updater

    public init(_ updater: any Updater) {
        self.updater = updater
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let updater = updater

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
