// StatusNotifierItem tray, exercised end-to-end over a real session bus.
//
// Gated on SWIFT_PWA_LINUX_GUI=1 (needs GTK initialized) AND a session
// bus (DBUS_SESSION_BUS_ADDRESS) — run under `dbus-run-session` on the
// GTK box. CI doesn't build the GTK backend at all, so this only ever
// runs on a GTK-capable machine.
//
// The tray registers its D-Bus objects on the session bus in-process;
// we drive them with the `gdbus` CLI (a separate process, so no
// self-call deadlock) while pumping our own GLib main context so the
// in-process server can answer. This covers the risky code — the
// dbusmenu GetLayout marshalling and the Event → event-stream path.
//
// One tray per process is the supported model (one
// `TrayPlugin(SystemTray())`). GDBus shares a single session-bus
// connection process-wide, so a second `SystemTray` would collide on the
// `/StatusNotifierItem` + `/MenuBar` object paths — hence a single tray
// drives both assertions here.
#if os(Linux)
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAGTK
    import Testing

    @Suite(
        "GTK tray (StatusNotifierItem)",
        .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LINUX_GUI"] == "1"
            && ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil),
        .serialized
    )
    @MainActor
    struct GTKTraySNITests {
        /// Run `gdbus <args>` while pumping our main context so the
        /// in-process tray server can service the call. Returns
        /// (combined output, exit code).
        private func gdbus(_ args: [String], timeout: Double = 5) -> (out: String, code: Int32) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["gdbus"] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return ("spawn failed: \(error)", -1) }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning, Date() < deadline {
                pumpMainContextForTesting(seconds: 0.02)
            }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
        }

        @Test("menu exports over dbusmenu and a click Event reaches the stream")
        func exportsMenuAndRoutesEvents() async throws {
            initGTKForTesting()
            let tray = SystemTray()
            tray.setTooltip("swift-pwa test tray")
            tray.setMenu(TrayMenu(items: [
                TrayMenuItem(id: "open", label: "Open App"),
                .separator(),
                TrayMenuItem(id: "quit", label: "Quit", enabled: false)
            ]))

            // A 4×3 RGBA PNG, exercising the GdkPixbuf → ARGB IconPixmap path.
            let iconPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftpwa-tray-\(getpid()).png").path
            let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR4nGP4z8DwHxkzEBQAAGHtF+mRbBMEAAAAAElFTkSuQmCC"
            let pngData = try #require(Data(base64Encoded: pngBase64))
            try pngData.write(to: URL(fileURLWithPath: iconPath))
            defer { try? FileManager.default.removeItem(atPath: iconPath) }
            tray.setIcon(path: iconPath, template: false)

            // Let g_bus_own_name acquire the name + register the objects.
            pumpMainContextForTesting(seconds: 1.0)
            let dest = tray.registeredBusName
            #expect(dest.hasPrefix("org.kde.StatusNotifierItem-"))

            // 0) The icon marshals as a 4×3 ARGB pixmap on the SNI object.
            let (icon, iconCode) = gdbus([
                "call", "--session", "--dest", dest,
                "--object-path", "/StatusNotifierItem",
                "--method", "org.freedesktop.DBus.Properties.Get",
                "org.kde.StatusNotifierItem", "IconPixmap"
            ])
            #expect(iconCode == 0)
            #expect(icon.contains("(4, 3,"))

            // 1) The menu is exported and marshals correctly.
            //    recursionDepth is `1` not `-1`: gdbus's option parser would
            //    swallow a leading-dash token as a flag. The shim ignores
            //    depth and always returns the full flat tree anyway.
            let (layout, layoutCode) = gdbus([
                "call", "--session", "--dest", dest,
                "--object-path", "/MenuBar",
                "--method", "com.canonical.dbusmenu.GetLayout", "0", "1", "[]"
            ])
            #expect(layoutCode == 0)
            #expect(layout.contains("Open App"))
            #expect(layout.contains("Quit"))
            #expect(layout.contains("separator"))

            // 2) An Event on item id 1 ("open") reaches the event stream.
            let stream = tray.eventStream()
            let (_, eventCode) = gdbus([
                "call", "--session", "--dest", dest,
                "--object-path", "/MenuBar",
                "--method", "com.canonical.dbusmenu.Event",
                "1", "clicked", "<int32 0>", "0"
            ])
            #expect(eventCode == 0)
            pumpMainContextForTesting(seconds: 0.2)

            // Race the (already-buffered) event against a timeout so a
            // regression fails the test instead of hanging it.
            let received: TrayEvent? = await withTaskGroup(of: TrayEvent?.self) { group in
                group.addTask { for await ev in stream { return ev }; return nil }
                group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            #expect(received == .menuItemClicked(id: "open"))
        }
    }
#endif
