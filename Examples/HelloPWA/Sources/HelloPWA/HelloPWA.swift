import Foundation
import SwiftPWA

// `@main` is the desktop entry point; on Android it's still defined
// so SwiftPM's linker can resolve its `--defsym=main=HelloPWA_main`
// indirection, but the .so is loaded by the JVM via
// `System.loadLibrary` and the JNI entry point in
// `AndroidEntry.swift` drives the runtime instead — `main()` here
// is unreachable on Android.
@main
struct HelloPWAApp {
    static func main() async throws {
        let runtime = try SwiftPWA.runtime()
        try runtime.run(configure)
    }
}

/// The cross-platform configure closure. Called from `HelloPWAApp.main`
/// on desktop and from the JNI entry in `AndroidEntry.swift` on
/// Android. `@MainActor` to match the protocol's
/// `@escaping @MainActor @Sendable (any AppContext) throws -> Void`
/// signature.
@MainActor
func configure(_ ctx: any AppContext) throws {
    // Register a custom command that returns the current time.
    ctx.registry.register("now", typed: { (_: EmptyArgs, _) -> NowResult in
        NowResult(iso: ISO8601DateFormatter().string(from: Date()))
    })

    // Tray — only registered where a real surface exists. Android
    // has no system-tray analogue (foreground-service notifications
    // are a heavy and Android-specific UX), so we skip it there
    // rather than register the no-op stub. The demo's capability
    // gating greys the tray buttons out automatically based on
    // `__platform.info.commands`.
    #if !os(Android)
        let tray = SystemTray()
        try? installTrayIcon(on: tray)
        tray.setTooltip("HelloPWA")
        tray.setMenu(TrayMenu(items: [
            TrayMenuItem(id: "ping", label: "Server ping"),
            TrayMenuItem(id: "rename", label: "Rename window"),
            .separator(),
            TrayMenuItem(id: "quit", label: "Quit HelloPWA")
        ]))
        ctx.use(TrayPlugin(tray))

        Task { @MainActor in
            for await event in tray.eventStream() {
                if case let .menuItemClicked(id) = event, id == "quit" {
                    ctx.quit(exitCode: 0)
                }
            }
        }
    #endif

    // Notifications, Dialog, BiometricAuth — first-class on every
    // backend including Android (v0.5.x), driven through the
    // Swift→Kotlin RPC channel on Android and the platform-native
    // APIs on the desktop backends. On Apple this needs a bundled
    // app to surface notification banners; under `swift run` the
    // JS-side `notifications.send` returns an "not allowed" error,
    // which is the demo's own way of showing the bundling distinction.
    ctx.use(NotificationsPlugin(SystemNotifications()))
    ctx.use(DialogPlugin(SystemDialog()))
    ctx.use(BiometricAuthPlugin(SystemBiometricAuth()))

    // Filesystem plugin — Foundation-backed, identical surface
    // on every backend (SystemFs lives in SwiftPWACore). Opt-in
    // because filesystem access is the plugin most likely to be
    // misused.
    ctx.use(FsPlugin(SystemFs()))

    // Auto-updater. The real backends — `AppleUpdater`,
    // `LinuxAppImageUpdater`, `WindowsUpdater` — only do
    // useful things from inside a bundled artifact pointing
    // at a real signed manifest, so the demo stands one in
    // with `DemoUpdater` (below) which synthesises a visible
    // progress arc and lets users exercise the streaming
    // event surface end-to-end.
    ctx.use(UpdaterPlugin(DemoUpdater()))

    // Window content: bundled `web/` for desktop (resolved from the
    // app's resource bundle), or `https://swift-pwa.local/web/...`
    // for Android (the AndroidWebViewAdapter ignores the directory
    // path and routes through the WebViewAssetLoader instead).
    #if os(Android)
        let content = WindowContent.bundled(directory: URL(fileURLWithPath: "/android_asset/web"))
    #else
        let content = WindowContent.bundled(directory: locateWebRoot())
    #endif

    _ = try ctx.createWindow(WindowConfig(
        title: "Hello, swift-pwa",
        size: Size(width: 1024, height: 768),
        content: content
    ))
}

struct NowResult: Codable, Sendable {
    let iso: String
}

