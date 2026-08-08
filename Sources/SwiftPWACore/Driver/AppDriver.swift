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

    /// The driver's binding of ``LoopbackServer``: mint a token, wrap a
    /// ``DriverSession``, listen. The socket mechanics live in
    /// `LoopbackServer`, shared with the agent surface.
    ///
    /// The driver never calls `stop()` — it lives for the process, since the
    /// env var that switched it on can't be un-set from outside.
    enum DriverServer {
        struct Started {
            let port: UInt16
            let token: String
        }

        static func start(context: any AppContext, backend: String, port: UInt16) throws -> Started {
            let token = LoopbackServer.makeToken()
            let session = DriverSession(context: context, token: token, backend: backend)
            let server = try LoopbackServer.start(port: port) { line in
                await session.handle(line: line)
            }
            return Started(port: server.port, token: token)
        }
    }

#endif
