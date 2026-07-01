import Foundation

/// Plugin exposing the `process.*` command set: launch and manage an external
/// child process, streaming its stdout/stderr as bridge events and feeding its
/// stdin from JS.
///
/// This is the escape hatch that lets a swift-pwa app host a "thick" local
/// backend — a converter, an indexer, a local model server, or (until a native
/// audio `AIBackend` exists) an out-of-process TTS synthesizer — instead of
/// being a purely thin PWA wrapper.
///
/// **Opt-in, and desktop-only.** Register it explicitly with a runner:
/// `ctx.use(ProcessPlugin(SystemProcess()))`. Not auto-installed (unlike
/// `window.*` / `app.*` / `events.*`). On iOS/Android the sandbox forbids
/// spawning; `SystemProcess.spawn` throws there.
///
/// **Guaranteed teardown.** A child's lifetime is tied to its `process.stream`
/// subscription: when JS unsubscribes *or the owning window closes*, the
/// bridge cancels the subscription, which terminates the child. Orphaned
/// children — the classic failure mode — can't happen.
///
/// ## Commands
/// - `process.stream(ProcessSpawnConfig)` → stream of ``ProcessStreamChunk``.
///   Launches the child and yields `spawned` (with the pid), then `stdout` /
///   `stderr` chunks (base64), then a terminal `exit`.
/// - `process.write(ProcessWriteArgs)` → write base64 bytes to a child's stdin
///   (by pid), optionally closing stdin afterwards.
/// - `process.kill(ProcessKillArgs)` → terminate a child by pid.
public struct ProcessPlugin: Plugin {
    public static let pluginName = "process"

    private let runner: any ProcessRunner

    public init(_ runner: any ProcessRunner) {
        self.runner = runner
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let runner = runner
        let live = LiveProcesses()

        registry.registerStream(
            "process.stream",
            typed: { (config: ProcessSpawnConfig, _) -> AsyncThrowingStream<ProcessStreamChunk, any Error> in
                AsyncThrowingStream { continuation in
                    let child: any ProcessChild
                    do {
                        child = try runner.spawn(config)
                    } catch let bridge as BridgeError {
                        continuation.finish(throwing: bridge)
                        return
                    } catch {
                        continuation.finish(throwing: BridgeError(
                            code: BridgeError.handler,
                            message: "\(error)"
                        ))
                        return
                    }

                    live.add(child)
                    continuation.yield(.spawned(pid: child.pid))

                    let pump = Task {
                        do {
                            for try await event in child.events {
                                continuation.yield(.from(event))
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                        live.remove(child.pid)
                    }

                    // Fires on unsubscribe, window close, or normal completion.
                    // On the first two the child is still alive, so terminate it;
                    // after a normal exit `terminate()` is a guarded no-op.
                    continuation.onTermination = { _ in
                        pump.cancel()
                        child.terminate()
                        live.remove(child.pid)
                    }
                }
            }
        )

        registry.register("process.write", typed: { (args: ProcessWriteArgs, _) async throws -> EmptyResult in
            guard let child = live.get(args.pid) else {
                throw BridgeError(code: BridgeError.notFound, message: "no live process with pid \(args.pid)")
            }
            if let base64 = args.dataBase64, let data = Data(base64Encoded: base64) {
                child.write(data)
            }
            if args.closeStdin == true {
                child.closeStdin()
            }
            return EmptyResult()
        })

        registry.register("process.kill", typed: { (args: ProcessKillArgs, _) async throws -> EmptyResult in
            guard let child = live.get(args.pid) else {
                throw BridgeError(code: BridgeError.notFound, message: "no live process with pid \(args.pid)")
            }
            child.terminate()
            return EmptyResult()
        })
    }
}

/// Lock-guarded table of live children, keyed by pid, so `process.write` /
/// `process.kill` can reach a child spawned by a separate `process.stream`
/// subscription. Entries are removed on child exit or stream teardown.
private final class LiveProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var byPID: [Int32: any ProcessChild] = [:]

    func add(_ child: any ProcessChild) {
        lock.withLock { byPID[child.pid] = child }
    }

    func get(_ pid: Int32) -> (any ProcessChild)? {
        lock.withLock { byPID[pid] }
    }

    func remove(_ pid: Int32) {
        lock.withLock { _ = byPID.removeValue(forKey: pid) }
    }
}
