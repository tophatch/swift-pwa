import Foundation
import SwiftPWA

// Copied into a scaffolded app by verify-close-flush.sh / .ps1 (#281).

struct ProbeValue: Codable { let value: String }

private let markerLock = NSLock()

/// One line per marker, appended and closed before the command answers, so a
/// marker on disk means the write finished — the way a synchronous database
/// write would. Serialised: invokes run concurrently, and two handles seeking
/// to the same end overwrite each other.
func appendMarker(_ value: String) {
    guard let path = ProcessInfo.processInfo.environment["CLOSE_PROBE_LOG"] else { return }
    markerLock.lock()
    defer { markerLock.unlock() }
    let line = Data((value + "\n").utf8)
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: line)
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

@MainActor
func registerCloseProbe(_ ctx: any AppContext) {
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
