import Foundation
import SwiftPWA
#if os(iOS)
    import UIKit
    import WebKit
#endif

// Copied into a scaffolded app by verify-close-flush.sh / .ps1 (#281).

struct ProbeValue: Codable { let value: String }

private let markerLock = NSLock()

/// `CLOSE_PROBE_LOG` on a desktop; on a phone, where a launch can't easily be
/// handed a path, a folder of the app's own that the harness can reach: its
/// Documents on iOS (`devicectl` copies from there), its data directory on
/// Android (`run-as`), where Foundation's Documents isn't inside the app at all.
private let markerPath: String? = ProcessInfo.processInfo.environment["CLOSE_PROBE_LOG"] ?? {
    #if os(Android)
        PlatformDirectories.dataDirectory(appID: AppPlugin.appID())
            .appendingPathComponent("close-flush-markers.txt").path
    #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("close-flush-markers.txt").path
    #endif
}()

/// One line per marker, appended and closed before the command answers, so a
/// marker on disk means the write finished — the way a synchronous database
/// write would. Serialised: invokes run concurrently, and two handles seeking
/// to the same end overwrite each other.
func appendMarker(_ value: String) {
    guard let path = markerPath else { return }
    markerLock.lock()
    defer { markerLock.unlock() }
    let line = Data((value + "\n").utf8)
    #if os(Android)
        // Android discards stdout and stderr; logcat is where a harness looks.
        RuntimeDiagnostics.emit("CLOSEPROBE \(value)")
    #endif
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: line)
    }
}

final class TakenActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []
    func insert(_ value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.insert(value).inserted
    }
}

func label(_ reason: CloseReason) -> String {
    switch reason {
    case .window: "window"
    case .quit: "quit"
    case .system: "system"
    case .backgrounded: "backgrounded"
    }
}

/// What the page should do once it's ready — `quit`, `close`, or nothing — for
/// a phone, where no driver can tell it. Read from a file beside the markers,
/// which the harness puts there before launch.
private let probeAction: String = {
    guard let path = markerPath else { return "" }
    let file = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("close-probe-action.txt")
    return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}()

@MainActor
func registerCloseProbe(_ ctx: any AppContext) {
    // Once per page prefix: a window the system opens shows the same page,
    // and mustn't run the action a second time.
    let actionTaken = TakenActions()
    ctx.registry.register("probe.action", typed: { (args: ProbeValue?, _) -> String in
        actionTaken.insert(args?.value ?? "") ? probeAction : ""
    })
    ctx.registry.register("probe.write", typed: { (args: ProbeValue, _) -> Bool in
        appendMarker(args.value)
        return true
    })
    // Slow on purpose: a marker from this proves the runtime waited for an
    // invoke to finish, not merely that it arrived.
    ctx.registry.register("probe.slowWrite", typed: { (args: ProbeValue, _) -> Bool in
        try await Task.sleep(for: .milliseconds(300))
        appendMarker(args.value)
        return true
    })
    #if os(iOS)
        // iPad multi-window (#287): a window the app opens, a window the
        // system opens, and a scene the system takes away.
        ctx.registry.register("probe.openScene", typed: { (_: ProbeValue?, _) -> Bool in
            do {
                try await MainActor.run {
                    _ = try ctx.createWindow(WindowConfig(
                        title: "second",
                        size: Size(width: 800, height: 600),
                        content: .bundledWeb(entry: "window2.html", spaFallback: false)
                    ))
                }
                return true
            } catch {
                appendMarker("create-refused")
                return false
            }
        })
        // What "New Window" in the Dock does: a scene with nothing asking for it.
        ctx.registry.register("probe.systemScene", typed: { (_: ProbeValue?, _) -> Bool in
            await MainActor.run {
                UIApplication.shared.activateSceneSession(
                    for: UISceneSessionActivationRequest(role: .windowApplication)
                ) { error in appendMarker("system-scene-error \(error)") }
            }
            return true
        })
        // What closing a window from the system UI does: the calling window's
        // scene goes, without the runtime being asked.
        ctx.registry.register("probe.dropScene", typed: { (_: ProbeValue?, call) -> Bool in
            await MainActor.run {
                guard let id = call.originWindow,
                      let adapter = ctx.window(id)?.webView as? WKWebViewAdapter,
                      let session = adapter.webView.window?.windowScene?.session
                else { return false }
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                return true
            }
        })
        // Between rows: every other window goes, hidden ones included (they
        // outlive closing the connected ones), and the caller forgets its
        // page, so the next launch starts from the app's entry in one window.
        ctx.registry.register("probe.resetSessions", typed: { (_: ProbeValue?, call) -> Bool in
            await MainActor.run {
                let mine = call.originWindow
                    .flatMap { ctx.window($0)?.webView as? WKWebViewAdapter }?
                    .webView.window?.windowScene?.session
                guard let mine else {
                    appendMarker("reset-no-session")
                    return false
                }
                let others = UIApplication.shared.openSessions.filter { $0 !== mine }
                for session in others {
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                }
                mine.userInfo = nil
                appendMarker("reset-\(others.count)")
                return true
            }
        })
        // What iPadOS kept: each session, whether it's connected, and the page
        // the runtime recorded on it.
        ctx.registry.register("probe.sessions", typed: { (_: ProbeValue?, _) -> String in
            await MainActor.run {
                UIApplication.shared.openSessions.map { session in
                    let page = (session.userInfo?["swift-pwa.page"] as? String)
                        .map { URL(string: $0)?.lastPathComponent ?? $0 } ?? "none"
                    return "\(session.scene == nil ? "hidden" : "connected"):\(page)"
                }.sorted().joined(separator: ",")
            }
        })
        // Scene counts at the given delays (ms, comma-separated), taken in
        // Swift: the page asking may be hidden behind the window it opened,
        // and WebKit stops a hidden page's timers.
        ctx.registry.register("probe.countScenes", typed: { (args: ProbeValue, _) -> Bool in
            let start = ContinuousClock.now
            Task { @MainActor in
                for delay in args.value.split(separator: ",").compactMap({ Int($0) }) {
                    try? await Task.sleep(until: start + .milliseconds(delay))
                    appendMarker("scenes-\(UIApplication.shared.connectedScenes.count)")
                }
            }
            return true
        })
    #endif
    ctx.beforeClose { reason in
        try? await Task.sleep(for: .milliseconds(200))
        appendMarker("swift:\(label(reason))")
    }
    if ProcessInfo.processInfo.environment["CLOSE_PROBE_HANG"] == "1" {
        // A handler that never returns, ignoring cancellation: the app has to
        // go anyway, at the deadline.
        ctx.beforeClose { _ in
            while true { try? await Task.sleep(for: .seconds(60)) }
        }
    }
}