/// Local stand-in for a real `Updater` used by the demo's "Updater"
/// card. `check` always reports a fresh release; `download` synthesises
/// a fast progress arc so the v0.4 streaming-download feature has a
/// visible exhibit; `installAndRelaunch` deliberately throws because
/// the running `swift run` process has nothing to swap onto. Production
/// apps wire one of `AppleUpdater` / `LinuxAppImageUpdater` /
/// `WindowsUpdater` here against a real signed manifest endpoint.
final class DemoUpdater: Updater, @unchecked Sendable {
    func check() async throws -> UpdateInfo? {
        UpdateInfo(
            version: "0.4.0",
            currentVersion: "0.3.0",
            pubDate: ISO8601DateFormatter().string(from: Date()),
            notes: "Demo update — never actually installs.",
            downloadURL: URL(string: "https://example.invalid/demo.bin")!,
            signature: "",
            target: "demo"
        )
    }

    func download(_: UpdateInfo) -> AsyncThrowingStream<UpdaterEvent, any Error> {
        AsyncThrowingStream { continuation in
            // 18 chunks across ~270 ms — slow enough for the user to
            // see the progress bar fill, fast enough that they aren't
            // stuck waiting. Real backends emit at the granularity of
            // `URLSessionDownloadDelegate.didWriteData` (~64 KB).
            let task = Task {
                let total = 4_500_000
                let chunks = 18
                for i in 0 ... chunks {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    let bytes = total * i / chunks
                    continuation.yield(.downloadProgress(
                        bytesDownloaded: bytes,
                        contentLength: total
                    ))
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
                continuation.yield(.readyToInstall)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func installAndRelaunch() async throws {
        // `swift run`'s process has nothing meaningful to swap onto;
        // a real Updater backend would `exec` into a detached helper
        // here. Throw a clear bridge error so the demo's UI shows
        // what production apps would do behind a "Restart now" prompt.
        throw BridgeError(
            code: BridgeError.handler,
            message: """
            DemoUpdater can't relaunch the running `swift run` process. Wire a real \
            backend (AppleUpdater / LinuxAppImageUpdater / WindowsUpdater) against \
            a signed manifest endpoint to exercise the install path.
            """
        )
    }
}

/// Locates the `web/` folder, looking in:
///   1. `Bundle.main.resourceURL/web` — where `swift-pwa build` puts it
///      inside `MyApp.app/Contents/Resources/`.
///   2. `Bundle.module.bundleURL/web` — the SwiftPM resource bundle
///      used by plain `swift run`.
func locateWebRoot() -> URL {
    let fm = FileManager.default
    if let main = Bundle.main.resourceURL?.appendingPathComponent("web"),
       fm.fileExists(atPath: main.path) {
        return main
    }
    return Bundle.module.bundleURL.appendingPathComponent("web")
}

/// Materialise the bundled tray icon PNG into the temp dir and point
/// the tray at it. Tray icon paths must be real files on disk — both
/// `NSImage(contentsOfFile:)` and `gtk_status_icon_set_from_file` only
/// accept paths, not in-memory buffers — so we write once per launch.
@MainActor
func installTrayIcon(on tray: any Tray) throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hellopwa-tray.png")
    try Data(trayIconPNG).write(to: url)
    // Template asks AppKit to tint the icon for the menu bar; ignored
    // on platforms without auto-tinting.
    tray.setIcon(path: url.path, template: true)
}

/// 16×16 RGBA PNG of a black filled circle on transparent background.
/// Generated once and embedded so the demo doesn't ship a binary or
/// depend on AppKit / Cairo for icon rendering.
private let trayIconPNG: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0xF3, 0xFF, 0x61, 0x00, 0x00, 0x00,
    0x5B, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0xA0, 0x11, 0xE0,
    0x04, 0xE2, 0x60, 0x20, 0xAE, 0x82, 0xE2, 0x60, 0xA8, 0x18, 0x51, 0x00,
    0xA4, 0xE1, 0x0B, 0x10, 0xFF, 0x47, 0xC3, 0x5F, 0xA0, 0x72, 0x78, 0xC1,
    0x22, 0x2C, 0x1A, 0xD1, 0xF1, 0x22, 0x7C, 0x36, 0xFF, 0x27, 0x12, 0x57,
    0x61, 0xF3, 0xF3, 0x17, 0x12, 0x0C, 0xF8, 0x82, 0x1E, 0x26, 0xC1, 0x24,
    0x68, 0x86, 0xE1, 0x60, 0x72, 0x9D, 0x8F, 0xD5, 0x1B, 0x14, 0x1B, 0x40,
    0xB1, 0x17, 0x28, 0x0E, 0x44, 0x8A, 0xA3, 0x91, 0x2A, 0x09, 0x89, 0x2A,
    0x49, 0x99, 0x2A, 0x99, 0x89, 0x24, 0x00, 0x00, 0xDF, 0x21, 0x84, 0x39,
    0x04, 0x87, 0x90, 0x6A, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
    0xAE, 0x42, 0x60, 0x82
]
