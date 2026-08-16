import Foundation
import SwiftPWA
// `ZIPExtractor` lives in SwiftPWAArchive (ZIPFoundation / tar.exe); on Android
// that can't build, so the extractor comes from the SwiftPWA umbrella
// (`AndroidArchiveExtractor`, Kotlin java.util.zip over JNI) instead.
#if !os(Android)
    import SwiftPWAArchive
#endif

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

    // The ceiling on what this app could ever offer an AI agent. It exposes
    // nothing on its own — the demo's "Agent access" card is where a *user*
    // turns it on, per session. This list has to match `agent.expose` in
    // pwa.json, and `swift-pwa build` fails if the two drift apart.
    ctx.use(AgentPlugin(tools: [
        AgentTool(
            command: "now",
            description: "The current time on the device, as an ISO-8601 string.",
            readOnly: true
        ),
        AgentTool(
            command: "demo.importDest",
            description: "Where an imported content pack would be written.",
            readOnly: true
        ),
        AgentTool(
            command: "demo.stageSamplePack",
            description: "Write the bundled sample content pack to a temporary file, ready to import.",
            idempotent: true
        )
    ]))

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

    // Filesystem plugin — Foundation-backed, identical surface on every
    // backend (SystemFs lives in SwiftPWACore). Opt-in because filesystem
    // access is the plugin most likely to be misused. We inject an archive
    // extractor so the content-packs demo can use `fs.extractZip` —
    // `ZIPExtractor` everywhere except Android, which routes to Kotlin's
    // java.util.zip via `AndroidArchiveExtractor`.
    #if os(Android)
        let extractor: any ArchiveExtractor = AndroidArchiveExtractor()
    #else
        let extractor: any ArchiveExtractor = ZIPExtractor()
    #endif
    ctx.use(FsPlugin(SystemFs(extractor: extractor)))

    // Content packs: serve a writable directory under the bundle origin so
    // page JS can reference runtime-extracted media at `/packs/...` on every
    // backend. The app mounts the *container* once; packs extracted into it
    // at runtime are served immediately. On Android the same mount is declared
    // in `pwa.json` (`build.serve`) because the asset loader is built before
    // this code runs; here we mount it imperatively for desktop.
    let packsDir = ctx.dataDirectory().appendingPathComponent("packs", isDirectory: true)
    try? FileManager.default.createDirectory(at: packsDir, withIntermediateDirectories: true)
    ctx.serveDirectory(packsDir, at: "/packs")

    // A tiny custom command the demo's JS calls to get a real on-disk path to
    // the embedded sample `.zip` (writing it into the cache dir). This stands
    // in for `dialog.openFile` — a real app would let the user pick a pack —
    // and works identically on Android, where bundled web assets have no
    // filesystem path that `fs.extractZip` could read. Paths are captured here
    // (configure runs on the MainActor) so the handler — which runs on the
    // cooperative pool — doesn't have to hop back for the dir lookups.
    let cacheDir = ctx.cacheDirectory()
    let sampleDest = packsDir.appendingPathComponent("sample", isDirectory: true)
    ctx.registry.register("demo.stageSamplePack", typed: { (_: EmptyArgs, _) -> StageResult in
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let zipURL = cacheDir.appendingPathComponent("sample-pack.zip")
        try Data(sampleContentPackZip).write(to: zipURL)
        return StageResult(zipPath: zipURL.path, destPath: sampleDest.path)
    })

    // Destination for the *user-picked* import flow (the "Import pack" button):
    // a real path under the `/packs` mount that `fs.extractZip` writes into.
    // The button feeds `dialog.openFile`'s result straight to `fs.extractZip`
    // as `from` — on Android that's a `content://` SAF URI, read off-bridge via
    // the ContentResolver; on desktop it's a real path. Both land here.
    let importDest = packsDir.appendingPathComponent("imported", isDirectory: true)
    ctx.registry.register("demo.importDest", typed: { (_: EmptyArgs, _) -> ImportDestResult in
        ImportDestResult(destPath: importDest.path)
    })

    // Auto-updater. The real backends — `AppleUpdater`,
    // `LinuxAppImageUpdater`, `WindowsUpdater` — only do
    // useful things from inside a bundled artifact pointing
    // at a real signed manifest, so the demo stands one in
    // with `DemoUpdater` (below) which synthesises a visible
    // progress arc and lets users exercise the streaming
    // event surface end-to-end.
    //
    // Set `SWIFT_PWA_UPDATER_ENDPOINT` (+ optional `SWIFT_PWA_UPDATER_PUBKEY`)
    // to swap in the *real* platform backend against a live signed manifest —
    // this is how the manual updater test cases (docs/manual-test-cases.md) are
    // driven against a bundled HelloPWA. Otherwise the demo backend is used.
    let updater = makeUpdater()
    ctx.use(UpdaterPlugin(updater))
    // Opt-in headless smoke (`SWIFT_PWA_UPDATER_SMOKE=1`): drive
    // check → download → installAndRelaunch on launch, logging each stage, so
    // the whole flow can be verified without clicking the demo's UI. Only
    // meaningful with a real backend + endpoint.
    if ProcessInfo.processInfo.environment["SWIFT_PWA_UPDATER_SMOKE"] != nil {
        runUpdaterSmoke(updater)
    }

    // Device surface: the permission policy plus `geo.*`. Declaring is a
    // ceiling, not a grant — the page's own getUserMedia works because
    // something now answers the webview's request, and location goes through
    // the plugin because macOS WKWebView can't be told to allow the web API.
    // See the "Device & location" card in web/index.html.
    ctx.permissions.declare(.camera, .microphone, .geolocation)
    ctx.use(GeoPlugin(SystemGeolocation()))

    // The app's own privacy switch, the thing an in-app "location: off" toggle
    // would drive. It sits *above* the OS prompt, so flipping it off refuses
    // without asking the user about something the app has already decided.
    ctx.permissions.setVeto { permission, _ in
        permission == .geolocation && !LocationSwitch.shared.isOn
    }
    ctx.registry.register("demo.setLocationEnabled", typed: { (args: LocationSwitchArgs, _) -> LocationSwitchArgs in
        LocationSwitch.shared.isOn = args.enabled
        return args
    })

    // Duplex-session demo (bidirectional bridge sessions). A `registerSession`
    // command that keeps per-session state: the page pushes numbers into the
    // open session (`session.push({ add })`) and the handler streams back the
    // running total after each one, on the same correlated channel. This is the
    // thing a plain `subscribe` can't express — the client feeds the stream
    // while it runs. Needs nothing platform-specific, so it's wired
    // unconditionally. See the "Duplex session" card in web/index.html.
    // A small `maxBufferedFrames` so the page's "flood" button visibly
    // overflows the client→server buffer: dropped frames' adds are lost
    // (drop-oldest) and `inbound.droppedCount` climbs, which each event reports
    // back to the UI.
    ctx.registry.registerSession(
        "demo.runningTotal",
        maxBufferedFrames: 32,
        typed: { (_: EmptyArgs, inbound: BridgeInbound<AddFrame>, _)
            -> AsyncThrowingStream<TotalEvent, any Error> in
            AsyncThrowingStream { continuation in
                let task = Task {
                    var total = 0.0
                    var count = 0
                    for await frame in inbound {
                        total += frame.add
                        count += 1
                        continuation.yield(TotalEvent(total: total, count: count, dropped: inbound.droppedCount))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    )

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

/// Returned by `demo.stageSamplePack`: where the sample `.zip` was written
/// and where the demo should extract it (a `/packs/sample` mount on disk).
struct StageResult: Codable, Sendable {
    let zipPath: String
    let destPath: String
}

/// Returned by `demo.importDest`: where the user-picked-pack import flow
/// extracts to (a `/packs/imported` mount on disk).
struct ImportDestResult: Codable, Sendable {
    let destPath: String
}

/// A client frame pushed into the `demo.runningTotal` session (duplex demo).
struct AddFrame: Codable, Sendable { let add: Double }

/// A downstream event the `demo.runningTotal` session streams back. `dropped`
/// is how many pushed frames the bounded buffer discarded (drop-oldest).
struct TotalEvent: Codable, Sendable { let total: Double; let count: Int; let dropped: Int }

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

/// Select the updater backend. With `SWIFT_PWA_UPDATER_ENDPOINT` set, wire the
/// real platform backend against that endpoint (the manifest URL may contain
/// `{{target}}` / `{{current_version}}` placeholders); `SWIFT_PWA_UPDATER_PUBKEY`
/// supplies the Ed25519 public key for signature verification. Without the
/// endpoint, fall back to `DemoUpdater` so the example runs normally.
@MainActor
func makeUpdater() -> any Updater {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["SWIFT_PWA_UPDATER_ENDPOINT"], let endpoint = URL(string: raw) else {
        return DemoUpdater()
    }
    let pubkey = env["SWIFT_PWA_UPDATER_PUBKEY"]
    #if os(macOS) || os(iOS)
        return AppleUpdater(endpoint: endpoint, publicKey: pubkey)
    #elseif os(Linux)
        return LinuxAppImageUpdater(endpoint: endpoint, publicKey: pubkey)
    #elseif os(Windows)
        // Install mode is env-selectable so one build can exercise both the
        // portable (EXE-replace) and MSIX (Add-AppxPackage) paths:
        // SWIFT_PWA_UPDATER_INSTALL_MODE=msix picks MSIX, else portable.
        let mode = env["SWIFT_PWA_UPDATER_INSTALL_MODE"]
            .flatMap(WindowsUpdater.InstallMode.init(rawValue:)) ?? .portable
        return WindowsUpdater(endpoint: endpoint, publicKey: pubkey, installMode: mode)
    #else
        return DemoUpdater()
    #endif
}

/// Headless updater smoke: drive the full flow on launch and log each stage.
/// Markers go to stderr and, if `SWIFT_PWA_UPDATER_SMOKE_LOG` is set, are
/// appended to that file (survives a detached launch). `installAndRelaunch`
/// replaces the process, so the "did it update" signal is the relaunched
/// build's version, not a return here.
@MainActor
func runUpdaterSmoke(_ updater: any Updater) {
    let logPath = ProcessInfo.processInfo.environment["SWIFT_PWA_UPDATER_SMOKE_LOG"]
    @Sendable func mark(_ s: String) {
        let line = "UPDATER_SMOKE \(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let path = logPath {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
            } else {
                try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
    // Run on the cooperative pool, *not* a `@MainActor` task: on the Linux
    // GTK backend the MainActor executor is backed by libdispatch's main
    // queue, which `gtk_main()` never drains, so a `Task { @MainActor in }`
    // body would never start (see CLAUDE.md's concurrency note). The
    // `Updater` methods aren't MainActor-isolated, so a detached task drives
    // them fine on every backend.
    Task.detached {
        // Let the window + bridge come up first.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        do {
            mark("start")
            guard let info = try await updater.check() else { mark("up-to-date"); return }
            mark("available version=\(info.version) current=\(info.currentVersion)")
            for try await event in updater.download(info) {
                switch event {
                case let .downloadProgress(bytes, total):
                    mark("progress \(bytes)/\(total.map(String.init) ?? "?")")
                case .readyToInstall:
                    mark("readyToInstall")
                default:
                    mark("event \(event)")
                }
            }
            mark("installing")
            try await updater.installAndRelaunch()
            mark("installAndRelaunch returned (process not replaced?)")
        } catch {
            mark("error \(error)")
        }
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

/// Backs the "Device & location" card's in-app location toggle. A plain
/// lock-guarded flag rather than anything clever: the point of the demo is
/// that the veto is *the app's* decision, made wherever the app keeps its
/// settings.
final class LocationSwitch: @unchecked Sendable {
    static let shared = LocationSwitch()
    private let lock = NSLock()
    private var value = true
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

struct LocationSwitchArgs: Codable, Sendable {
    var enabled: Bool
}
