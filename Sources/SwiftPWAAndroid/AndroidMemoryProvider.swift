#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `MemoryProvider` that sources device-memory facts from Kotlin's
    /// `ActivityManager`, since none of the numbers are reachable from a
    /// portable Swift syscall the way the desktop `DefaultMemoryProvider`'s are.
    ///
    /// Routes `system.memory` into the Kotlin scaffold's `SwiftPWASystemPlugins`
    /// (`system.memory` RPC → `ActivityManager.getMemoryInfo` +
    /// `getLargeMemoryClass`), exactly like `AndroidContentResolver` /
    /// `AndroidArchiveExtractor` route their calls. The `AndroidAppContext`
    /// wires it up automatically on process init.
    ///
    /// **What "app limit" means on Android.** `appLimitBytes` is
    /// `getLargeMemoryClass() × 1 MiB` — the Java-heap tier for the device. A
    /// WebView canvas app's real pressure is usually *native/GPU* memory rather
    /// than the Java heap, so treat this as a device-tier proxy for sizing, and
    /// rely on the `system.memoryPressure` event (fed by `onTrimMemory`) for the
    /// signal that actually matters.
    public final class AndroidMemoryProvider: MemoryProvider, @unchecked Sendable {
        // The large-heap class is constant for the process, so the value backing
        // `PlatformInfo.appMemoryLimitBytes` is cached after the first read to
        // keep `__platform.info` from doing a JNI round-trip on every call.
        private let lock = NSLock()
        private var cachedAppLimit: UInt64?

        public init() {}

        public func snapshot() async -> MemorySnapshot {
            do {
                let r = try await AndroidRPC.call(
                    "system.memory",
                    EmptyArgs(),
                    as: AndroidMemoryResult.self
                )
                if let limit = r.appLimitBytes {
                    lock.withLock { cachedAppLimit = limit }
                }
                return MemorySnapshot(
                    physicalBytes: r.physicalBytes,
                    availableBytes: r.availableBytes,
                    appLimitBytes: r.appLimitBytes,
                    lowMemory: r.lowMemory
                )
            } catch {
                // Never let a memory read fail a caller: fall back to the one
                // number Swift can read locally (total RAM), like desktop.
                return MemorySnapshot(physicalBytes: ProcessInfo.processInfo.physicalMemory)
            }
        }

        /// The static per-app ceiling for `PlatformInfo.appMemoryLimitBytes`.
        /// Returns the cached large-heap value if a `snapshot()` has already
        /// populated it, else fetches once. `nil` on any RPC failure — a
        /// foundational `__platform.info` call must not break on a memory read.
        public func appMemoryLimit() async -> UInt64? {
            if let cached = lock.withLock({ cachedAppLimit }) { return cached }
            _ = await snapshot()
            return lock.withLock { cachedAppLimit }
        }
    }

    /// Decoded shape of the Kotlin `system.memory` RPC result.
    private struct AndroidMemoryResult: Decodable {
        let physicalBytes: UInt64
        let availableBytes: UInt64?
        let appLimitBytes: UInt64?
        let lowMemory: Bool
    }
#endif
