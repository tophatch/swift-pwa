import Foundation
#if os(Android)
    import Android
#elseif os(iOS)
    import UIKit
#endif

/// What `__platform.info` returns to JS. Apps can read this to make
/// per-platform UI decisions — e.g. greying out a "Copy from
/// clipboard" button when the active backend hasn't installed
/// `ClipboardPlugin`. Registered automatically by every backend's
/// `AppContext.init`; never opt-in.
public struct PlatformInfo: Sendable, Codable, Equatable {
    /// Lowercased OS identifier: `"macos"`, `"ios"`, `"linux"`,
    /// `"windows"`, `"android"`, or `"unknown"`. Stable;
    /// `swift-pwa` doesn't reuse these values for anything else.
    public var os: String
    /// Every command name currently registered on the
    /// `CommandRegistry`. Sorted, so JS can do membership checks
    /// against a stable order without re-sorting.
    public var commands: [String]
    /// Absolute path to a writable temp directory the app can use
    /// for scratch files when `dialog.saveFile` isn't available
    /// (e.g. on the v0.5 Android backend) or otherwise inappropriate
    /// (background work, machine-generated paths). Resolved via
    /// `NSTemporaryDirectory()`, which Foundation maps to the
    /// platform's standard per-process temp area:
    /// `/var/folders/...` on macOS, `<bundle>/tmp` on iOS,
    /// `/tmp` on Linux, `%TEMP%` on Windows, `/data/data/<pkg>/cache`
    /// on Android. No trailing slash.
    public var tempDir: String
    /// Total device RAM in bytes (`ProcessInfo.physicalMemory`). Exact and
    /// uncapped on every backend — including iOS, where `navigator.deviceMemory`
    /// is `undefined` — so it's a strictly better signal for sizing an
    /// in-memory working set at startup. Effectively constant for the session,
    /// which is why it rides this cached call. See the `system.memory` command
    /// (`SystemPlugin`) for a live "available" read and the
    /// `system.memoryPressure` event.
    public var physicalMemoryBytes: UInt64
    /// The per-app memory ceiling in bytes where the OS defines one (Android's
    /// large-heap class), else `nil` (desktop; also iOS, which exposes shrinking
    /// *remaining* headroom via `system.memory`'s `availableBytes` rather than a
    /// fixed cap). Constant for the session.
    public var appMemoryLimitBytes: UInt64?
    /// What to call this device in something a person reads — a
    /// "continue reading on…" list, a sync sidecar, a bug report.
    ///
    /// `ProcessInfo.hostName` is the obvious source and is **`localhost` on
    /// every Android device**, which is how "continue reading from localhost"
    /// ends up in an app's UI. So: the hostname on the three desktops, the
    /// device's own name on iOS, and the model (`ro.product.model`, e.g.
    /// `SM-F966B`) on Android. Never empty — an unknown device reports its OS
    /// identifier rather than a blank a page would have to special-case.
    public var deviceName: String

    public init(
        os: String,
        commands: [String],
        tempDir: String,
        physicalMemoryBytes: UInt64 = 0,
        appMemoryLimitBytes: UInt64? = nil,
        deviceName: String = ""
    ) {
        self.os = os
        self.commands = commands
        self.tempDir = tempDir
        self.physicalMemoryBytes = physicalMemoryBytes
        self.appMemoryLimitBytes = appMemoryLimitBytes
        self.deviceName = deviceName.isEmpty ? os : deviceName
    }
}

/// Built-in plugin that exposes `__platform.info`. The JS side reads
/// the returned `commands` list to decide which UI controls to enable
/// — much simpler than trying every command and watching for "command
/// not registered" errors. Registered eagerly by each backend's
/// `AppContext.init` so the OS branches in cross-platform demos
/// (HelloPWA's button grid, in particular) have a single source of
/// truth.
public final class PlatformInfoPlugin: Plugin {
    public static let pluginName = "__platform"

