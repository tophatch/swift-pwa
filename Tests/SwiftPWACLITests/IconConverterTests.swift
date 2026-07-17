#if os(macOS)
    import Foundation
    @testable import SwiftPWACLISupport
    import Testing

    /// The `.icns` builder shells out to `sips` + `iconutil`, so these run only
    /// on macOS (where those ship). They pin the content-hash cache: an
    /// unchanged icon on a rebuild must reuse the cached `.icns` rather than
    /// re-running the ~14-spawn pipeline.
    @Suite("IconConverter — .icns cache")
    struct IconConverterTests {
        /// A 1×1 transparent PNG — valid input; `sips` upscales it to each size.
        private var onePixelPNG: Data {
            Data([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
                0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
                0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
                0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                0x42, 0x60, 0x82
            ])
        }

        @Test("a rebuild with an unchanged icon reuses the cache instead of re-running sips/iconutil")
        func cacheReuse() async throws {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swiftpwa-icontest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let png = tmp.appendingPathComponent("icon.png")
            try onePixelPNG.write(to: png)
            let cacheDir = tmp.appendingPathComponent("cache")

            // First build: real sips/iconutil, populates the cache.
            let n = try await IconConverter.makeICNS(
                from: png, into: tmp.appendingPathComponent("A.icns"), cacheDir: cacheDir
            )
            #expect(n == 7) // 16/32/64/128/256/512/1024
            let files = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
            let cached = try #require(files.first { $0.pathExtension == "icns" })

            // Overwrite the cache with a sentinel. A cache *hit* copies it
            // verbatim; a regeneration would clobber it with a real .icns.
            try Data("SENTINEL".utf8).write(to: cached)
            let out = tmp.appendingPathComponent("B.icns")
            _ = try await IconConverter.makeICNS(from: png, into: out, cacheDir: cacheDir)
            #expect(try String(contentsOf: out, encoding: .utf8) == "SENTINEL")
        }

        @Test("no cacheDir → generates a real .icns every time (no caching)")
        func noCacheStillWorks() async throws {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swiftpwa-icontest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let png = tmp.appendingPathComponent("icon.png")
            try onePixelPNG.write(to: png)
            let out = tmp.appendingPathComponent("AppIcon.icns")
            let n = try await IconConverter.makeICNS(from: png, into: out, cacheDir: nil)
            #expect(n == 7)
            #expect(FileManager.default.fileExists(atPath: out.path))
            // A real .icns starts with the "icns" magic, not our sentinel.
            let head = try FileHandle(forReadingFrom: out).readData(ofLength: 4)
            #expect(String(decoding: head, as: UTF8.self) == "icns")
        }
    }
#endif
