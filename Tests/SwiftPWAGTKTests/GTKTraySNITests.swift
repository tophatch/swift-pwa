// StatusNotifierItem tray, exercised end-to-end over a real session bus,
// on whichever Linux backend is in the package graph.
//
// Gated on SWIFT_PWA_LINUX_GUI=1 (needs GTK initialized) AND a session
// bus (DBUS_SESSION_BUS_ADDRESS) — run under `dbus-run-session` on the
// GTK box. CI has no session bus, so this only ever runs on a desktop
// machine.
//
// **No panel is required.** Both backends export their D-Bus objects as
// soon as the tray exists; a `StatusNotifierWatcher` is who gets *told*,
// not what makes the objects appear. That is true of our own GTK4 shim by
// construction and measured to be true of libayatana on GTK3, which is
// what lets this run headlessly.
//
// The two backends are addressed differently, so the test asks the tray
// where it lives rather than assuming: our GTK4 shim owns a name of its
// own and exports at `/StatusNotifierItem` + `/MenuBar`, while libayatana
// exports onto the app's own connection under
// `/org/ayatana/NotificationItem/<id>`. Asserting GTK4's addresses on
// GTK3 is what made this suite unpassable there (#193).
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
// object paths — hence a single tray drives both assertions here.
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
        func exportsMenuAndRoutesEvents() throws {
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

            // Let the bus name be acquired + the objects registered.
            pumpMainContextForTesting(seconds: 1.0)
            let dest = tray.registeredBusName
            let itemPath = tray.itemObjectPath
            let menuPath = tray.menuObjectPath
            try #require(!dest.isEmpty, "the tray reported no bus name to address")

            // 0) The icon reaches the item. The two backends advertise it
            //    differently and that is the backend difference, not a bug:
            //    our GTK4 shim marshals the file into an ARGB IconPixmap,
            //    while libayatana passes the path through as IconName and
            //    leaves loading it to the panel.
            let iconProperty = Self.usesOwnSNIShim ? "IconPixmap" : "IconName"
            let (icon, iconCode) = gdbus([
                "call", "--session", "--dest", dest,
                "--object-path", itemPath,
                "--method", "org.freedesktop.DBus.Properties.Get",
                "org.kde.StatusNotifierItem", iconProperty
            ])
            #expect(iconCode == 0, "\(iconProperty) on \(itemPath): \(icon)")
            #expect(icon.contains(Self.usesOwnSNIShim ? "(4, 3," : iconPath))

            // 1) The menu is exported and marshals correctly.
            //    recursionDepth is `1` not `-1`: gdbus's option parser would
            //    swallow a leading-dash token as a flag. The shim ignores
            //    depth and always returns the full flat tree anyway.
            let (layout, layoutCode) = gdbus([
                "call", "--session", "--dest", dest,
                "--object-path", menuPath,
                "--method", "com.canonical.dbusmenu.GetLayout", "0", "1", "[]"
            ])
            #expect(layoutCode == 0, "GetLayout on \(menuPath): \(layout)")
            #expect(layout.contains("Open App"))
            #expect(layout.contains("Quit"))
            #expect(layout.contains("separator"))

            // 2) An Event on the "open" item reaches the event stream. Its
            //    dbusmenu id is read back from the layout rather than assumed:
            //    our GTK4 shim numbers items in the order it was given them,
            //    libayatana assigns its own (the same item is 1 on one backend
            //    and 2 on the other). Looking it up also makes this assert what
            //    it claims to — that the item we *named* is the one that fires.
            //    The collector is detached on purpose: a `Task {}` here would
            //    inherit this suite's MainActor isolation and could not run
            //    while the test blocks the main thread pumping GLib, so it
            //    would never drain the stream.
            let openID = try #require(
                Self.menuItemID(labelled: "Open App", in: layout),
                "no 'Open App' item in the layout: \(layout)"
            )

            let stream = tray.eventStream()
            let recorder = EventRecorder()
            let collector = Task.detached { for await ev in stream { recorder.append(ev) } }
            defer { collector.cancel() }

            let (eventOut, eventCode) = gdbus([
                "call", "--session", "--dest", dest,
                "--object-path", menuPath,
                "--method", "com.canonical.dbusmenu.Event",
                openID, "clicked", "<int32 0>", "0"
            ])
            #expect(eventCode == 0, "Event on \(menuPath): \(eventOut)")

            // Pump until the menu callback has fired and the collector has
            // drained it, then assert. Bounded polling rather than awaiting a
            // task group: an event that never arrives has to *fail* this test,
            // and the previous racing shape hung instead — which cost every
            // other GUI suite in the same run its result (#193). The test body
            // is deliberately non-`async` as a result: with no suspension point
            // in it, there is nothing that can be left unresumed.
            let deadline = Date().addingTimeInterval(2)
            while recorder.first == nil, Date() < deadline {
                pumpMainContextForTesting(seconds: 0.05)
            }
            #expect(recorder.first == .menuItemClicked(id: "open"))

            // 3) A *disabled* item does not activate. `enabled: false` is
            //    exported so a panel greys the item out, but a panel is not the
            //    only thing that can send an Event — anything on the session
            //    bus can — so refusing it has to happen in the app, not in the
            //    UI that usually prevents the click.
            let quitID = try #require(Self.menuItemID(labelled: "Quit", in: layout))
            let (quitOut, quitCode) = gdbus([
                "call", "--session", "--dest", dest,
                "--object-path", menuPath,
                "--method", "com.canonical.dbusmenu.Event",
                quitID, "clicked", "<int32 0>", "0"
            ])
            #expect(quitCode == 0, "Event on the disabled item: \(quitOut)")
            pumpMainContextForTesting(seconds: 0.3)
            #expect(
                !recorder.all.contains(.menuItemClicked(id: "quit")),
                "a disabled menu item activated: \(recorder.all)"
            )
        }

        /// The dbusmenu id of the item carrying `label`, read out of a
        /// `GetLayout` reply — `…[<(2, {'label': <'Open App'>, …}, @av [])>…]`.
        /// The id is the integer opening the tuple the label sits in.
        static func menuItemID(labelled label: String, in layout: String) -> String? {
            guard let labelRange = layout.range(of: "'label': <'\(label)'>") else { return nil }
            let head = layout[layout.startIndex ..< labelRange.lowerBound]
            guard let open = head.range(of: "(", options: .backwards) else { return nil }
            let digits = head[open.upperBound...].prefix(while: \.isNumber)
            return digits.isEmpty ? nil : String(digits)
        }

        /// True on the GTK4 backend, which implements SNI + dbusmenu itself.
        /// The GTK3 backend delegates to `libayatana-appindicator3`, and the
        /// two publish the item at different addresses and advertise the icon
        /// differently.
        static var usesOwnSNIShim: Bool {
            #if canImport(CStatusNotifierShim)
                true
            #else
                false
            #endif
        }

        /// Collects stream events from the detached collector task, which
        /// runs on the cooperative pool while the test blocks the main thread.
        final class EventRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [TrayEvent] = []

            func append(_ event: TrayEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }

            var first: TrayEvent? {
                lock.lock()
                defer { lock.unlock() }
                return events.first
            }

            var all: [TrayEvent] {
                lock.lock()
                defer { lock.unlock() }
                return events
            }
        }
    }
#endif