    /// Supplies `appMemoryLimitBytes`, the one static memory fact that isn't a
    /// portable syscall: `nil` on every backend except Android, which passes a
    /// closure that reads its large-heap class over JNI (and caches it). Kept
    /// as an isolated closure — rather than folding the whole `MemoryProvider`
    /// snapshot in — so that `__platform.info`, a foundational early call,
    /// never depends on a live memory read (`physicalMemoryBytes` comes from the
    /// synchronous, always-available `ProcessInfo.physicalMemory`). A throwing
    /// or slow provider degrades to `nil`, never breaks the call.
    private let appMemoryLimit: @Sendable () async -> UInt64?

    public init(appMemoryLimit: @escaping @Sendable () async -> UInt64? = { nil }) {
        self.appMemoryLimit = appMemoryLimit
    }

    @MainActor
    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let appMemoryLimit = appMemoryLimit
        // The closure captures `registry`. `registry.names()` is
        // called at invoke time, not registration time — the list
        // grows as later `use(_:)` calls install more plugins, so a
        // late-bound read is what gives JS the up-to-date set. (The
        // backends register `PlatformInfoPlugin` first, then plugins
        // like `WindowPlugin`, then user-`use`d plugins, then the
        // first window's webview navigation triggers the page load.
        // By the time JS makes its first `__platform.info` invoke
        // call, every plugin in the configure closure is registered.)
        let registryRef = registry
        registry.register("__platform.info", typed: { (_: EmptyArgs, _) async -> PlatformInfo in
            // `NSTemporaryDirectory()` returns the path with a
            // trailing slash on Apple, no trailing slash on
            // swift-corelibs-foundation. Strip for consistency so
            // JS callers can do `info.tempDir + "/foo.txt"` without
            // double-slash worries.
            var temp = NSTemporaryDirectory()
            if temp.hasSuffix("/") { temp.removeLast() }
            return await PlatformInfo(
                os: currentOSIdentifier(),
                commands: registryRef.names().sorted(),
                tempDir: temp,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                appMemoryLimitBytes: appMemoryLimit(),
                deviceName: currentDeviceName()
            )
        })

        // Typed command catalog for the codegen layer (roadmap #6). Like
        // `__platform.info`'s `commands`, it's read late-bound so it reflects
        // every plugin registered by the time it's called. Returns one
        // `CommandDescriptor` per command registered through a `typed:` variant
        // (raw handlers have no static shape, so they're absent — present only
        // in `__platform.info.commands`).
        registry.register("__bridge.describe", typed: { (_: EmptyArgs, _) -> [CommandDescriptor] in
            registryRef.descriptors()
        })
    }
}

/// Private — exposed via `__platform.info`'s `os` field. Lowercased
/// to match the values JS code on the page typically compares
/// against (e.g. `if (info.os === 'android')`).
/// The device's own name, per platform. See ``PlatformInfo/deviceName`` for
/// why `ProcessInfo.hostName` isn't it.
///
/// Android answers through Bionic's property store rather than a JNI hop to
/// `Build.MODEL`: it's the same string, and it keeps a foundational call that
/// every page makes early off the RPC path.
func currentDeviceName() async -> String {
    #if os(Android)
        var value = [CChar](repeating: 0, count: 92) // PROP_VALUE_MAX
        guard __system_property_get("ro.product.model", &value) > 0 else { return "" }
        // `String(validatingCString:)` is deprecated and the replacement wants
        // the NUL already gone, so cut it here.
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    #elseif os(iOS)
        // Not the user's chosen device name since iOS 16 unless the app is
        // entitled — it degrades to the model ("iPad"), which is still the
        // right answer for this field and needs no entitlement.
        return await MainThread.run { UIDevice.current.name }
    #else
        let host = ProcessInfo.processInfo.hostName
        // `.local` is mDNS bookkeeping, not part of what the machine is
        // called; a person reading a device list doesn't want it.
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    #endif
}

private func currentOSIdentifier() -> String {
    #if os(macOS)
        return "macos"
    #elseif os(iOS)
        return "ios"
    #elseif os(Linux)
        return "linux"
    #elseif os(Windows)
        return "windows"
    #elseif os(Android)
        return "android"
    #else
        return "unknown"
    #endif
}
