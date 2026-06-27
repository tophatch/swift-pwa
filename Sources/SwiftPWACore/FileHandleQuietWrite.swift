import Foundation

public extension FileHandle {
    /// Best-effort write that never traps on failure — for diagnostics
    /// (warnings, error logs) that must not be able to crash the app.
    ///
    /// The legacy `write(_ data: Data)` raises/`fatalError`s when the
    /// underlying write fails (this is how swift-corelibs-foundation
    /// implements it). On a **GUI-subsystem Windows app** the standard
    /// handles are invalid — there's no console attached — so a stray
    /// `FileHandle.standardError.write(…)` (e.g. from llama.cpp's error-log
    /// callback) turns into an illegal-instruction trap in `swiftCore.dll`.
    /// The same hazard exists anywhere stdout/stderr is closed or
    /// redirected to a dead handle. The throwing `write(contentsOf:)` lets
    /// us swallow that failure: a log line that can't be written is dropped,
    /// not fatal.
    func writeQuietly(_ data: Data) {
        try? write(contentsOf: data)
    }
}
