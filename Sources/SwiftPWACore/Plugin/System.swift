import Dispatch
import Foundation
#if canImport(Darwin)
    import Darwin
#elseif os(Windows)
    import WinSDK
#elseif canImport(Glibc)
    import Glibc
#endif

/// A point-in-time reading of device / process memory, returned by
/// `system.memory`. Everything is in **bytes** (`UInt64`) — exact and
/// uncapped, unlike the web platform's `navigator.deviceMemory`, which is
/// quantized to powers of two, capped at 8 GB, and absent in WKWebView.
///
/// - `physicalBytes` is the total device RAM (effectively constant for the
///   session; also exposed statically on `__platform.info`).
/// - `availableBytes` is how much RAM can be allocated *right now*, or `nil`
///   on a backend with no portable "available" signal. On iOS this is the
///   remaining per-app headroom before jetsam (`os_proc_available_memory()`),
///   which is the number a memory-scaled cache actually wants.
/// - `appLimitBytes` is the per-app ceiling where the OS defines one
///   (Android's large-heap class); `nil` on desktop and iOS. See the
///   device-memory proposal's open question 5 for why iOS reports its
///   headroom as `availableBytes` and leaves this `nil`.
/// - `lowMemory` is the OS's own "under pressure" flag where it exposes one
///   (Android `MemoryInfo.lowMemory`), otherwise a heuristic (`availableBytes`
///   below ~1/8 of `physicalBytes`).
public struct MemorySnapshot: Sendable, Codable, Equatable {
    public var physicalBytes: UInt64
    public var availableBytes: UInt64?
    public var appLimitBytes: UInt64?
    public var lowMemory: Bool

    public init(
        physicalBytes: UInt64,
        availableBytes: UInt64? = nil,
        appLimitBytes: UInt64? = nil,
        lowMemory: Bool = false
    ) {
        self.physicalBytes = physicalBytes
        self.availableBytes = availableBytes
        self.appLimitBytes = appLimitBytes
        self.lowMemory = lowMemory
    }
}

/// Source of device-memory facts for the `system.*` command set. Injected into
/// `SystemPlugin` / `PlatformInfoPlugin` so backends whose numbers don't come
/// from a portable syscall (Android, via JNI) can supply their own, exactly
/// like `ProcessRunner` / `FsContentResolver`. The default,
/// ``DefaultMemoryProvider``, covers macOS / iOS / Linux / Windows with
/// standard platform APIs.
public protocol MemoryProvider: Sendable {
    /// A live, point-in-time read. `async` because the Android implementation
    /// crosses the JNI RPC boundary; the desktop implementation returns
    /// synchronously.
    func snapshot() async -> MemorySnapshot
}

/// Cross-platform ``MemoryProvider`` built on standard system APIs. Covers
/// macOS / iOS / Linux / Windows directly; the Android backend injects its own
/// JNI-backed provider instead. `physicalBytes` is always
/// `ProcessInfo.physicalMemory` (exact, uncapped, present on every backend
/// including iOS — already beating `navigator.deviceMemory`).
public struct DefaultMemoryProvider: MemoryProvider {
    public init() {}

    public func snapshot() async -> MemorySnapshot {
        let physical = ProcessInfo.processInfo.physicalMemory
        let available = Self.availableBytes()
        // No per-app OS ceiling on desktop/iOS (see MemorySnapshot docs);
        // Android supplies its large-heap class via its own provider.
        let low: Bool = {
            guard let available else { return false }
            return available < physical / 8
        }()
        return MemorySnapshot(
            physicalBytes: physical,
            availableBytes: available,
            appLimitBytes: nil,
            lowMemory: low
        )
    }

