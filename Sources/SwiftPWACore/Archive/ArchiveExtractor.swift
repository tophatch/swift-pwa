import Foundation

/// A zip-extraction backend. Defined in Core (dependency-free) so
/// `FsPlugin` / `SystemFs` can offer `fs.extractZip` without `SwiftPWACore`
/// taking on a third-party zip dependency: the concrete implementation
/// (`ZIPExtractor`, backed by ZIPFoundation) lives in the optional
/// `SwiftPWAArchive` target and is injected by apps that import content
/// packs — `ctx.use(FsPlugin(SystemFs(extractor: ZIPExtractor())))`.
///
/// Implementations MUST enforce the security guards the content-pack use
/// case depends on, since the input is untrusted file data:
/// - **Path traversal** — every entry must land inside the destination;
///   reject `../`, absolute paths, and anything that escapes (use
///   `ArchiveSafety.resolveDestination`).
/// - **Symlinks** — reject symlink entries (they can point outside the
///   destination, defeating the traversal check).
/// - **Zip bombs** — honor `ExtractLimits` (total uncompressed bytes,
///   entry count, per-entry compression ratio) and fail rather than fill
///   the disk; clean up partial output on failure.
public protocol ArchiveExtractor: Sendable {
    /// List a zip's entries without extracting — lets a caller validate a
    /// manifest entry (e.g. read `pack.json`'s presence/size) before
    /// committing to a multi-GB extract.
    func list(zipAt url: URL) throws -> [ArchiveEntry]

    /// Extract every entry into `destination` (created if absent),
    /// enforcing `limits`. Returns a summary. Throws `ArchiveError` on a
    /// guard violation or a corrupt archive, leaving no partial output.
    @discardableResult
    func extract(zipAt url: URL, to destination: URL, limits: ExtractLimits) throws -> ExtractResult
}

/// One entry in a zip's central directory.
public struct ArchiveEntry: Sendable, Equatable {
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let uncompressedSize: Int64
    public let compressedSize: Int64

    public init(
        path: String,
        isDirectory: Bool,
        isSymlink: Bool,
        uncompressedSize: Int64,
        compressedSize: Int64
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
    }
}

/// Zip-bomb guards. All optional; `nil` means "no limit for this axis".
/// `.default` is generous-but-finite so a careless caller still can't fill
/// the disk from an untrusted archive.
public struct ExtractLimits: Sendable, Equatable {
    /// Abort once the running uncompressed total would exceed this.
    public var maxUncompressedBytes: Int64?
    /// Abort once the entry count would exceed this.
    public var maxEntries: Int?
    /// Abort if any entry's uncompressed/compressed ratio exceeds this.
    public var maxCompressionRatio: Double?

    public init(
        maxUncompressedBytes: Int64? = nil,
        maxEntries: Int? = nil,
        maxCompressionRatio: Double? = nil
    ) {
        self.maxUncompressedBytes = maxUncompressedBytes
        self.maxEntries = maxEntries
        self.maxCompressionRatio = maxCompressionRatio
    }

    /// No limits (callers that have already validated the archive).
    public static let unbounded = ExtractLimits()

    /// Generous defaults for untrusted input: 8 GiB total, 50k entries,
    /// 200:1 per-entry ratio.
    public static let `default` = ExtractLimits(
        maxUncompressedBytes: 8 * 1024 * 1024 * 1024,
        maxEntries: 50000,
        maxCompressionRatio: 200
    )
}

/// Summary of a completed extraction.
public struct ExtractResult: Sendable, Equatable {
    public let entries: Int
    public let uncompressedBytes: Int64

    public init(entries: Int, uncompressedBytes: Int64) {
        self.entries = entries
        self.uncompressedBytes = uncompressedBytes
    }
}

/// Failures an `ArchiveExtractor` surfaces. Each maps to a stable
/// `BridgeError` code at the `fs.extractZip` boundary.
public enum ArchiveError: Error, Equatable {
    case notReadable(path: String)
    case corrupt(String)
    case pathTraversal(entry: String)
    case symlinkRejected(entry: String)
    case tooManyEntries(limit: Int)
    case uncompressedTooLarge(limit: Int64)
    case compressionRatioExceeded(entry: String, ratio: Double, limit: Double)
}

/// Path-safety helpers shared by every `ArchiveExtractor` so the
/// traversal guard is defined and tested once, in Core, independent of the
/// zip backend.
public enum ArchiveSafety {
    /// Resolve a zip entry's path against `root`, returning the on-disk
    /// destination only if it stays inside `root` after normalisation.
    /// Returns `nil` for an absolute path, a leading-slash path, or any
    /// `../` sequence that would escape — the caller treats `nil` as a
    /// path-traversal rejection.
    public static func resolveDestination(entry: String, within root: URL) -> URL? {
        // Absolute or rooted entry names never belong inside `root`.
        if entry.hasPrefix("/") || entry.hasPrefix("\\") { return nil }
        // Windows-style drive prefixes (C:\...) are absolute too.
        if entry.count >= 2 {
            let chars = Array(entry)
            if chars[1] == ":" { return nil }
        }
        let rootStd = root.standardizedFileURL
        let candidate = rootStd.appendingPathComponent(entry).standardizedFileURL
        let rootPath = rootStd.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }
}
