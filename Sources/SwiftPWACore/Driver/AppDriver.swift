import Foundation

/// The app driver's runtime half: an **opt-in loopback control socket** that
/// lets a script or an agent drive and screenshot a running app without taking
/// over the machine.
///
/// The gap it closes: Android has had programmatic control since
/// `setWebContentsDebuggingEnabled(true)` put the page on a CDP socket, but on
/// macOS, Linux and Windows `Cmd+Opt+J` / `Ctrl+Alt+J` opens DevTools *for a
/// human* and that is the whole story. The alternative people reach for —
/// screen capture plus OS-wide synthetic clicks — commandeers the machine,
/// photographs whatever window drifted on top, and needs TCC grants that no CI
/// runner can click through.
///
/// ## Three gates
///
/// A loopback port that evaluates arbitrary JS inside a running app is
/// reachable by every local user account, so one gate isn't enough:
///
/// 1. **Compile** — everything below is `#if SWIFT_PWA_DRIVER`, which is
///    defined for **debug builds only** unless `SWIFT_PWA_DRIVER=1` was set at
///    build time. A shipped release build does not contain the driver at all.
/// 2. **Environment** — a driver-capable build still doesn't listen until
///    ``environmentVariable`` (`SWIFT_PWA_DRIVE`) names a port. `0` asks the OS
///    for a free one.
/// 3. **Token** — a fresh random token per launch, printed on stdout for the
///    supervising process to read, required on every frame. An env-only gate is
///    one `launchctl setenv` away from being a hole.
///
/// Backends call ``startIfRequested(_:backend:)`` once, after `configure` has
/// run and the first window exists. When the driver is compiled out, or the env
/// var is unset, the call compiles to (or returns as) nothing.
public enum AppDriver {
    /// The env var a backend checks: set it to a TCP port to have the app
    /// listen on `127.0.0.1:<port>`, or to `0` for an OS-assigned port. Matches
    /// the `SWIFT_PWA_DESCRIBE` / `SWIFT_PWA_GTK4` env-flag convention. Unset
    /// (the normal case) ⇒ ``startIfRequested(_:backend:)`` is a no-op.
    public static let environmentVariable = "SWIFT_PWA_DRIVE"

    /// Whether this binary was compiled with the driver in it at all — the
    /// first of the three gates. `swift-pwa drive` reports this when an app
    /// launches but never announces a port.
    public static var isCompiledIn: Bool {
        #if SWIFT_PWA_DRIVER
            true
        #else
            false
        #endif
    }

    /// The port requested via ``environmentVariable``, or `nil` when the app
    /// was launched normally. `0` means "any free port".
    public static var requestedPort: UInt16? {
        guard let raw = ProcessInfo.processInfo.environment[environmentVariable],
              let port = UInt16(raw.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return port
    }

    /// Start the control socket if ``environmentVariable`` asked for it.
    ///
    /// - Parameters:
    ///   - context: the live app context; the driver reads windows off it.
    ///   - backend: this backend's own name (`macos`, `ios`, `gtk3`, `gtk4`,
    ///     `windows`), reported by the `capabilities` verb. Core can't work it
    ///     out for itself — `#if os(Linux)` doesn't say which GTK is linked.
    @MainActor
    public static func startIfRequested(_ context: any AppContext, backend: String) {
        #if SWIFT_PWA_DRIVER
            guard let port = requestedPort else { return }
            do {
                let started = try DriverServer.start(context: context, backend: backend, port: port)
                // One machine-greppable line on stdout: the supervising process
                // reads it to learn where to connect and with what token.
                // `writeQuietly` because a console-less Windows GUI build has
                // no stdout to write to and must not die trying.
                FileHandle.standardOutput.writeQuietly(Data(
                    "swift-pwa driver listening port=\(started.port) token=\(started.token)\n".utf8
                ))
            } catch {
                FileHandle.standardError.writeQuietly(Data(
                    "swift-pwa: driver failed to start: \(error)\n".utf8
                ))
            }
        #endif
    }
}

#if SWIFT_PWA_DRIVER

