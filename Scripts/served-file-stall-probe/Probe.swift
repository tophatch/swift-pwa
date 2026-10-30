import Foundation
import SwiftPWA

// Copied into a scaffolded app by verify-served-file-stall.sh (#338).

/// Serves `SERVE_PROBE_DIR` at `/served`, where the page asks for one file
/// whose bytes aren't on disk and one that is.
@MainActor
func registerServeProbe(_ ctx: any AppContext) {
    // `fs.writeText` for the Windows script, which reads a report file.
    ctx.use(FsPlugin(SystemFs()))
    guard let dir = ProcessInfo.processInfo.environment["SERVE_PROBE_DIR"] else { return }
    ctx.serveDirectory(URL(fileURLWithPath: dir), at: "/served")
}
