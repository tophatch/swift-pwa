import Foundation
import SwiftPWACore

#if os(Windows)

    /// Windows stub. ZIPFoundation doesn't build under clang-cl (its
    /// `CZLib` shim uses `#import <zlib.h>`, which MSVC/clang-cl reject,
    /// and Windows ships no system zlib), so the real extractor is gated
    /// off Windows in `Package.swift`. This placeholder keeps cross-
    /// platform app code compiling; both methods throw
    /// `ArchiveError.unsupportedPlatform`. A Windows-native extractor
    /// (e.g. bundled `tar.exe`) is a tracked follow-up.
    public struct ZIPExtractor: ArchiveExtractor {
        public init() {}

        public func list(zipAt _: URL) throws -> [ArchiveEntry] {
            throw ArchiveError.unsupportedPlatform("fs.extractZip is not yet available on Windows")
        }

        @discardableResult
        public func extract(
            zipAt _: URL,
            to _: URL,
            limits _: ExtractLimits,
            onProgress _: (@Sendable (ExtractProgress) -> Void)?
        ) throws -> ExtractResult {
            throw ArchiveError.unsupportedPlatform("fs.extractZip is not yet available on Windows")
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
