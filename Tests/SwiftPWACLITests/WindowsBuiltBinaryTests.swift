import Foundation
@testable import SwiftPWACLISupport
import Testing

/// Where the Windows bundler finds the exe a build made, which is also how it
/// decides the permission check's build can stand in for its own: only when
/// the exe is actually there.
@Suite("Windows built binary lookup")
struct WindowsBuiltBinaryTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-built-binary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    @Test("Found through the configuration directory")
    func throughConfigurationDirectory() throws {
        let build = try scratch()
        defer { try? FileManager.default.removeItem(at: build) }
        let exe = build.appendingPathComponent("release/App.exe")
        try touch(exe)
        #expect(WindowsBundler.builtBinary(exeName: "App.exe", buildDir: build, configuration: .release) == exe)
    }

    @Test("Found in the arch directory when SwiftPM couldn't make the symlink")
    func inArchDirectory() throws {
        let build = try scratch()
        defer { try? FileManager.default.removeItem(at: build) }
        let exe = build.appendingPathComponent("x86_64-unknown-windows-msvc/release/App.exe")
        try touch(exe)
        // A directory listing hands back the resolved path (/private/var on macOS).
        let found = WindowsBundler.builtBinary(exeName: "App.exe", buildDir: build, configuration: .release)
        #expect(found?.resolvingSymlinksInPath().path == exe.resolvingSymlinksInPath().path)
    }

    @Test("Absent when only another configuration was built")
    func otherConfiguration() throws {
        let build = try scratch()
        defer { try? FileManager.default.removeItem(at: build) }
        try touch(build.appendingPathComponent("x86_64-unknown-windows-msvc/debug/App.exe"))
        #expect(WindowsBundler.builtBinary(exeName: "App.exe", buildDir: build, configuration: .release) == nil)
    }
}
