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

        public func list(zipAt url: URL) async throws -> [ArchiveEntry] {
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
        ) async throws -> ExtractResult {
            let entries = try await list(zipAt: url)

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

        @discardableResult
        public func create(
            zipAt destination: URL,
            from source: URL,
            compression: ZipCompression,
            onProgress: (@Sendable (CreateProgress) -> Void)?
        ) async throws -> CreateResult {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
                throw ArchiveError.notReadable(path: source.path)
            }
            // bsdtar doesn't print a clean machine-readable summary, so walk the
            // tree ourselves for the entry count / uncompressed total.
            let items = try ArchiveSourceWalk.walk(source: source)
            let totalBytes = items.reduce(Int64(0)) { $0 + $1.size }

            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".swift-pwa-create-\(UUID().uuidString).zip")
            var cleanup = true
            defer { if cleanup { try? fm.removeItem(at: staging) } }

            // libarchive's zip writer: `store` (no deflate) or `deflate`.
            let comp = compression == .deflate ? "deflate" : "store"
            _ = try Self.runTar([
                "--format", "zip",
                "--options", "zip:compression=\(comp)",
                "-cf", staging.path,
                "-C", source.path, "."
            ])
            onProgress?(CreateProgress(entriesDone: items.count, bytesDone: totalBytes, totalEntries: items.count))

            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
            cleanup = false
            return CreateResult(entries: items.count, uncompressedBytes: totalBytes)
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

#elseif os(Android)

    /// Android stub. ZIPFoundation can't build against Bionic libc (`lstat`,
    /// `errno`, `S_IF*`, `mode_t` mismatches), so apps on Android use
    /// `AndroidArchiveExtractor` (from `SwiftPWAAndroid`, routing to Kotlin's
    /// `java.util.zip` over JNI) instead of this type. This stub keeps
    /// `SwiftPWAArchive` compilable if ever pulled into an Android target.
    public struct ZIPExtractor: ArchiveExtractor {
        public init() {}

        public func list(zipAt _: URL) async throws -> [ArchiveEntry] {
            throw ArchiveError.unsupportedPlatform(
                "ZIPExtractor isn't available on Android — use AndroidArchiveExtractor (SwiftPWAAndroid)"
            )
        }

        @discardableResult
        public func extract(
            zipAt _: URL,
            to _: URL,
            limits _: ExtractLimits,
            onProgress _: (@Sendable (ExtractProgress) -> Void)?
        ) async throws -> ExtractResult {
            throw ArchiveError.unsupportedPlatform(
                "ZIPExtractor isn't available on Android — use AndroidArchiveExtractor (SwiftPWAAndroid)"
            )
        }

        @discardableResult
        public func create(
            zipAt _: URL,
            from _: URL,
            compression _: ZipCompression,
            onProgress _: (@Sendable (CreateProgress) -> Void)?
        ) async throws -> CreateResult {
            throw ArchiveError.unsupportedPlatform(
                "ZIPExtractor isn't available on Android — use AndroidArchiveExtractor (SwiftPWAAndroid)"
            )
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

        public func list(zipAt url: URL) async throws -> [ArchiveEntry] {
            let archive = try openArchive(url)
            return archive.map(Self.entry(from:))
        }

        @discardableResult
        public func extract(
            zipAt url: URL,
            to destination: URL,
            limits: ExtractLimits,
            onProgress: (@Sendable (ExtractProgress) -> Void)?
        ) async throws -> ExtractResult {
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

        @discardableResult
        public func create(
            zipAt destination: URL,
            from source: URL,
            compression: ZipCompression,
            onProgress: (@Sendable (CreateProgress) -> Void)?
        ) async throws -> CreateResult {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
                throw ArchiveError.notReadable(path: source.path)
            }

            // Walk the tree up front so totalEntries is known for progress.
            let items = try ArchiveSourceWalk.walk(source: source)
            let method: CompressionMethod = compression == .deflate ? .deflate : .none

            // Build into a temp sibling, then move into place, so a failed
            // create never leaves a half-written .zip at `destination`.
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".swift-pwa-create-\(UUID().uuidString).zip")
            var cleanup = true
            defer { if cleanup { try? fm.removeItem(at: staging) } }

            let archive: Archive
            do {
                archive = try Archive(url: staging, accessMode: .create)
            } catch {
                throw ArchiveError.notReadable(path: staging.path)
            }

            var totalBytes: Int64 = 0
            var count = 0
            for item in items {
                do {
                    // ZIPFoundation streams the file through a provider — bytes
                    // go disk→archive without a full in-memory copy.
                    try archive.addEntry(with: item.relativePath, relativeTo: source, compressionMethod: method)
                } catch {
                    throw ArchiveError.corrupt("failed to add \(item.relativePath): \(error)")
                }
                count += 1
                totalBytes += item.size
                onProgress?(CreateProgress(entriesDone: count, bytesDone: totalBytes, totalEntries: items.count))
            }

            // Commit: replace any existing file at the destination atomically.
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
            cleanup = false
            return CreateResult(entries: count, uncompressedBytes: totalBytes)
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

/// Source-tree walk shared by the `create` paths (ZIPFoundation on
/// Apple/Linux, `tar.exe` on Windows). Compiled on every platform — it
/// only touches Foundation. Returns each regular file and directory as a
/// path relative to `source`, in a deterministic order, **skipping
/// symlinks** (not followed, not stored) so an exported pack can't smuggle
/// a link out of the tree.
enum ArchiveSourceWalk {
    struct Item: Equatable {
        let relativePath: String
        let isDirectory: Bool
        let size: Int64
    }

    static func walk(source: URL) throws -> [Item] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: source, includingPropertiesForKeys: keys, options: []
        ) else {
            throw ArchiveError.notReadable(path: source.path)
        }
        let basePath = source.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        var items: [Item] = []
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: Set(keys))
            if vals?.isSymbolicLink == true {
                enumerator.skipDescendants() // don't recurse a symlinked dir
                continue // skip symlink entries entirely
            }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(basePrefix) else { continue }
            let rel = String(full.dropFirst(basePrefix.count))
            if rel.isEmpty { continue }
            let isDir = vals?.isDirectory == true
            let size = isDir ? 0 : Int64(vals?.fileSize ?? 0)
            items.append(Item(relativePath: rel, isDirectory: isDir, size: size))
        }
        // Deterministic order (enumerator order varies by platform); parents
        // sort before their children lexicographically.
        return items.sorted { $0.relativePath < $1.relativePath }
    }
}
