#if os(Linux)
    import Crypto
    import Foundation
    import Glibc // kill(2) / SIGKILL for reliable HTTP-server teardown
    import SwiftPWACore
    @testable import SwiftPWAGTK
    import Testing

    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// End-to-end delta (binary-patch) update over real HTTP, driving the
    /// actual `LinuxAppImageUpdater.check` + `download` path — patch fetch,
    /// libzstd reconstruction, Ed25519 verification of the *reconstructed*
    /// artifact, and staging. Also proves the two fallback paths (corrupt
    /// patch, base mismatch) transparently full-download instead.
    ///
    /// **Gated behind `SWIFT_PWA_DELTA_E2E=1`** (and needs `zstd` +
    /// `python3` on PATH), because it spins a throwaway HTTP server and
    /// binds a port — not something to run on every CI image. Run it on the
    /// GTK verify box:
    ///
    ///   SWIFT_PWA_GTK4=1 SWIFT_PWA_DELTA_E2E=1 swift test --filter LinuxDeltaUpdateE2E
    ///
    /// swift-corelibs URLSession rejects `file://`, so a real HTTP origin is
    /// required — hence the server rather than a hermetic file-URL fixture.
    @Suite("LinuxDeltaUpdateE2E", .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_DELTA_E2E"] != nil))
    struct LinuxDeltaUpdateE2ETests {
        @Test("delta path downloads only the patch, reconstructs, verifies, and stages the new artifact")
        func deltaHappyPath() async throws {
            let r = try await runScenario(port: 8790, corruptPatch: false, wrongBase: false)
            // Only the patch was fetched — its advertised size is far below
            // the full artifact, which is the whole point of a delta.
            #expect(r.maxContentLength < r.fullSize / 5)
            #expect(r.stagedSHA == r.newSHA)
        }

        @Test("a corrupt patch falls back to a full download")
        func corruptPatchFallsBack() async throws {
            let r = try await runScenario(port: 8791, corruptPatch: true, wrongBase: false)
            // The full artifact was fetched (fallback), so the largest
            // content-length seen is the full size, and the result still
            // installs correctly.
            #expect(r.maxContentLength >= r.fullSize)
            #expect(r.stagedSHA == r.newSHA)
        }

        @Test("a base mismatch falls back to a full download")
        func baseMismatchFallsBack() async throws {
            let r = try await runScenario(port: 8792, corruptPatch: false, wrongBase: true)
            #expect(r.maxContentLength >= r.fullSize)
            #expect(r.stagedSHA == r.newSHA)
        }

        // MARK: - scenario harness

        private struct ScenarioResult {
            var maxContentLength: Int
            var fullSize: Int
            var stagedSHA: String
            var newSHA: String
        }

        private func runScenario(port: Int, corruptPatch: Bool, wrongBase: Bool) async throws -> ScenarioResult {
            guard commandAvailable("zstd"), commandAvailable("python3") else {
                throw BridgeError(code: BridgeError.handler, message: "zstd/python3 required for the E2E")
            }
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let serveDir = root.appendingPathComponent("serve", isDirectory: true)
            try FileManager.default.createDirectory(at: serveDir, withIntermediateDirectories: true)

            // "AppImages": a base (v0.1.0) and a new build (v0.2.0) that
            // differs in a small region — they don't have to be launchable
            // here (we drive check+download, not install).
            var newBytes = Data((0 ..< 4_000_000).map { UInt8($0 &* 53 & 0xFF) })
            let base = serveDir.appendingPathComponent("MyApp-0.1.0.AppImage")
            try newBytes.write(to: base)
            newBytes.replaceSubrange(2_000_000 ..< 2_000_400, with: Data(repeating: 0xC3, count: 400))
            let new = serveDir.appendingPathComponent("MyApp-0.2.0.AppImage")
            try newBytes.write(to: new)
            let fullSize = newBytes.count

            // Patch via the CLI's engine (zstd --patch-from).
            let patch = serveDir.appendingPathComponent("0.1.0-to-0.2.0.zstpatch")
            try runProcess("/usr/bin/env", [
                "zstd", "-q", "-f", "-19", "--long=30",
                "--patch-from=\(base.path)", new.path, "-o", patch.path
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
            let baseSHA = try sha256Hex(Data(contentsOf: base))

            let manifest = """
            {
              "version": "0.2.0",
              "platforms": {
                "linux-x86_64-appimage": {
                  "url": "http://127.0.0.1:\(port)/MyApp-0.2.0.AppImage",
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
            try manifest.write(to: serveDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

            // The "installed" base the updater patches against. For the
            // wrong-base case, hand it a file whose bytes differ from the
            // advertised base_sha256 so the fast-reject fires.
            let installed = root.appendingPathComponent("installed.AppImage")
            if wrongBase {
                try Data((0 ..< 4_000_000).map { UInt8($0 &* 7 & 0xFF) }).write(to: installed)
            } else {
                try FileManager.default.copyItem(at: base, to: installed)
            }

            let server = try startHTTPServer(directory: serveDir, port: port)
            defer {
                // SIGTERM (Process.terminate) does NOT reliably kill
                // `python -m http.server` here — a plain terminate() leaves
                // the server alive holding its port, which fails the next
                // run. SIGKILL by pid, then reap so the port is freed.
                kill(server.processIdentifier, SIGKILL)
                server.waitUntilExit()
            }
            try await waitForServer(port: port)

            let staging = root.appendingPathComponent("staging", isDirectory: true)
            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "http://127.0.0.1:\(port)/manifest.json")),
                publicKey: pubB64,
                currentVersion: "0.1.0",
                target: "linux-x86_64-appimage",
                stagingRoot: staging,
                appImagePath: installed
            )

            let info = try #require(await updater.check())
            #expect(info.delta != nil) // the manifest advertised a delta

            var maxContentLength = 0
            for try await event in updater.download(info) {
                if case let .downloadProgress(_, total) = event, let total {
                    maxContentLength = max(maxContentLength, total)
                }
            }
            let staged = staging.appendingPathComponent("0.2.0").appendingPathComponent("update.AppImage")
            let stagedData = try Data(contentsOf: staged)
            return ScenarioResult(
                maxContentLength: maxContentLength,
                fullSize: fullSize,
                stagedSHA: sha256Hex(stagedData),
                newSHA: sha256Hex(newBytes)
            )
        }

        // MARK: - helpers

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

        /// Poll the server until it answers (or give up after ~5s).
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
                .appendingPathComponent("swift-pwa-delta-e2e-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }
#endif
