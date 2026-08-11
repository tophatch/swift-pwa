import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// Finding the app's `web/` directory — the resolution that used to be copied
/// into every generated `App.swift` and frozen there.
///
/// `.serialized` because the override is a process-global environment variable.
@Suite("Web root", .serialized)
struct WebRootTests {
    /// Sets `SWIFT_PWA_WEB_ROOT` for the duration of `body`. The helper lives in
    /// test support because the Windows path is a compile error you can't catch
    /// locally — see `withEnvironmentVariable`.
    static func withOverride(_ value: String?, _ body: () throws -> Void) rethrows {
        try withEnvironmentVariable(WebRoot.environmentVariable, value, body)
    }

    @Test("a directory that exists is found")
    func findsAnExistingRoot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-webroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = try WebRoot.resolve(fallbacks: [dir])
        #expect(resolved.path == dir.path)
    }

    @Test("a missing root throws, listing every path it tried")
    func missingRootThrows() {
        let ghost = URL(fileURLWithPath: "/nonexistent-swift-pwa-web-\(UUID().uuidString)")
        do {
            _ = try WebRoot.resolve(fallbacks: [ghost])
            #if !os(Android)
                Issue.record("expected a throw")
            #endif
        } catch let error as WebRootError {
            // A blank window is the hardest thing to debug; the paths tried are
            // the whole diagnostic.
            #expect("\(error)".contains(ghost.path))
            #expect("\(error)".contains("swift-pwa build"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    /// A headless catalog dump creates no window, so the web root it would have
    /// used is never read — and throwing there broke `swift-pwa build` for
    /// *any* app declaring `agent.expose`, since the build resolves that list by
    /// running the app for its command catalog and the bare SwiftPM binary has
    /// no staged `web/`. Reported by an adopter whose web directory lives
    /// outside the package entirely, where no `fallbacks:` value could help.
    @Test("a missing root does NOT throw during a headless describe run")
    func missingRootIsToleratedWhileDumping() throws {
        let ghost = URL(fileURLWithPath: "/nonexistent-swift-pwa-web-\(UUID().uuidString)")
        try withEnvironmentVariable(HeadlessDescribe.environmentVariable, "/tmp/catalog.json") {
            #expect(HeadlessDescribe.isDumping)
            // Whatever it returns is never dereferenced; the point is that a
            // build isn't failed over an asset the dump doesn't use.
            #expect(throws: Never.self) { _ = try WebRoot.resolve(fallbacks: [ghost]) }
        }
    }

    @Test("the tolerance is scoped to the dump — it still throws normally")
    func missingRootStillThrowsOutsideADump() throws {
        let ghost = URL(fileURLWithPath: "/nonexistent-swift-pwa-web-\(UUID().uuidString)")
        try withEnvironmentVariable(HeadlessDescribe.environmentVariable, nil) {
            #expect(!HeadlessDescribe.isDumping)
            #if !os(Android)
                #expect(throws: WebRootError.self) { _ = try WebRoot.resolve(fallbacks: [ghost]) }
            #endif
        }
    }

    @Test("fallbacks are tried after the platform default, not before")
    func fallbacksComeLast() {
        let fallback = URL(fileURLWithPath: "/tmp/some-fallback")
        let order = WebRoot.candidates(fallbacks: [fallback])
        // A real bundled app must never prefer a SwiftPM resource bundle
        // staged for development over what `swift-pwa build` produced.
        #expect(order.last?.path == fallback.path)
        #expect(order.count >= 2)
    }

    #if SWIFT_PWA_DRIVER
        @Test("the environment override wins, so tooling can point at a source tree")
        func overrideWins() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("swift-pwa-override-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try Self.withOverride(dir.path) {
                #expect(WebRoot.candidates().first?.path == dir.path)
                let resolved = try WebRoot.resolve()
                #expect(resolved.path == dir.path)
            }
        }

        @Test("an empty override is ignored rather than treated as a path")
        func emptyOverrideIgnored() throws {
            try Self.withOverride("") {
                #expect(WebRoot.candidates().first?.path != "")
            }
        }
    #endif

    @Test("bundledWeb carries entry and spaFallback through")
    func bundledWebPassesOptions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = try WindowContent.bundledWeb(entry: "main.html", spaFallback: true, fallbacks: [dir])
        guard case let .bundled(directory, entry, spaFallback) = content else {
            Issue.record("expected .bundled, got \(content)")
            return
        }
        #expect(directory.path == dir.path)
        #expect(entry == "main.html")
        #expect(spaFallback)
    }
}
