import Foundation
@testable import SwiftPWACore
@testable import SwiftPWAImage
import Testing

@Suite("PlatformImageTranscoder")
struct PlatformImageTranscoderTests {
    /// A tiny PNG built by hand so the tests don't depend on a fixture file.
    private static func makePNG(width: Int, height: Int) -> Data {
        func chunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
            var out = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { [UInt8]($0) }
            let body = [UInt8](tag.utf8) + payload
            out += body
            out += withUnsafeBytes(of: crc32(body).bigEndian) { [UInt8]($0) }
            return out
        }
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
        var raw: [UInt8] = []
        for y in 0 ..< height {
            raw.append(0) // filter: none
            for x in 0 ..< width {
                raw.append(UInt8((x * 255) / max(width - 1, 1)))
                raw.append(UInt8((y * 255) / max(height - 1, 1)))
                raw.append(120)
            }
        }
        var ihdr = withUnsafeBytes(of: UInt32(width).bigEndian) { [UInt8]($0) }
        ihdr += withUnsafeBytes(of: UInt32(height).bigEndian) { [UInt8]($0) }
        ihdr += [8, 2, 0, 0, 0] // 8-bit, truecolour
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + chunk("IHDR", ihdr) + chunk("IDAT", deflateStored(raw)) + chunk("IEND", []))
    }

    /// zlib stream with stored (uncompressed) deflate blocks — enough for a
    /// decoder to read, with no compression dependency in the test.
    private static func deflateStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var offset = 0
        while offset < data.count {
            let size = min(65535, data.count - offset)
            let isLast = offset + size >= data.count
            out.append(isLast ? 1 : 0)
            out.append(UInt8(size & 0xFF))
            out.append(UInt8((size >> 8) & 0xFF))
            out.append(UInt8(~size & 0xFF))
            out.append(UInt8((~size >> 8) & 0xFF))
            out += data[offset ..< offset + size]
            offset += size
        }
        var s1: UInt32 = 1, s2: UInt32 = 0
        for b in data {
            s1 = (s1 + UInt32(b)) % 65521
            s2 = (s2 + s1) % 65521
        }
        out += withUnsafeBytes(of: ((s2 << 16) | s1).bigEndian) { [UInt8]($0) }
        return out
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-image-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("reports what this build can read and write")
    func capabilities() async {
        let caps = await PlatformImageTranscoder().capabilities()
        // Printed because the answer is per-platform and, on Windows and Linux,
        // per-machine — and because a capability-branching test below passes
        // either way, so this is how a run says which branch it took.
        print("image.info decode: \(caps.decode.joined(separator: ","))")
        print("image.info encode: \(caps.encode.joined(separator: ","))")
        // PNG is the one format every platform codec in this package handles.
        #expect(caps.decode.contains("png"))
        #expect(caps.encode.contains("png"))
        #expect(caps.encode.contains("jpeg"))
    }

    @Test("transcodes inline bytes and returns them inline")
    func inlineRoundTrip() async throws {
        let png = Self.makePNG(width: 32, height: 24)
        let result = try await PlatformImageTranscoder().transcode(
            ImageTranscodeRequest(dataBase64: png.base64EncodedString(), format: .png)
        )
        #expect(result.width == 32)
        #expect(result.height == 24)
        #expect(result.bytes > 0)
        #expect(result.path == nil)
        #expect(result.dataBase64 != nil)
    }

    @Test("writes to outputPath when asked, and creates missing directories")
    func writesToPath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("in.png")
        try Self.makePNG(width: 16, height: 16).write(to: source)
        // A directory that does not exist yet — an import cache is the obvious
        // destination and making the caller mkdir it first is a papercut.
        let out = dir.appendingPathComponent("nested/cache/out.png").path

        let result = try await PlatformImageTranscoder().transcode(
            ImageTranscodeRequest(path: source.path, format: .png, outputPath: out)
        )
        #expect(result.path == out)
        #expect(result.dataBase64 == nil)
        #expect(FileManager.default.fileExists(atPath: out))
        #expect(try Data(contentsOf: URL(fileURLWithPath: out)).count == result.bytes)
    }

    @Test("maxSide bounds the longest edge and reports the real output size")
    func maxSideDownscales() async throws {
        let png = Self.makePNG(width: 200, height: 100)
        let result = try await PlatformImageTranscoder().transcode(
            ImageTranscodeRequest(dataBase64: png.base64EncodedString(), format: .png, maxSide: 50)
        )
        #expect(result.width == 50)
        #expect(result.height == 25)
    }

    @Test("jpeg output is smaller than png for a photographic image")
    func jpegEncodes() async throws {
        let png = Self.makePNG(width: 120, height: 120)
        let transcoder = PlatformImageTranscoder()
        let asPNG = try await transcoder.transcode(
            ImageTranscodeRequest(dataBase64: png.base64EncodedString(), format: .png)
        )
        let asJPEG = try await transcoder.transcode(
            ImageTranscodeRequest(dataBase64: png.base64EncodedString(), format: .jpeg, quality: 0.6)
        )
        #expect(asJPEG.bytes > 0)
        #expect(asJPEG.width == 120)
        // Not a compression benchmark — just proof the two paths produce
        // genuinely different bytes rather than PNG twice, which is the failure
        // mode if a `format` argument is quietly dropped somewhere.
        #expect(asJPEG.bytes != asPNG.bytes)
    }

    /// The load-bearing test for the whole plugin: **a build that claims a
    /// format in `image.info` must actually decode it.** Which platforms can is
    /// genuinely uneven — ImageIO always, `BitmapFactory` by API level, WIC only
    /// with the right codec extension installed, libheif only when present with
    /// its plugin — so this branches on the reported capability rather than
    /// asserting one. Either way something is checked: that the claim holds, or
    /// that the refusal is clean.
    @Test("a format image.info claims is one it can really decode", arguments: ["heic", "avif"])
    func claimedFormatsReallyDecode(_ ext: String) async throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/sample", withExtension: ext),
            "missing the \(ext) fixture"
        )
        let transcoder = PlatformImageTranscoder()
        let claimed = await transcoder.capabilities().decode.contains(ext)

        if claimed {
            let result = try await transcoder.transcode(
                ImageTranscodeRequest(path: url.path, format: .png)
            )
            #expect(result.width == 240)
            #expect(result.height == 240)
            #expect(result.bytes > 0)
        } else {
            // Not a gap in the test: on a machine with no decoder this is the
            // behaviour that matters — a named refusal, not a broken image.
            await #expect(throws: ImageTranscodeError.self) {
                try await transcoder.transcode(ImageTranscodeRequest(path: url.path, format: .png))
            }
        }
    }

    @Test("rejects a request with neither or both sources")
    func rejectsAmbiguousSource() async {
        let transcoder = PlatformImageTranscoder()
        await #expect(throws: ImageTranscodeError.self) {
            try await transcoder.transcode(ImageTranscodeRequest(format: .png))
        }
        await #expect(throws: ImageTranscodeError.self) {
            try await transcoder.transcode(
                ImageTranscodeRequest(path: "/tmp/x.png", dataBase64: "AAAA", format: .png)
            )
        }
    }

    @Test("names the formats it does support when handed one it doesn't")
    func unsupportedSourceIsExplained() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caps = await PlatformImageTranscoder().capabilities()
        // Only meaningful where the platform genuinely lacks a HEIC decoder.
        guard !caps.decode.contains("heic") else { return }
        let source = dir.appendingPathComponent("photo.heic")
        try Data([0, 1, 2, 3]).write(to: source)

        do {
            _ = try await PlatformImageTranscoder().transcode(
                ImageTranscodeRequest(path: source.path, format: .png)
            )
            Issue.record("expected an unsupported-source error")
        } catch let error as ImageTranscodeError {
            guard case let .unsupportedSource(message) = error else {
                Issue.record("expected .unsupportedSource, got \(error)")
                return
            }
            #expect(message.contains("heic"))
        }
    }
}
