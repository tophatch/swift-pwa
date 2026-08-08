import Foundation

/// A newline-delimited-JSON server on `127.0.0.1`, serving **one client at a
/// time** on a dedicated OS thread.
///
/// Two consumers, which is why it's a type rather than inlined: the app driver
/// (`AppDriver`, debug-only) and the agent surface (`AgentSurface`, which ships
/// in release builds). They differ in what they answer and in how they're
/// gated, but the socket half — bind, poll, accept, frame, respond — is the
/// same, and the agent half has to live outside `#if SWIFT_PWA_DRIVER`.
///
/// Serialising clients is deliberate rather than a simplification: both
/// consumers mutate app state, and interleaved frames from two connections
/// could race on the same window.
///
/// Loopback TCP rather than a Unix socket because ``LoopbackSocket`` is already
/// the cross-platform BSD/Winsock abstraction, and it keeps AF_UNIX-on-Windows
/// out of the picture entirely.
package final class LoopbackServer: @unchecked Sendable {
    /// The port actually bound — resolved, so a request for `0` reports the
    /// port the OS chose.
    package let port: UInt16

    private let listener: SocketHandle
    private let lock = NSLock()
    private var stopping = false
    private var currentClient: SocketHandle?

    /// Bind and start accepting.
    ///
    /// - Parameters:
    ///   - port: `0` asks the OS for a free one.
    ///   - onAttach/onDetach: called as a client connects and disconnects, on
    ///     the accept thread. The agent surface drives its user-visible
    ///     indicator from these, so they fire for *every* connection, including
    ///     one that's rejected for a bad token.
    ///   - handler: one request line in, one response line out (no trailing
    ///     newline — the server adds it).
    package static func start(
        port: UInt16,
        backlog: Int32 = 4,
        onAttach: @escaping @Sendable () -> Void = {},
        onDetach: @escaping @Sendable () -> Void = {},
        handler: @escaping @Sendable (Data) async -> Data
    ) throws -> LoopbackServer {
        LoopbackSocket.startup() // Winsock init; no-op on POSIX

        let listener = LoopbackSocket.makeStreamSocket()
        guard LoopbackSocket.isValid(listener) else {
            throw LoopbackServerError.socket("socket() failed")
        }
        LoopbackSocket.setReuseAddr(listener)

        guard LoopbackSocket.bindLoopback(listener, port: port) else {
            LoopbackSocket.closeSocket(listener)
            throw LoopbackServerError.socket("couldn't bind 127.0.0.1:\(port)")
        }
        guard LoopbackSocket.startListening(listener, backlog: backlog) else {
            LoopbackSocket.closeSocket(listener)
            throw LoopbackServerError.socket("listen() failed")
        }

        let server = LoopbackServer(listener: listener, port: LoopbackSocket.boundPort(listener))

        // A dedicated OS thread, not a cooperative-pool task: the loop blocks
        // in `poll`/`accept`, which would starve a pool thread. It's also why
        // `blocking(_:)` below may park — this thread is neither the UI thread
        // nor a cooperative one.
        Thread.detachNewThread {
            server.acceptLoop(onAttach: onAttach, onDetach: onDetach, handler: handler)
        }
        return server
    }

    private init(listener: SocketHandle, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// Stop accepting and drop any connected client.
    ///
    /// Revocation has to reach a client that's already connected, not just
    /// refuse the next one — a user who turns access off means *now*. Closing
    /// the client's socket makes its next read fail, which ends the serve loop.
    package func stop() {
        lock.lock()
        stopping = true
        let client = currentClient
        currentClient = nil
        lock.unlock()

        if let client { LoopbackSocket.closeSocket(client) }
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop(
        onAttach: @Sendable () -> Void,
        onDetach: @Sendable () -> Void,
        handler: @escaping @Sendable (Data) async -> Data
    ) {
        while !isStopping {
            // Poll rather than block in `accept`, so `stop()` is noticed within
            // the timeout and the thread isn't permanently unkillable if the
            // app tears down around it.
            let ready = LoopbackSocket.pollReadable(listener, timeoutMs: 500)
            if ready < 0 { break }
            if ready == 0 { continue }

            let client = LoopbackSocket.acceptOne(listener)
            guard LoopbackSocket.isValid(client) else { continue }

            lock.lock()
            let refuse = stopping
            if !refuse { currentClient = client }
            lock.unlock()
            if refuse {
                LoopbackSocket.closeSocket(client)
                break
            }

            onAttach()
            serve(client: client, handler: handler)
            onDetach()

            lock.lock()
            let stillOurs = currentClient != nil
            currentClient = nil
            lock.unlock()
            // `stop()` already closed it if it took ownership; closing twice
            // would risk hitting a recycled descriptor.
            if stillOurs { LoopbackSocket.closeSocket(client) }
        }
        LoopbackSocket.closeSocket(listener)
    }

    /// Read newline-delimited requests off one connection until the peer closes
    /// (or `stop()` closes it underneath us). A response can be large — a
    /// full-window PNG arrives base64'd — so the write side loops over short
    /// writes.
    private func serve(client: SocketHandle, handler: @escaping @Sendable (Data) async -> Data) {
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

                let response = Self.blocking { await handler(Data(line)) }
                var out = [UInt8](response)
                out.append(UInt8(ascii: "\n"))
                guard LoopbackSocket.sendAll(client, out, offset: 0, count: out.count) else { return }
                if isStopping { return }
            }
        }
    }

    /// Run an async body from this blocking thread and wait for it.
    ///
    /// Parking a thread on a semaphore is normally a deadlock risk, but this
    /// one is dedicated to the accept loop: it is not the UI thread and not a
    /// cooperative-pool thread, so nothing the `Task` needs is waiting behind
    /// it.
    package static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
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
    /// another local process can't guess its way onto the socket.
    package static func makeToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0 ..< 2)
            .map { _ in String(format: "%016llx", UInt64.random(in: .min ... .max, using: &rng)) }
            .joined()
    }
}

/// Box so ``LoopbackServer/blocking(_:)`` can carry a value out of a `Task`.
/// Unchecked because the semaphore, not the type, orders the two accesses.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

package enum LoopbackServerError: Error, CustomStringConvertible {
    case socket(String)

    package var description: String {
        switch self {
        case let .socket(message): message
        }
    }
}
