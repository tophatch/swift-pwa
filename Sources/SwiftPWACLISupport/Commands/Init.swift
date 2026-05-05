import ArgumentParser
import Foundation

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Scaffold a new swift-pwa project."
    )

    @Argument(help: "Project name (also used as the directory name).")
    var name: String

    @Option(help: "Reverse-DNS identifier for the app, e.g. com.example.hello.")
    var bundleId: String?

    @Option(help: "Directory to create the project in. Defaults to current dir + name.")
    var path: String?

    func run() async throws {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let root = path.map { URL(fileURLWithPath: $0) } ?? cwd.appendingPathComponent(name)

        if fm.fileExists(atPath: root.path) {
            throw ValidationError("Directory already exists: \(root.path)")
        }

        let id = bundleId ?? "com.example.\(name.lowercased())"
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Sources/\(name)"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: true)

        let manifest = PWAManifest(
            id: id,
            name: name,
            version: "0.1.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: name),
            macos: .init(bundleIdentifier: id, category: nil, minimumSystemVersion: "15.0"),
            ios: .init(bundleIdentifier: id, minimumSystemVersion: "18.0"),
            linux: .init(desktopCategories: ["Utility"], executableName: nil)
        )
        try manifest.write(to: root.appendingPathComponent("pwa.json"))

        try Templates.packageSwift(name: name).write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Templates.mainSwift(name: name).write(
            to: root.appendingPathComponent("Sources/\(name)/App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Templates.indexHTML(name: name).write(
            to: root.appendingPathComponent("web/index.html"),
            atomically: true,
            encoding: .utf8
        )
        try ".build/\nDerivedData/\nbuild/\n*.app\n*.ipa\n*.AppImage\n".write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        print("Created \(root.path)")
        print("Next: cd \(name) && swift run swift-pwa build --target macos")
    }
}

enum Templates {
    static func packageSwift(name: String) -> String {
        """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            platforms: [.macOS(.v15), .iOS(.v18)],
            dependencies: [
                .package(url: "https://github.com/tophatch/swift-pwa", from: "0.1.0"),
            ],
            targets: [
                .executableTarget(
                    name: "\(name)",
                    dependencies: [
                        .product(name: "SwiftPWA", package: "swift-pwa"),
                    ]
                ),
            ]
        )
        """
    }

    static func mainSwift(name: String) -> String {
        """
        import Foundation
        import SwiftPWA

        @main
        struct \(name)App {
            static func main() async throws {
                let runtime = try SwiftPWA.runtime()
                try runtime.run { ctx in
                    let webRoot = Bundle.main.bundleURL.appendingPathComponent("web")
                    _ = try ctx.createWindow(.init(
                        title: "\(name)",
                        size: .init(width: 1024, height: 768),
                        content: .bundled(directory: webRoot)
                    ))
                }
            }
        }
        """
    }

    static func indexHTML(name: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8" />
        <title>\(name)</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; }
          button { padding: .5rem 1rem; }
        </style></head>
        <body>
        <h1>Hello, \(name)</h1>
        <p>Powered by <a href="https://github.com/tophatch/swift-pwa">swift-pwa</a>.</p>
        <button id="rename">Rename window</button>
        <pre id="log"></pre>
        <script>
          const log = (m) => document.getElementById('log').textContent += m + '\\n';
          document.getElementById('rename').onclick = async () => {
            try {
              await __SWIFT_PWA__.invoke('window.setTitle', { title: 'renamed at ' + new Date().toISOString() });
              log('renamed');
            } catch (e) { log('error: ' + e.message); }
          };
          __SWIFT_PWA__.subscribe('window.subscribe', {}, (e) => log('event: ' + JSON.stringify(e)));
        </script>
        </body></html>
        """
    }
}
