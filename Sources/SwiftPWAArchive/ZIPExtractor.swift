import Foundation
import SwiftPWACore

#if os(Windows)

    /// Windows `ArchiveExtractor` backed by `tar.exe` — libarchive's bsdtar,
    /// shipped in Windows 10 1803+ — because ZIPFoundation doesn't build under
    /// clang-cl (its `CZLib` shim uses `#import <zlib.h>`, which clang-cl
    /// rejects, and Windows ships no system zlib). Same `ZIPExtractor` name as
    /// the other platforms so app code stays cross-platform.
    ///
    /// `tar` won't enforce *our* guards, so extraction does a pre-extract
    /// listing pass (`tar -tvf`) to reject path-traversal / symlink entries
    /// and trip the zip-bomb limits **before** unpacking, then extracts into a
    /// staging dir and commits on success — identical contract to the
    /// ZIPFoundation path.
    public struct ZIPExtractor: ArchiveExtractor {
        public init() {}

        public func list(zipAt url: URL) throws -> [ArchiveEntry] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ArchiveError.notReadable(path: url.path)
            }
            return try BSDTarListParser.parse(Self.runTar(["-tvf", url.path]))
        }

        @discardableResult
        public func extract(
            zipAt url: URL,
            to destination: URL,
            limits: ExtractLimits,
            onProgress: (@Sendable (ExtractProgress) -> Void)?
        ) throws -> ExtractResult {
            let entries = try list(zipAt: url)

            // Enforce every guard from the listing *before* we let tar write a
            // single byte — a malicious archive never reaches the extract call.
            var totalBytes: Int64 = 0
            var count = 0
            for entry in entries {
                count += 1
                if let max = limits.maxEntries, count > max {
                    throw ArchiveError.tooManyEntries(limit: max)
                }
                if entry.isSymlink {
                    throw ArchiveError.symlinkRejected(entry: entry.path)
                }
                if ArchiveSafety.resolveDestination(entry: entry.path, within: destination) == nil {
                    throw ArchiveError.pathTraversal(entry: entry.path)
                }
                totalBytes += entry.uncompressedSize
                if let maxBytes = limits.maxUncompressedBytes, totalBytes > maxBytes {
                    throw ArchiveError.uncompressedTooLarge(limit: maxBytes)
                }
                // Per-entry compression ratio is unavailable from bsdtar's
                // listing (no compressed size), so the ratio guard degrades to
                // the size/entry-count guards on Windows.
            }

            let fm = FileManager.default
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".swift-pwa-extract-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var cleanup = true
            defer { if cleanup { try? fm.removeItem(at: staging) } }

            _ = try Self.runTar(["-xf", url.path, "-C", staging.path])
            onProgress?(ExtractProgress(entriesDone: count, bytesDone: totalBytes, totalEntries: entries.count))

            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
                let target = destination.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: item, to: target)
            }
            cleanup = true
            return ExtractResult(entries: count, uncompressedBytes: totalBytes)
        }

        /// Run `tar.exe` with `args`, returning stdout. Resolves the binary
        /// under `%SystemRoot%\System32` (where Windows ships bsdtar).
        private static func runTar(_ args: [String]) throws -> String {
            let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
            let tarPath = systemRoot + "\\System32\\tar.exe"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tarPath)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                throw ArchiveError.unsupportedPlatform("tar.exe not available at \(tarPath): \(error)")
            }
            // Read stdout to EOF before waiting (deadlock-safe for the
            // listing-heavy `-tvf`); stderr is small and read only on failure.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let err = String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? ""
                throw ArchiveError.corrupt("tar exited \(proc.terminationStatus): \(err)")
            }
            return String(data: outData, encoding: .utf8) ?? ""
        }
    }

