import ArgumentParser
import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The per-target output layout and the guard that backs it up. Both exist
/// because every Apple bundler writes `<output>/<name>.app`, so an iOS deploy
/// used to overwrite a macOS build in place — and the resulting bundle failed
/// to launch with Finder blaming the architecture.
@Suite("build output layout")
struct BuildOutputLayoutTests {
    @Test("each target defaults to its own subdirectory")
    func perTargetDefaults() {
        #expect(Build.resolveOutput(nil, target: .macos, simulator: false) == "build/macos")
        #expect(Build.resolveOutput(nil, target: .ios, simulator: false) == "build/ios")
        #expect(Build.resolveOutput(nil, target: .ios, simulator: true) == "build/ios-simulator")
        #expect(Build.resolveOutput(nil, target: .linux, simulator: false) == "build/linux")
        #expect(Build.resolveOutput(nil, target: .windows, simulator: false) == "build/windows")
        #expect(Build.resolveOutput(nil, target: .android, simulator: false) == "build/android")
    }

    @Test("an explicit --output is used verbatim")
    func explicitOutputWins() {
        #expect(Build.resolveOutput("dist", target: .macos, simulator: false) == "dist")
        #expect(Build.resolveOutput("dist", target: .ios, simulator: true) == "dist")
    }

    // MARK: - arch validation

    @Test("macOS takes one or both slices")
    func macArchs() throws {
        try Build.validateArchs([], target: .macos)
        try Build.validateArchs(["arm64"], target: .macos)
        try Build.validateArchs(["arm64", "x86_64"], target: .macos)
    }

    @Test("an unknown or repeated macOS arch is refused rather than silently dropped")
    func macArchRejections() {
        #expect(throws: (any Error).self) { try Build.validateArchs(["aarch64"], target: .macos) }
        #expect(throws: (any Error).self) { try Build.validateArchs(["arm64", "arm64"], target: .macos) }
    }

    @Test("Windows takes a single arch; other targets take none")
    func nonMacArchs() throws {
        try Build.validateArchs(["arm64"], target: .windows)
        #expect(throws: (any Error).self) { try Build.validateArchs(["x64", "arm64"], target: .windows) }
        #expect(throws: (any Error).self) { try Build.validateArchs(["arm64"], target: .ios) }
        #expect(throws: (any Error).self) { try Build.validateArchs(["x86_64"], target: .linux) }
        #expect(throws: (any Error).self) { try Build.validateArchs(["arm64-v8a"], target: .android) }
    }

    // MARK: - the clobber guard

    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stamp(_ target: BuildTarget, destination: String? = nil) -> BuildStamp {
        BuildStamp(
            target: target.rawValue, destination: destination, name: "MyApp",
            configuration: "release", cliVersion: "0.0.0"
        )
    }

    @Test("an empty directory, and a rebuild of the same target, are both fine")
    func compatibleCases() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try BuildStamp.checkCompatible(directory: dir, with: stamp(.macos))
        try stamp(.macos).write(to: dir)
        try BuildStamp.checkCompatible(directory: dir, with: stamp(.macos))
    }

    @Test("a build for another platform into the same directory is refused")
    func refusesForeignTarget() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stamp(.macos).write(to: dir)
        #expect(throws: (any Error).self) {
            try BuildStamp.checkCompatible(directory: dir, with: stamp(.ios, destination: "simulator"))
        }
    }

    @Test("a simulator build is refused over a device build (both write <name>.app)")
    func refusesForeignDestination() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stamp(.ios, destination: "device").write(to: dir)
        #expect(throws: (any Error).self) {
            try BuildStamp.checkCompatible(directory: dir, with: stamp(.ios, destination: "simulator"))
        }
    }

    /// The reported case: the existing bundle predates the stamp, so the shape of
    /// the `.app` is the only evidence — macOS bundles have `Contents/`, iOS
    /// bundles are flat.
    @Test("an unstamped macOS .app is recognised by its Contents/ directory")
    func structuralDetectionOfMacBundle() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("MyApp.app/Contents/MacOS"), withIntermediateDirectories: true
        )
        #expect(throws: (any Error).self) {
            try BuildStamp.checkCompatible(directory: dir, with: stamp(.ios, destination: "simulator"))
        }
        // …and the same directory accepts another macOS build.
        try BuildStamp.checkCompatible(directory: dir, with: stamp(.macos))
    }

    @Test("an unstamped iOS .app is recognised by being flat")
    func structuralDetectionOfIOSBundle() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("MyApp.app"), withIntermediateDirectories: true
        )
        #expect(throws: (any Error).self) {
            try BuildStamp.checkCompatible(directory: dir, with: stamp(.macos))
        }
        try BuildStamp.checkCompatible(directory: dir, with: stamp(.ios, destination: "simulator"))
    }
}
