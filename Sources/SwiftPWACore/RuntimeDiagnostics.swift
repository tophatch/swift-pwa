import Foundation

/// Where the runtime's own diagnostics go.
///
/// Core writes to `FileHandle.standardError`, which is right on every desktop
/// backend and **invisible on Android**, where an app process's stdout and
/// stderr go to `/dev/null` and `adb logcat` is the only channel anyone reads.
/// A diagnostic whose entire job is to explain a silent refusal cannot itself
/// be silent, so backends whose platform needs a different sink install one.
///
/// Deliberately a single function hook rather than a logging subsystem — the
/// same shape as ``MainThread``'s dispatch hook, and for the same reason: one
/// platform-specific behaviour, injected once at startup.
///
/// > Note: the other Core sites that write to stderr directly (`HeadlessDescribe`,
/// > `InitialRoute`, the driver) have the same blindness on Android. They're
/// > left alone for now because each runs in a context where Android either
/// > can't reach them or isn't the platform in question.
public enum RuntimeDiagnostics {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var sink: (@Sendable (String) -> Void)?

    /// Install the platform's diagnostic sink. Called by a backend during
    /// startup, before the app's `configure` runs.
    public static func installSink(_ sink: @escaping @Sendable (String) -> Void) {
        lock.withLock { Self.sink = sink }
    }

    /// Emit one line. Falls back to stderr when no sink is installed, which is
    /// correct everywhere except Android.
    public static func emit(_ message: String) {
        let sink = lock.withLock { Self.sink }
        if let sink {
            sink(message)
        } else {
            FileHandle.standardError.writeQuietly(Data((message + "\n").utf8))
        }
    }
}