#else

    import ZIPFoundation

    /// ZIPFoundation-backed `ArchiveExtractor`. Lives in its own target so the
    /// ZIPFoundation dependency is linked only by apps that opt into
    /// content-pack import:
    ///
    /// ```swift
    /// import SwiftPWA
    /// import SwiftPWAArchive
    ///
    /// ctx.use(FsPlugin(SystemFs(extractor: ZIPExtractor())))
    /// ```
    ///
    /// Bytes are read from the archive and written to disk entry-by-entry by
    /// ZIPFoundation — they never cross the JS↔Swift bridge, which is the
    /// whole point versus an `fs.readBinary` + JS-side unzip (a GB of video
    /// would otherwise become a ~1.33 GB base64 string per file).
    public struct ZIPExtractor: ArchiveExtractor {
        public init() {}

        public func list(zipAt url: URL) throws -> [ArchiveEntry] {
            let archive = try openArchive(url)
            return archive.map(Self.entry(from:))
        }

        @discardableResult
        public func extract(
            zipAt url: URL,
            to destination: URL,
            limits: ExtractLimits,
            onProgress: (@Sendable (ExtractProgress) -> Void)?
        ) throws -> ExtractResult {
            let archive = try openArchive(url)
            let fm = FileManager.default
            // The central directory is cheap to enumerate (metadata only), so
            // total-entry count is known up front for progress reporting even
            // for a multi-GB archive.
            let totalEntries = archive.reduce(into: 0) { acc, _ in acc += 1 }

            // Extract into a temp sibling, then move into place, so an aborted
            // or failed extract never leaves a half-populated destination the
            // app might serve. Clean up the temp on any throw.
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".swift-pwa-extract-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var cleanup = true
            defer { if cleanup { try? fm.removeItem(at: staging) } }

            var totalBytes: Int64 = 0
            var count = 0
            for entry in archive {
                count += 1
                if let max = limits.maxEntries, count > max {
                    throw ArchiveError.tooManyEntries(limit: max)
                }
                // Symlinks can point outside the destination — reject outright.
                if entry.type == .symlink {
                    throw ArchiveError.symlinkRejected(entry: entry.path)
                }
                guard let dest = ArchiveSafety.resolveDestination(entry: entry.path, within: staging) else {
                    throw ArchiveError.pathTraversal(entry: entry.path)
                }
                let uncompressed = Int64(entry.uncompressedSize)
                let compressed = Int64(entry.compressedSize)
                if let maxRatio = limits.maxCompressionRatio, compressed > 0 {
                    let ratio = Double(uncompressed) / Double(compressed)
                    if ratio > maxRatio {
                        throw ArchiveError.compressionRatioExceeded(entry: entry.path, ratio: ratio, limit: maxRatio)
                    }
                }
                totalBytes += uncompressed
                if let maxBytes = limits.maxUncompressedBytes, totalBytes > maxBytes {
                    throw ArchiveError.uncompressedTooLarge(limit: maxBytes)
                }

                if entry.type == .directory {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    do {
                        _ = try archive.extract(entry, to: dest)
                    } catch {
                        throw ArchiveError.corrupt("failed to extract \(entry.path): \(error)")
                    }
                }
                onProgress?(ExtractProgress(entriesDone: count, bytesDone: totalBytes, totalEntries: totalEntries))
            }

            // Commit: move staged contents into the real destination.
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
                let target = destination.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: item, to: target)
            }
            cleanup = true // staging is now empty; defer removes the husk
            return ExtractResult(entries: count, uncompressedBytes: totalBytes)
        }

        // MARK: - Helpers

        private func openArchive(_ url: URL) throws -> Archive {
            do {
                return try Archive(url: url, accessMode: .read)
            } catch {
                throw ArchiveError.notReadable(path: url.path)
            }
        }

        private static func entry(from entry: Entry) -> ArchiveEntry {
            ArchiveEntry(
                path: entry.path,
                isDirectory: entry.type == .directory,
                isSymlink: entry.type == .symlink,
                uncompressedSize: Int64(entry.uncompressedSize),
                compressedSize: Int64(entry.compressedSize)
            )
        }
    }

#endif
