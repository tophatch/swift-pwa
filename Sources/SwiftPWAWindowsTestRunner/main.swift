// Stand-alone test runner for the Windows backend.
//
// We can't use a regular `swift-testing` `testTarget` on Windows: SwiftPM's
// test-discovery build plugin emits 0-byte stubs for every suite on Windows
// (Swift 6.1.2 and 6.3.1, both x64 and arm64), so the test bundle finds zero
// tests at runtime and `swift test` exits 1 with no output. `--list-tests`
// hangs on the same code path. See docs/windows-setup.md "Known limitations".
//
// Rather than ship a green CI check that ran nothing, this target re-expresses
// the WindowsUpdater coverage as a plain executable with a tiny assertion
// harness. CI invokes it via `swift run SwiftPWAWindowsTestRunner`.

#if os(Windows)
    import Crypto
    import Foundation
    import SwiftPWACore

    // Plain `import`, not `@testable`: SwiftPM only sets `-enable-testing`
    // on debug-config builds with a test-target dependent. The CI Windows
    // job runs `swift build -c release` first, which compiles this target
    // in release where `@testable` fails. The members we used to reach via
    // `@testable` (`verifyEd25519`, `verifySignature`, `currentExecutablePath`,
    // `msixIdentityName`, `applicationID`) are now `package`-access on
    // `WindowsUpdater` instead.
    import SwiftPWAImage
    import SwiftPWAImageIO
    import SwiftPWAWindows

    // MARK: - Harness

    struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String {
            message
        }
    }

    func expect(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String = "expectation failed")
        throws
    {
        if !cond() { throw TestFailure(message: msg()) }
    }

    func require<T>(_ value: T?, _ name: String = "value") throws -> T {
        guard let value else { throw TestFailure(message: "required \(name) was nil") }
        return value
    }

    func fail(_ message: String) throws -> Never {
        throw TestFailure(message: message)
    }

    func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-updater-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    let manifestURL = URL(string: "https://example.invalid/manifest.json")!

    // MARK: - Tests

    func installAndRelaunchWithoutStagedUpdate() async throws {
        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: nil,
            installMode: .portable,
            executablePath: URL(fileURLWithPath: "C:/Program Files/Fake/MyApp.exe")
        )
        do {
            try await updater.installAndRelaunch()
            try fail("expected installAndRelaunch to throw")
        } catch let bridge as BridgeError {
            try expect(bridge.code == BridgeError.handler, "wrong code: \(bridge.code)")
            try expect(bridge.message.contains("no staged update"), "wrong message: \(bridge.message)")
        }
    }

    func currentExecutablePathOverride() throws {
        let override = URL(fileURLWithPath: "C:/Apps/Whatever/MyApp.exe")
        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: nil,
            installMode: .portable,
            executablePath: override
        )
        try expect(updater.currentExecutablePath() == override)
    }

    func verifyEd25519HappyPath() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
        let payload = Data("the artifact bytes".utf8)
        let sigB64 = try priv.signature(for: payload).base64EncodedString()

        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: pubB64,
            installMode: .portable
        )
        try updater.verifyEd25519(data: payload, signature: sigB64)
    }

    func verifyEd25519WrongKey() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let unrelatedKey = Curve25519.Signing.PrivateKey()
        let payload = Data("the artifact bytes".utf8)
        let sigB64 = try signingKey.signature(for: payload).base64EncodedString()

        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: unrelatedKey.publicKey.rawRepresentation.base64EncodedString(),
            installMode: .portable
        )
        do {
            try updater.verifyEd25519(data: payload, signature: sigB64)
            try fail("expected verifyEd25519 to throw")
        } catch let bridge as BridgeError {
            try expect(bridge.code == BridgeError.handler)
            try expect(bridge.message.contains("signature verification failed"), "wrong message: \(bridge.message)")
        }
    }

    func verifyEd25519NoKey() throws {
        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: nil,
            installMode: .portable
        )
        do {
            try updater.verifyEd25519(data: Data(), signature: "")
            try fail("expected verifyEd25519 to throw")
        } catch let bridge as BridgeError {
            try expect(bridge.message.contains("no public key configured"), "wrong message: \(bridge.message)")
        }
    }

    func verifyEd25519MalformedSignature() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: priv.publicKey.rawRepresentation.base64EncodedString(),
            installMode: .portable
        )
        do {
            try updater.verifyEd25519(data: Data("x".utf8), signature: "not-base64!!")
            try fail("expected verifyEd25519 to throw")
        } catch let bridge as BridgeError {
            try expect(bridge.message.contains("64-byte Ed25519 signature"), "wrong message: \(bridge.message)")
        }
    }

    func msixSkipVerifyWithoutKey() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let staged = tmp.appendingPathComponent("update.msix")
        try Data("fake msix bytes".utf8).write(to: staged)
        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: nil,
            installMode: .msix
        )
        let info = try UpdateInfo(
            version: "0.4.0",
            currentVersion: "0.3.0",
            downloadURL: require(URL(string: "https://example.invalid/update.msix")),
            signature: "",
            target: "windows-x86_64-msix"
        )
        try updater.verifySignature(at: staged, info: info)
    }

    func msixVerifiesWhenKeySet() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let staged = tmp.appendingPathComponent("update.msix")
        let payload = Data("real msix bytes".utf8)
        try payload.write(to: staged)

        let priv = Curve25519.Signing.PrivateKey()
        let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
        let sigB64 = try priv.signature(for: payload).base64EncodedString()

        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: pubB64,
            installMode: .msix
        )
        let info = try UpdateInfo(
            version: "0.4.0",
            currentVersion: "0.3.0",
            downloadURL: require(URL(string: "https://example.invalid/update.msix")),
            signature: sigB64,
            target: "windows-x86_64-msix"
        )
        try updater.verifySignature(at: staged, info: info)
    }

    func portableRequiresKey() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let staged = tmp.appendingPathComponent("update.exe")
        try Data("fake exe".utf8).write(to: staged)
        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: nil,
            installMode: .portable
        )
        let info = try UpdateInfo(
            version: "0.4.0",
            currentVersion: "0.3.0",
            downloadURL: require(URL(string: "https://example.invalid/update.exe")),
            signature: "",
            target: "windows-x86_64-portable"
        )
        do {
            try updater.verifySignature(at: staged, info: info)
            try fail("expected verifySignature to throw on portable without key")
        } catch let bridge as BridgeError {
            try expect(bridge.message.contains("no public key configured"), "wrong message: \(bridge.message)")
        }
    }

    func msixIdentityDefaultsNil() throws {
        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: nil,
            installMode: .msix
        )
        try expect(updater.msixIdentityName == nil)
        try expect(updater.applicationID == "App")
    }

    func msixIdentityRoundtrip() throws {
        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: nil,
            installMode: .msix,
            msixIdentityName: "com.example.hello",
            applicationID: "App"
        )
        try expect(updater.msixIdentityName == "com.example.hello")
        try expect(updater.applicationID == "App")
    }

    func verifyEd25519MinisignInputs() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let payload = Data("an msix's bytes".utf8)
        let rawSig = try priv.signature(for: payload)

        var pubBlob = Data()
        pubBlob.append(contentsOf: "Ed".utf8)
        pubBlob.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        pubBlob.append(priv.publicKey.rawRepresentation)
        let pubText = """
        untrusted comment: minisign public key
        \(pubBlob.base64EncodedString())
        """

        var sigBlob = Data()
        sigBlob.append(contentsOf: "Ed".utf8)
        sigBlob.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        sigBlob.append(rawSig)
        let sigText = """
        untrusted comment: signature
        \(sigBlob.base64EncodedString())
        trusted comment: x
        \(Data(repeating: 0, count: 64).base64EncodedString())
        """

        let updater = try WindowsUpdater(
            endpoint: manifestURL,
            publicKey: pubText,
            installMode: .portable
        )
        try updater.verifyEd25519(data: payload, signature: sigText)
    }

    // MARK: - Entry point

    // MARK: - image.* (WIC)

    //
    // The Windows half of the `image.*` plugin. These exercise the real WIC
    // codec, so they are the only place its decode/encode path runs at all —
    // the swift-testing suites that cover it elsewhere cannot run on Windows.

    /// A tiny PNG, built by hand so the runner needs no fixture file.
    func makeTestPNG(width: Int, height: Int) -> Data {
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var table = [UInt32](repeating: 0, count: 256)
            for i in 0 ..< 256 {
                var c = UInt32(i)
                for _ in 0 ..< 8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
                table[i] = c
            }
            var c: UInt32 = 0xFFFF_FFFF
            for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            return c ^ 0xFFFF_FFFF
        }
        func chunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
            var out = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { [UInt8]($0) }
            let body = [UInt8](tag.utf8) + payload
            out += body
            out += withUnsafeBytes(of: crc32(body).bigEndian) { [UInt8]($0) }
            return out
        }
        var raw: [UInt8] = []
        for y in 0 ..< height {
            raw.append(0)
            for x in 0 ..< width {
                raw.append(UInt8((x * 255) / max(width - 1, 1)))
                raw.append(UInt8((y * 255) / max(height - 1, 1)))
                raw.append(120)
            }
        }
        var deflated: [UInt8] = [0x78, 0x01]
        var offset = 0
        while offset < raw.count {
            let size = min(65535, raw.count - offset)
            deflated.append(offset + size >= raw.count ? 1 : 0)
            deflated.append(UInt8(size & 0xFF))
            deflated.append(UInt8((size >> 8) & 0xFF))
            deflated.append(UInt8(~size & 0xFF))
            deflated.append(UInt8((~size >> 8) & 0xFF))
            deflated += raw[offset ..< offset + size]
            offset += size
        }
        var s1: UInt32 = 1, s2: UInt32 = 0
        for b in raw {
            s1 = (s1 + UInt32(b)) % 65521
            s2 = (s2 + s1) % 65521
        }
        deflated += withUnsafeBytes(of: ((s2 << 16) | s1).bigEndian) { [UInt8]($0) }
        var ihdr = withUnsafeBytes(of: UInt32(width).bigEndian) { [UInt8]($0) }
        ihdr += withUnsafeBytes(of: UInt32(height).bigEndian) { [UInt8]($0) }
        ihdr += [8, 2, 0, 0, 0]
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + chunk("IHDR", ihdr) + chunk("IDAT", deflated) + chunk("IEND", []))
    }

    func wicReportsRegisteredDecoders() async throws {
        let caps = await PlatformImageTranscoder().capabilities()
        // WIC always ships PNG/JPEG decoders; anything beyond that is a
        // property of the machine and deliberately not asserted.
        try expect(caps.decode.contains("png"), "expected png in \(caps.decode)")
        try expect(
            caps.decode.contains("jpg") || caps.decode.contains("jpeg"),
            "expected jpeg in \(caps.decode)"
        )
        try expect(caps.encode.contains("png"), "expected png encode")
        try expect(caps.encode.contains("jpeg"), "expected jpeg encode")
        print("      WIC decodes: \(caps.decode.joined(separator: ","))")
    }

    func wicRoundTripsPNG() async throws {
        let png = makeTestPNG(width: 40, height: 24)
        let result = try await PlatformImageTranscoder().transcode(
            ImageTranscodeRequest(dataBase64: png.base64EncodedString(), format: .png)
        )
        try expect(result.width == 40, "expected width 40, got \(result.width)")
        try expect(result.height == 24, "expected height 24, got \(result.height)")
        try expect(result.bytes > 0, "expected bytes")
        try expect(result.dataBase64 != nil, "expected inline data")
    }

    func wicEncodesJPEGDistinctFromPNG() async throws {
        let png = makeTestPNG(width: 96, height: 96)
        let transcoder = PlatformImageTranscoder()
        let asPNG = try await transcoder.transcode(
            ImageTranscodeRequest(dataBase64: png.base64EncodedString(), format: .png)
        )
        let asJPEG = try await transcoder.transcode(
            ImageTranscodeRequest(dataBase64: png.base64EncodedString(), format: .jpeg, quality: 0.6)
        )
        try expect(asJPEG.bytes > 0, "expected jpeg bytes")
        // Different bytes is the point: it proves `format` reached the encoder
        // rather than being dropped and writing PNG twice.
        try expect(asJPEG.bytes != asPNG.bytes, "jpeg and png byte counts were identical")
    }

    func wicScalesDuringDecode() async throws {
        let png = makeTestPNG(width: 200, height: 100)
        let result = try await PlatformImageTranscoder().transcode(
            ImageTranscodeRequest(dataBase64: png.base64EncodedString(), format: .png, maxSide: 50)
        )
        try expect(result.width == 50, "expected width 50, got \(result.width)")
        try expect(result.height == 25, "expected height 25, got \(result.height)")
    }

    func wicRejectsNonImageData() async throws {
        do {
            _ = try await PlatformImageTranscoder().transcode(
                ImageTranscodeRequest(dataBase64: Data([1, 2, 3, 4]).base64EncodedString(), format: .png)
            )
            throw TestFailure(message: "expected a decode failure for non-image bytes")
        } catch is ImageTranscodeError {
            // Expected — and importantly it is an error, not a crash: a C++
            // exception crossing the shim's C ABI would take the process down.
        }
    }

    let cases: [(String, () async throws -> Void)] = [
        ("installAndRelaunch errors when no update has been staged", installAndRelaunchWithoutStagedUpdate),
        ("currentExecutablePath honours the explicit override", currentExecutablePathOverride),
        ("verifyEd25519 accepts a signature produced by the corresponding private key", verifyEd25519HappyPath),
        ("verifyEd25519 rejects a signature from a different key", verifyEd25519WrongKey),
        ("verifyEd25519 rejects a missing public key with a helpful message", verifyEd25519NoKey),
        ("verifyEd25519 rejects a malformed signature", verifyEd25519MalformedSignature),
        ("MSIX without public key skips verification (trusts Authenticode chain)", msixSkipVerifyWithoutKey),
        ("MSIX with public key still verifies the signature", msixVerifiesWhenKeySet),
        ("Portable mode requires a configured public key", portableRequiresKey),
        ("MSIX identity defaults to nil when not supplied", msixIdentityDefaultsNil),
        ("MSIX identity round-trips through the constructor", msixIdentityRoundtrip),
        ("verifyEd25519 accepts minisign-format inputs", verifyEd25519MinisignInputs),
        ("WIC reports the decoders registered on this machine", wicReportsRegisteredDecoders),
        ("image.transcode round-trips a PNG through WIC", wicRoundTripsPNG),
        ("WIC JPEG output differs from PNG (format is not dropped)", wicEncodesJPEGDistinctFromPNG),
        ("WIC scales during decode when maxSide is set", wicScalesDuringDecode),
        ("non-image bytes fail as an error rather than a crash", wicRejectsNonImageData)
    ]

    var passed = 0
    var failed: [(String, String)] = []
    for (name, fn) in cases {
        do {
            try await fn()
            passed += 1
            print("PASS  \(name)")
        } catch {
            failed.append((name, "\(error)"))
            print("FAIL  \(name) — \(error)")
        }
    }
    print("---")
    print("\(passed) passed, \(failed.count) failed (of \(cases.count))")
    if !failed.isEmpty {
        for (name, err) in failed { print("  ✗ \(name): \(err)") }
        exit(1)
    }
#else
    // Non-Windows: this target is gated by `.when(platforms: [.windows])` on
    // its real dependencies and produces a no-op binary elsewhere. Building
    // (but never running) it on macOS keeps the Package.swift simple.
    print("SwiftPWAWindowsTestRunner is Windows-only; nothing to do.")
#endif
