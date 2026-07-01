import Foundation

/// Configuration for launching a child process. Mirrors what `process.spawn` /
/// `process.stream` accept from JS.
public struct ProcessSpawnConfig: Sendable, Codable {
    /// Executable to run. An absolute or relative path (containing a path
    /// separator) is used verbatim; a bare name (e.g. `python3`) is resolved
    /// against `PATH`.
    public var command: String
    /// Arguments passed to the executable (not including `command` itself).
    public var args: [String]
    /// Working directory for the child. Defaults to the parent's cwd.
    public var cwd: String?
    /// Environment variables. By default these are *merged into* the parent's
    /// environment; set ``clearEnv`` to make them the complete environment.
    public var env: [String: String]?
    /// When `true`, ``env`` becomes the child's entire environment instead of
    /// being merged into the inherited one. Defaults to `false`.
    public var clearEnv: Bool?

    public init(
        command: String,
        args: [String] = [],
        cwd: String? = nil,
        env: [String: String]? = nil,
        clearEnv: Bool? = nil
    ) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.clearEnv = clearEnv
    }

    // Custom decoding so JS can omit everything but `command` — a bare
    // `{"command":"ls"}` spawns with no args, inherited env, and the parent cwd.
    private enum CodingKeys: String, CodingKey {
        case command, args, cwd, env, clearEnv
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        env = try c.decodeIfPresent([String: String].self, forKey: .env)
        clearEnv = try c.decodeIfPresent(Bool.self, forKey: .clearEnv)
    }
}

/// One event in a child process's lifetime, yielded by ``ProcessChild/events``.
public enum ProcessEvent: Sendable, Equatable {
    /// A chunk of bytes read from the child's stdout.
    case stdout(Data)
    /// A chunk of bytes read from the child's stderr.
    case stderr(Data)
    /// The child exited with this status code. Terminal — the stream finishes
    /// right after.
    case exit(code: Int32)
}

/// A launched child process. Its ``events`` stream yields stdout/stderr/exit;
/// ``write(_:)`` feeds stdin; ``terminate()`` kills it.
///
/// The `ProcessPlugin` ties the child's lifetime to the JS subscription: when
/// the stream is unsubscribed or the owning window closes, `terminate()` runs —
/// so a child can't outlive the page that spawned it.
public protocol ProcessChild: AnyObject, Sendable {
    /// The OS process id, assigned once the child has launched.
    var pid: Int32 { get }
    /// stdout/stderr/exit, in arrival order, finishing after `exit`.
    var events: AsyncThrowingStream<ProcessEvent, any Error> { get }
    /// Write bytes to the child's stdin. A no-op after stdin is closed or the
    /// child has exited.
    func write(_ data: Data)
    /// Close the child's stdin, signalling EOF to the child.
    func closeStdin()
    /// Request termination (SIGTERM on POSIX). Idempotent; a no-op if the child
    /// has already exited.
    func terminate()
}

/// Launches child processes. The `ProcessPlugin` is constructed with one of
/// these (`ProcessPlugin(SystemProcess())`), so tests can inject a mock and
/// backends that can't spawn (iOS/Android) can supply an unsupported stub.
public protocol ProcessRunner: Sendable {
    /// Launch `config`. Throws if the executable can't be found or the OS
    /// refuses to spawn.
    func spawn(_ config: ProcessSpawnConfig) throws -> any ProcessChild
}

// MARK: - Wire types (JS-facing)

/// One frame delivered to a `process.stream` subscriber. Binary stdout/stderr
/// bytes are base64-encoded so they survive the JSON bridge — a JS
/// `AudioWorklet` (or any consumer) base64-decodes `dataBase64` back to bytes.
public struct ProcessStreamChunk: Sendable, Codable, Equatable {
    /// `"spawned"` | `"stdout"` | `"stderr"` | `"exit"`.
    public let type: String
    /// The child pid, present on the initial `"spawned"` frame.
    public let pid: Int32?
    /// Base64-encoded bytes on `"stdout"` / `"stderr"` frames.
    public let dataBase64: String?
    /// Exit status on the terminal `"exit"` frame.
    public let code: Int32?

    public init(type: String, pid: Int32? = nil, dataBase64: String? = nil, code: Int32? = nil) {
        self.type = type
        self.pid = pid
        self.dataBase64 = dataBase64
        self.code = code
    }

    static func spawned(pid: Int32) -> ProcessStreamChunk {
        ProcessStreamChunk(type: "spawned", pid: pid)
    }

    static func exit(code: Int32) -> ProcessStreamChunk {
        ProcessStreamChunk(type: "exit", code: code)
    }

    static func from(_ event: ProcessEvent) -> ProcessStreamChunk {
        switch event {
        case let .stdout(data):
            ProcessStreamChunk(type: "stdout", dataBase64: data.base64EncodedString())
        case let .stderr(data):
            ProcessStreamChunk(type: "stderr", dataBase64: data.base64EncodedString())
        case let .exit(code):
            .exit(code: code)
        }
    }
}

/// Arguments for `process.write`.
public struct ProcessWriteArgs: Sendable, Codable {
    public var pid: Int32
    /// Base64-encoded bytes to write to the child's stdin.
    public var dataBase64: String?
    /// When `true`, close stdin after writing (or immediately if no bytes).
    public var closeStdin: Bool?
    public init(pid: Int32, dataBase64: String? = nil, closeStdin: Bool? = nil) {
        self.pid = pid
        self.dataBase64 = dataBase64
        self.closeStdin = closeStdin
    }
}

/// Arguments for `process.kill`.
public struct ProcessKillArgs: Sendable, Codable {
    public var pid: Int32
    public init(pid: Int32) { self.pid = pid }
}
