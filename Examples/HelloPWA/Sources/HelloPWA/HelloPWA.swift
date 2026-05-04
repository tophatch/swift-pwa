import Foundation
import SwiftPWA

@main
struct HelloPWAApp {
    static func main() async throws {
        let runtime = try SwiftPWA.runtime()
        try runtime.run { ctx in
            // Register a custom command that returns the current time.
            ctx.registry.register("now", typed: { (_: EmptyArgs, _) -> NowResult in
                NowResult(iso: ISO8601DateFormatter().string(from: Date()))
            })

            // Tray demo — full implementation on macOS / GTK3, no-op
            // on iOS / GTK4 (the SystemTray stub there logs a one-shot
            // warning to stderr; commands resolve but display nothing).
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

            // Notifications plugin — auth + send. On Apple this needs
            // a bundled app to actually surface banners; under
            // `swift run` the JS-side `notifications.send` will return
            // an "not allowed" error, which is the demo's own
            // way of showing the bundling distinction.
            ctx.use(NotificationsPlugin(SystemNotifications()))

            // Drive a couple of menu items from Swift directly so users
            // can see backend-side reactions to tray events. JS also
            // subscribes via `tray.subscribe` and logs every event.
            Task { @MainActor in
                for await event in tray.eventStream() {
                    if case let .menuItemClicked(id) = event, id == "quit" {
                        ctx.quit(exitCode: 0)
                    }
                }
            }

            _ = try ctx.createWindow(WindowConfig(
                title: "Hello, swift-pwa",
                size: Size(width: 1024, height: 768),
                content: .bundled(directory: locateWebRoot())
            ))
        }
    }
}

struct NowResult: Codable, Sendable {
    let iso: String
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
