// The Windows `ZIPExtractor` shells to `tar.exe` (libarchive bsdtar) and
// parses its verbose listing. The `Process` call is Windows-only, but the
// parser is host-agnostic — and macOS/Linux `tar` IS the same bsdtar, so we
// test the parser both against hardcoded sample lines and real `tar` output.
#if !os(Windows)

    import Foundation
    @testable import SwiftPWAArchive
    import SwiftPWACore
    import Testing

    @Suite("BSDTarListParser")
    struct BSDTarListParserTests {
        @Test("parses regular file, directory, and symlink lines")
        func parseLines() {
            let sample = """
            -rw-r--r--  0 501    20         12 Jun 25 10:00 manifest.json
            drwxr-xr-x  0 501    20          0 Jun 25 10:00 media/
            -rw-r--r--  0 501    20       1048 Jun 25 10:00 media/clip name.webm
            lrwxrwxrwx  0 501    20          6 Jun 25 10:00 link -> media/
            """
            let entries = BSDTarListParser.parse(sample)
            #expect(entries.count == 4)

            let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
            #expect(byPath["manifest.json"]?.isDirectory == false)
            #expect(byPath["manifest.json"]?.uncompressedSize == 12)
            #expect(byPath["media"]?.isDirectory == true) // trailing slash stripped
            // A name with an embedded space survives.
            #expect(byPath["media/clip name.webm"]?.uncompressedSize == 1048)
            // Symlink: flagged, target stripped.
            #expect(byPath["link"]?.isSymlink == true)
        }

        @Test("ignores blank and malformed lines")
        func ignoresJunk() {
            let entries = BSDTarListParser.parse("\n   \nnot a tar line\n")
            #expect(entries.isEmpty)
        }

        @Test("parses real `tar -tvf` output for a zip")
        func realTar() throws {
            let tar = ["/usr/bin/tar", "/bin/tar", "/usr/local/bin/tar"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let tar else { return } // no tar on this host — skip

            // Build a small zip via `zip`-less path: stage files, then `tar`
            // can create a zip with `--format zip` (bsdtar supports it).
            let work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-bsdtar-\(UUID().uuidString)")
            let src = work.appendingPathComponent("src")
            try FileManager.default.createDirectory(
                at: src.appendingPathComponent("media"), withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: work) }
            try "{}".write(to: src.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try String(repeating: "x", count: 100)
                .write(to: src.appendingPathComponent("media/clip.txt"), atomically: true, encoding: .utf8)

            let zip = work.appendingPathComponent("pack.zip")
            try runProcess(tar, ["--format", "zip", "-cf", zip.path, "-C", src.path, "."])
            let listing = try captureProcess(tar, ["-tvf", zip.path])

            let entries = BSDTarListParser.parse(listing)
            let names = Set(entries.map(\.path))
            // bsdtar lists with a leading "./"; accept either form.
            #expect(names.contains { $0.hasSuffix("manifest.json") })
            #expect(names.contains { $0.hasSuffix("media/clip.txt") })
            // The clip's uncompressed size is reported.
            let clip = entries.first { $0.path.hasSuffix("media/clip.txt") }
            #expect(clip?.uncompressedSize == 100)
        }

        // MARK: - Process helpers (test-only)

        private func runProcess(_ exe: String, _ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }

        private func captureProcess(_ exe: String, _ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

#endif