    /// The accept loop behind ``AppDriver``. Newline-delimited JSON over
    /// loopback TCP, **one client at a time** — a driver is a single supervising
    /// process, and serialising also means two clients can't interleave frames
    /// that move the same window.
    ///
    /// Loopback TCP rather than a Unix socket because ``LoopbackSocket`` is
    /// already the cross-platform BSD/Winsock abstraction (written for
    /// `swift-pwa dev`, which runs the same socket in the opposite direction),
    /// and it keeps AF_UNIX-on-Windows out of the picture entirely.
    enum DriverServer {
        struct Started {
            let port: UInt16
            let token: String
        }

        static func start(context: any AppContext, backend: String, port: UInt16) throws -> Started {
            LoopbackSocket.startup() // Winsock init; no-op on POSIX

            let listener = LoopbackSocket.makeStreamSocket()
            guard LoopbackSocket.isValid(listener) else {
                throw DriverServerError.socket("socket() failed")
            }
            LoopbackSocket.setReuseAddr(listener)

            guard LoopbackSocket.bindLoopback(listener, port: port) else {
                LoopbackSocket.closeSocket(listener)
                throw DriverServerError.socket("couldn't bind 127.0.0.1:\(port)")
            }
            guard LoopbackSocket.startListening(listener, backlog: 4) else {
                LoopbackSocket.closeSocket(listener)
                throw DriverServerError.socket("listen() failed")
            }

            let token = makeToken()
            let session = DriverSession(context: context, token: token, backend: backend)
            let bound = LoopbackSocket.boundPort(listener)

            // A dedicated OS thread, not a cooperative-pool task: the loop
            // blocks in `poll`/`accept`, which would starve a pool thread. It's
            // also the reason `blocking(_:)` below is allowed to park — this
            // thread is neither the UI thread nor a cooperative one.
            Thread.detachNewThread {
                acceptLoop(listener: listener, session: session)
            }

            return Started(port: bound, token: token)
        }

        private static func acceptLoop(listener: SocketHandle, session: DriverSession) {
            while true {
                // Poll rather than block in `accept` so the thread isn't
                // permanently unkillable if the app tears down around it.
                let ready = LoopbackSocket.pollReadable(listener, timeoutMs: 500)
                if ready < 0 { break }
                if ready == 0 { continue }

                let client = LoopbackSocket.acceptOne(listener)
                guard LoopbackSocket.isValid(client) else { continue }
                serve(client: client, session: session)
                LoopbackSocket.closeSocket(client)
            }
            LoopbackSocket.closeSocket(listener)
        }

        /// Read newline-delimited requests off one connection until the peer
        /// closes. A response can be large — a full-window PNG arrives
        /// base64'd — so the write side loops over short writes.
        private static func serve(client: SocketHandle, session: DriverSession) {
            var pending = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)

            while true {
                let n = LoopbackSocket.recvInto(client, &buffer)
                guard n > 0 else { return } // 0 = peer closed, < 0 = error
                pending.append(contentsOf: buffer[0 ..< n])

                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Array(pending[pending.startIndex ..< newline])
                    pending.removeSubrange(pending.startIndex ... newline)
                    guard !line.isEmpty else { continue }

                    let response = blocking { await session.handle(line: Data(line)) }
                    var out = [UInt8](response)
                    out.append(UInt8(ascii: "\n"))
                    guard LoopbackSocket.sendAll(client, out, offset: 0, count: out.count) else { return }
                }
            }
        }

        /// Run an async body from this blocking thread and wait for it.
        ///
        /// Parking a thread on a semaphore is normally a deadlock risk, but this
        /// one is dedicated to the accept loop: it is not the UI thread and not
        /// a cooperative-pool thread, so nothing the `Task` needs is waiting
        /// behind it.
        private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
            let box = ResultBox<T>()
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                box.value = await body()
                semaphore.signal()
            }
            semaphore.wait()
            return box.value!
        }

        /// 128 bits of `SystemRandomNumberGenerator`, hex-encoded. Enough that
        /// another local process can't guess its way onto the socket in the
        /// lifetime of a debug session.
        private static func makeToken() -> String {
            var rng = SystemRandomNumberGenerator()
            return (0 ..< 2)
                .map { _ in String(format: "%016llx", UInt64.random(in: .min ... .max, using: &rng)) }
                .joined()
        }
    }

    /// Box so ``DriverServer/blocking(_:)`` can carry a value out of a `Task`.
    /// Unchecked because the semaphore, not the type, orders the two accesses.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    enum DriverServerError: Error, CustomStringConvertible {
        case socket(String)

        var description: String {
            switch self {
            case let .socket(message): message
            }
        }
    }

#endif
