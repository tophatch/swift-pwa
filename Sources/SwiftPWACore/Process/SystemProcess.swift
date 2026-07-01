import Foundation

#if os(macOS) || os(Linux) || os(Windows)

    /// Desktop `ProcessRunner` backed by Foundation's `Process`.
    ///
    /// Available on macOS, Linux, and Windows — the desktop hosts where
    /// spawning a child process is meaningful. iOS and Android sandboxes forbid
    /// it; there `SystemProcess.spawn` throws `E_UNIMPLEMENTED` (see the stub in
    /// the `#else` branch).
    public final class SystemProcess: ProcessRunner {
        public init() {}

        public func spawn(_ config: ProcessSpawnConfig) throws -> any ProcessChild {
            let process = Process()

            // Resolve the executable. A path (has a separator) is used as-is; a
            // bare name is resolved against PATH — via `/usr/bin/env` on POSIX,
            // and a manual PATH search on Windows.
            let hasSeparator = config.command.contains("/") || config.command.contains("\\")
            if hasSeparator {
                process.executableURL = URL(fileURLWithPath: config.command)
                process.arguments = config.args
            } else {
                #if os(Windows)
                    process.executableURL = Self.searchPath(config.command)
                        ?? URL(fileURLWithPath: config.command)
                    process.arguments = config.args
                #else
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [config.command] + config.args
                #endif
            }

            if let cwd = config.cwd {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }

            var environment = (config.clearEnv == true) ? [:] : ProcessInfo.processInfo.environment
            if let env = config.env {
                for (key, value) in env { environment[key] = value }
            }
            process.environment = environment

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let child = SystemProcessChild(
                process: process,
                stdin: stdinPipe,
                stdout: stdoutPipe,
                stderr: stderrPipe
            )

            do {
                try process.run()
            } catch {
                child.failLaunch(error)
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "failed to launch \"\(config.command)\": \(error)"
                )
            }
            return child
        }

        #if os(Windows)
            /// Minimal PATH search for a bare command on Windows (POSIX defers
            /// to `/usr/bin/env`). Tries the name as-is and with each
            /// `PATHEXT` suffix in every `PATH` entry.
            static func searchPath(_ command: String) -> URL? {
                let fm = FileManager.default
                let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                    .split(separator: ";").map(String.init)
                let exts = [""] + (ProcessInfo.processInfo.environment["PATHEXT"] ?? ".EXE")
                    .split(separator: ";").map(String.init)
                for dir in pathEntries {
                    for ext in exts {
                        let candidate = URL(fileURLWithPath: dir).appendingPathComponent(command + ext)
                        if fm.isExecutableFile(atPath: candidate.path) { return candidate }
                    }
                }
                return nil
            }
        #endif
    }

    /// A running `Process` adapted to ``ProcessChild``.
    ///
    /// **Output ordering / completeness.** The stream must not `finish` until
    /// *all* buffered stdout/stderr has been delivered — otherwise a fast child
    /// that writes then exits would lose its final chunks. We therefore don't
    /// finish on `terminationHandler` alone; we wait for stdout EOF, stderr EOF,
    /// *and* termination (tracked under a lock) before yielding the terminal
    /// `.exit` and finishing.
    private final class SystemProcessChild: ProcessChild, @unchecked Sendable {
        let events: AsyncThrowingStream<ProcessEvent, any Error>
        private let continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation
        private let process: Process
        private let stdin: Pipe

        private let lock = NSLock()
        private var stdinClosed = false
        private var stdoutEOF = false
        private var stderrEOF = false
        private var terminated = false
        private var finished = false
        private var exitCode: Int32 = 0

        var pid: Int32 {
            process.processIdentifier
        }

        init(process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
            self.process = process
            self.stdin = stdin
            var cont: AsyncThrowingStream<ProcessEvent, any Error>.Continuation!
            events = AsyncThrowingStream { cont = $0 }
            continuation = cont

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.markEOF(\.stdoutEOF)
                } else {
                    self?.continuation.yield(.stdout(data))
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.markEOF(\.stderrEOF)
                } else {
                    self?.continuation.yield(.stderr(data))
                }
            }
            process.terminationHandler = { [weak self] proc in
                self?.markTerminated(code: proc.terminationStatus)
            }
        }

        private func markEOF(_ keyPath: ReferenceWritableKeyPath<SystemProcessChild, Bool>) {
            lock.withLock { self[keyPath: keyPath] = true }
            finishIfDone()
        }

        private func markTerminated(code: Int32) {
            lock.withLock {
                terminated = true
                exitCode = code
            }
            finishIfDone()
        }

        private func finishIfDone() {
            let (shouldFinish, code) = lock.withLock { () -> (Bool, Int32) in
                guard stdoutEOF, stderrEOF, terminated, !finished else { return (false, 0) }
                finished = true
                return (true, exitCode)
            }
            guard shouldFinish else { return }
            continuation.yield(.exit(code: code))
            continuation.finish()
        }

        /// Called when `process.run()` itself throws (executable missing, etc.):
        /// surface it on the stream so the plugin can forward the error.
        func failLaunch(_ error: any Error) {
            let alreadyFinished = lock.withLock { () -> Bool in
                if finished { return true }
                finished = true
                return false
            }
            guard !alreadyFinished else { return }
            continuation.finish(throwing: error)
        }

        func write(_ data: Data) {
            lock.lock()
            let closed = stdinClosed
            lock.unlock()
            guard !closed, !data.isEmpty else { return }
            // `write(contentsOf:)` can throw `EPIPE` if the child closed its
            // stdin or exited; swallow it — the exit event is the signal.
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }

        func closeStdin() {
            lock.lock()
            let already = stdinClosed
            stdinClosed = true
            lock.unlock()
            guard !already else { return }
            try? stdin.fileHandleForWriting.close()
        }

        func terminate() {
            // Guarded: `terminate()` on an already-exited Process traps on some
            // platforms.
            if process.isRunning { process.terminate() }
        }
    }

#else

    /// iOS / Android stub: process spawning is unavailable in these sandboxes.
    /// `ProcessPlugin(SystemProcess())` compiles everywhere, but `spawn` fails
    /// fast with a stable error so callers get a clear message rather than a
    /// link error.
    public final class SystemProcess: ProcessRunner {
        public init() {}

        public func spawn(_ config: ProcessSpawnConfig) throws -> any ProcessChild {
            _ = config
            throw BridgeError(
                code: BridgeError.unimplemented,
                message: "subprocesses are not available on this platform"
            )
        }
    }

#endif