    /// Best-effort "allocatable right now", or `nil` where the platform gives
    /// no portable signal.
    static func availableBytes() -> UInt64? {
        #if os(iOS)
            // Remaining headroom before the OS jetsams us — the actionable
            // number on iOS, where a static per-app cap isn't exposed.
            let remaining = os_proc_available_memory()
            return remaining > 0 ? UInt64(remaining) : nil
        #elseif os(macOS)
            var stats = vm_statistics64_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
            )
            let result = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            var pageSize = vm_size_t()
            guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
            // Free + inactive pages are both reclaimable for a new allocation.
            let reclaimable = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            return reclaimable * UInt64(pageSize)
        #elseif os(Linux)
            return meminfoAvailableBytes()
        #elseif os(Windows)
            var status = MEMORYSTATUSEX()
            status.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
            guard GlobalMemoryStatusEx(&status) else { return nil }
            return UInt64(status.ullAvailPhys)
        #else
            return nil
        #endif
    }

    #if os(Linux)
        /// Parse `MemAvailable` (kB) out of `/proc/meminfo`. That field is the
        /// kernel's own estimate of allocatable-without-swapping memory —
        /// strictly better than `MemFree` for cache sizing.
        static func meminfoAvailableBytes() -> UInt64? {
            guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else {
                return nil
            }
            for line in text.split(separator: "\n") where line.hasPrefix("MemAvailable:") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                // "MemAvailable:" "12345" "kB"
                if parts.count >= 2, let kb = UInt64(parts[1]) {
                    return kb * 1024
                }
            }
            return nil
        }
    #endif
}

/// Built-in plugin exposing the `system.*` command set — device/OS facts that
/// aren't application identity (`app.*`) or window state (`window.*`).
///
/// Registered eagerly by every backend's `AppContext.init` (alongside
/// `WindowPlugin` / `AppPlugin` / `PlatformInfoPlugin`) — never opt-in — so
/// memory-scaled caches work without app-side setup. A plain browser without
/// the native shell keeps falling back to `navigator.deviceMemory`.
///
/// ## Commands
/// - `system.memory()` → ``MemorySnapshot``: a live point-in-time read. Cheap
///   (one syscall on desktop); fine on a debounce before growing a cache, not
///   per frame.
///
/// ## Events
/// - `system.memoryPressure` on the `events.*` bus, payload `{ level }` where
///   `level ∈ "warning" | "critical"` — the OS asking the app to shed caches
///   *before* it kills the process. Wired here on Apple platforms via
///   `DispatchSource.makeMemoryPressureSource`; the Android backend emits it
///   from `onTrimMemory`. Linux/Windows have no portable signal and don't emit
///   (documented, not synthesized).
public struct SystemPlugin: Plugin {
    public static let pluginName = "system"

    private let memory: any MemoryProvider

    public init(_ memory: any MemoryProvider = DefaultMemoryProvider()) {
        self.memory = memory
    }

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let memory = memory
        registry.register("system.memory", typed: { (_: EmptyArgs, _) async -> MemorySnapshot in
            await memory.snapshot()
        })

        // Emit `system.memoryPressure` on the app-wide event bus where the OS
        // gives us a signal. Apple's `DispatchSource` is the one core can reach
        // directly; Android wires its `onTrimMemory` callback in the backend.
        #if canImport(Darwin)
            MemoryPressureMonitor.shared.start(emitTo: app.events)
        #endif
    }
}

#if canImport(Darwin)
    /// Process-global memory-pressure watcher for Apple platforms. One
    /// `DispatchSource` per process (pressure is a process-wide signal, and
    /// swift-pwa runs one app per process), retained in a `shared` singleton
    /// because a `Plugin` value isn't retained past `register`. Idempotent:
    /// repeated `start` calls (e.g. a second window installing the plugin — it
    /// won't, `use` dedupes — or a re-`use`) are no-ops.
    final class MemoryPressureMonitor: @unchecked Sendable {
        static let shared = MemoryPressureMonitor()

        private let lock = NSLock()
        private var source: (any DispatchSourceMemoryPressure)?

        func start(emitTo events: EventBus) {
            lock.lock()
            defer { lock.unlock() }
            guard source == nil else { return }
            let src = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .global(qos: .utility)
            )
            src.setEventHandler { [weak src] in
                guard let data = src?.data else { return }
                let level = data.contains(.critical) ? "critical" : "warning"
                events.emit(
                    "system.memoryPressure",
                    payload: Data("{\"level\":\"\(level)\"}".utf8)
                )
            }
            src.resume()
            source = src
        }
    }
#endif
