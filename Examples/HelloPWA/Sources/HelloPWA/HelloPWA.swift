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
