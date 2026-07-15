#if os(macOS)
    import Crypto
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing

    /// End-to-end delta (binary-patch) update over real HTTP, driving the
    /// actual `AppleUpdater.check` + `download` path — patch fetch, vendored
    /// zstd reconstruction of the `.app.tar.gz`, Ed25519 verification of the
    /// *reconstructed* tarball, extraction, and re-caching the new tarball as
    /// the base for the *next* delta. Also proves the fallback paths
    /// (corrupt patch, base mismatch, no cached base) transparently
    /// full-download instead.
    ///
    /// Unlike the Linux/Windows backends — where the installed file *is* the
    /// signed artifact — macOS patches a **cached** copy of the last verified
    /// `.app.tar.gz` (`<stagingRoot>/base/<version>.app.tar.gz`), so the
    /// harness seeds that cache to stand in for a prior update.
    ///
    /// **Gated behind `SWIFT_PWA_DELTA_E2E=1`** (needs `zstd`, `tar`, and
    /// `python3` on PATH). Run on a Mac:
    ///
    ///   SWIFT_PWA_DELTA_E2E=1 swift test --filter AppleDeltaUpdateE2E
    @Suite("AppleDeltaUpdateE2E", .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_DELTA_E2E"] != nil))
    struct AppleDeltaUpdateE2ETests {
        @Test("delta path downloads only the patch, reconstructs, verifies, extracts, and re-caches the base")
        func deltaHappyPath() async throws {
            let r = try await runScenario(port: 8793, corruptPatch: false, wrongBase: false, seedBase: true)
            // Only the patch was fetched — far below the full artifact.
            #expect(r.maxContentLength < r.fullSize / 5)
            // The extracted bundle is the NEW build (delta reconstructed it).
            #expect(r.stagedMarker == "new-build-marker")
            // The verified tarball was re-cached as the base for the next cycle.
            #expect(r.recachedBaseSHA == r.newTarballSHA)
        }

        @Test("a corrupt patch falls back to a full download")
        func corruptPatchFallsBack() async throws {
            let r = try await runScenario(port: 8794, corruptPatch: true, wrongBase: false, seedBase: true)
            #expect(r.maxContentLength >= r.fullSize)
            #expect(r.stagedMarker == "new-build-marker")
            #expect(r.recachedBaseSHA == r.newTarballSHA)
        }

        @Test("a base-hash mismatch falls back to a full download")
        func baseMismatchFallsBack() async throws {
            let r = try await runScenario(port: 8795, corruptPatch: false, wrongBase: true, seedBase: true)
            #expect(r.maxContentLength >= r.fullSize)
            #expect(r.stagedMarker == "new-build-marker")
        }

        @Test("no cached base (first update after the feature ships) falls back to a full download")
        func noCachedBaseFallsBack() async throws {
            let r = try await runScenario(port: 8796, corruptPatch: false, wrongBase: false, seedBase: false)
            #expect(r.maxContentLength >= r.fullSize)
            #expect(r.stagedMarker == "new-build-marker")
            // Even on the full-download path, the base is cached so the *next*
            // update can go delta.
            #expect(r.recachedBaseSHA == r.newTarballSHA)
        }

        // MARK: - scenario harness

        private struct ScenarioResult {
            var maxContentLength: Int
            var fullSize: Int
            var stagedMarker: String
            var recachedBaseSHA: String?
            var newTarballSHA: String
        }

        private func runScenario(
            port: Int, corruptPatch: Bool, wrongBase: Bool, seedBase: Bool
        ) async throws -> ScenarioResult {
            guard commandAvailable("zstd"), commandAvailable("python3") else {
                throw BridgeError(code: BridgeError.handler, message: "zstd/python3 required for the E2E")
            }
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let serveDir = root.appendingPathComponent("serve", isDirectory: true)
            try FileManager.default.createDirectory(at: serveDir, withIntermediateDirectories: true)

            // Two `.app` trees differing in a localized region (an
            // incompressible "binary" + a marker resource) — representative
            // of a point release. They tar.gz to full artifacts.
            let baseTgz = serveDir.appendingPathComponent("HelloPWA-0.1.0.app.tar.gz")
            let newTgz = serveDir.appendingPathComponent("HelloPWA-0.2.0.app.tar.gz")
            try buildAppTarball(into: baseTgz, marker: "base-build-marker", tweak: 0x00, workRoot: root, name: "b")
            try buildAppTarball(into: newTgz, marker: "new-build-marker", tweak: 0x5A, workRoot: root, name: "n")

            let newBytes = try Data(contentsOf: newTgz)
            let fullSize = newBytes.count
            let newTarballSHA = sha256Hex(newBytes)

            // Patch via the same engine the publish CLI uses.
            let patch = serveDir.appendingPathComponent("0.1.0-to-0.2.0.zstpatch")
            try runProcess("/usr/bin/env", [
                "zstd", "-q", "-f", "-19", "--long=30",
                "--patch-from=\(baseTgz.path)", newTgz.path, "-o", patch.path
            ])
            if corruptPatch {
                var bytes = try Data(contentsOf: patch)
                for i in bytes.indices where i % 5 == 0 { bytes[i] = bytes[i] ^ 0xFF }
                try bytes.write(to: patch)
            }

            // Sign the *full* new artifact; the delta carries no signature.
            let priv = Curve25519.Signing.PrivateKey()
            let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
            let sigB64 = try priv.signature(for: newBytes).base64EncodedString()
            let baseSHA = try sha256Hex(Data(contentsOf: baseTgz))

            let manifest = """
            {
              "version": "0.2.0",
              "platforms": {
                "darwin-aarch64": {
                  "url": "http://127.0.0.1:\(port)/HelloPWA-0.2.0.app.tar.gz",
                  "signature": "\(sigB64)",
                  "deltas": [
                    { "from": "0.1.0",
                      "url": "http://127.0.0.1:\(port)/0.1.0-to-0.2.0.zstpatch",
                      "base_sha256": "\(baseSHA)" }
                  ]
                }
              }
            }
            """
            try manifest.write(
                to: serveDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
            )

            let staging = root.appendingPathComponent("staging", isDirectory: true)
            // Seed the cached base the updater patches against (stands in for a
            // prior update having cached its verified tarball).
            if seedBase {
                let baseDir = staging.appendingPathComponent("base", isDirectory: true)
                try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
                let cached = baseDir.appendingPathComponent("0.1.0.app.tar.gz")
                if wrongBase {
                    // Bytes that don't match base_sha256 → fast-reject fallback.
                    try Data((0 ..< baseSHA.count).map { UInt8($0 & 0xFF) }).write(to: cached)
                } else {
                    try FileManager.default.copyItem(at: baseTgz, to: cached)
                }
            }

            let server = try startHTTPServer(directory: serveDir, port: port)
            defer {
                kill(server.processIdentifier, SIGKILL)
                server.waitUntilExit()
            }
            try await waitForServer(port: port)

            let updater = try AppleUpdater(
                endpoint: #require(URL(string: "http://127.0.0.1:\(port)/manifest.json")),
                publicKey: pubB64,
                currentVersion: "0.1.0",
                target: "darwin-aarch64",
                stagingRoot: staging
            )

            let info = try #require(await updater.check())
            #expect(info.delta != nil) // the manifest advertised a delta

            var maxContentLength = 0
            for try await event in updater.download(info) {
                if case let .downloadProgress(_, total) = event, let total {
                    maxContentLength = max(maxContentLength, total)
                }
            }

            // The extracted bundle's marker resource tells us which build was staged.
            let markerURL = staging.appendingPathComponent("0.2.0")
                .appendingPathComponent("extracted")
                .appendingPathComponent("HelloPWA.app")
                .appendingPathComponent("Contents/Resources/marker.txt")
            let stagedMarker = (try? String(contentsOf: markerURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<missing>"

            let recached = staging.appendingPathComponent("base")
                .appendingPathComponent("0.2.0.app.tar.gz")
            let recachedBaseSHA = (try? Data(contentsOf: recached)).map { sha256Hex($0) }

            return ScenarioResult(
                maxContentLength: maxContentLength,
                fullSize: fullSize,
                stagedMarker: stagedMarker,
                recachedBaseSHA: recachedBaseSHA,
                newTarballSHA: newTarballSHA
            )
        }

        // MARK: - fixtures / helpers

        /// Build a `HelloPWA.app` tree with an incompressible pseudo-binary
        /// (localized by `tweak`) + a marker resource, then `tar czf` it.
        private func buildAppTarball(
            into tgz: URL, marker: String, tweak: UInt8, workRoot: URL, name: String
        ) throws {
            let appRoot = workRoot.appendingPathComponent("app-\(name)", isDirectory: true)
            let app = appRoot.appendingPathComponent("HelloPWA.app", isDirectory: true)
            let macOSDir = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            let resDir = app.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)

            // 4 MB deterministic "binary"; differ only in a localized region.
            var bin = Data((0 ..< 4_000_000).map { UInt8(($0 &* 61 &+ 7) & 0xFF) })
            bin.replaceSubrange(2_000_000 ..< 2_000_400, with: Data(repeating: tweak, count: 400))
            try bin.write(to: macOSDir.appendingPathComponent("HelloPWA"))
            try Data("<plist>0.x</plist>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try marker.write(to: resDir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

            // COPYFILE_DISABLE so macOS tar doesn't embed AppleDouble `._*`.
            try runProcess("/usr/bin/env", [
                "tar", "--no-mac-metadata", "-czf", tgz.path, "-C", appRoot.path, "HelloPWA.app"
            ])
        }

        private func sha256Hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private func commandAvailable(_ name: String) -> Bool {
            (try? runProcess("/usr/bin/env", ["which", name])) != nil
        }

        @discardableResult
        private func runProcess(_ exe: String, _ args: [String]) throws -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.environment = [
                "COPYFILE_DISABLE": "1",
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin"
            ]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw BridgeError(code: BridgeError.handler, message: "\(exe) \(args) exited \(proc.terminationStatus)")
            }
            return proc.terminationStatus
        }

        private func startHTTPServer(directory: URL, port: Int) throws -> Process {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", "-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
            proc.currentDirectoryURL = directory
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            return proc
        }

        private func waitForServer(port: Int) async throws {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/manifest.json"))
            for _ in 0 ..< 50 {
                if let (_, resp) = try? await URLSession.shared.data(from: url),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200
                {
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw BridgeError(code: BridgeError.handler, message: "HTTP server on :\(port) never came up")
        }

        private func makeTempDir() throws -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-apple-delta-e2e-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }
#endif
