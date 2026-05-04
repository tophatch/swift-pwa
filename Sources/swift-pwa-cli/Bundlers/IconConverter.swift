import Foundation

/// Converts a 1024x1024 source PNG into platform-appropriate icon
/// containers. Best-effort: silently no-ops if the host doesn't have
/// the required tools (`sips`/`iconutil` on macOS, `convert` on Linux).
enum IconConverter {
    static func makeICNS(from png: URL, into icns: URL) async throws {
        // macOS-only path: build an .iconset and run iconutil.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-iconset-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        for size in sizes {
            let dest = tmp.appendingPathComponent("icon_\(size)x\(size).png")
            try await Shell.run("/usr/bin/env", [
                "sips", "-z", "\(size)", "\(size)", png.path, "--out", dest.path
            ])
            if size <= 512 {
                let dest2x = tmp.appendingPathComponent("icon_\(size)x\(size)@2x.png")
                try await Shell.run("/usr/bin/env", [
                    "sips", "-z", "\(size * 2)", "\(size * 2)", png.path, "--out", dest2x.path
                ])
            }
        }
        try await Shell.run("/usr/bin/env", ["iconutil", "-c", "icns", tmp.path, "-o", icns.path])
    }
}
