import Foundation

/// Cross-platform filesystem access. The default `SystemFs` is built
/// on `FileManager` and `Data(contentsOf:)`, which work identically on
/// every backend — Apple Foundation, swift-corelibs-foundation on
/// Linux, and the Windows port. No per-backend implementations exist;
/// tests use `MockFs` from `_SwiftPWATestSupport`.
///
/// **Sandbox.** On iOS / macOS sandboxed apps, paths are restricted to
/// the app's container (and any user-granted scoped bookmarks). On
/// desktop hosts the process runs with the user's full permissions —
/// the host app is expected to gate sensitive flows itself, e.g. by
/// pairing this plugin with `dialog.openFile` so the user picks the
/// path the JS side then reads. The plugin is opt-in for that reason.
///
/// **Binary data.** `readBinary` / `writeBinary` exchange bytes as
/// base64-encoded strings — the simplest representation that survives
/// JSON envelope encoding without additional infrastructure. Consider
/// `URL.createObjectURL` (or a `pwa://` resource handler) if your app
/// is reading large media files repeatedly.
public protocol Fs: AnyObject, Sendable {
    func readText(path: String) async throws -> String
    func writeText(path: String, contents: String) async throws

    /// Read raw bytes. The Swift side returns `Data`; `FsPlugin` wraps
    /// it in a base64 envelope before sending across the bridge.
    func readBinary(path: String) async throws -> Data
    func writeBinary(path: String, data: Data) async throws

    func exists(path: String) async throws -> Bool

    /// Create a directory. `recursive` mirrors `mkdir -p`: when true,
    /// missing parents are created and an existing directory at `path`
    /// is not an error. When false the call fails if the parent
    /// doesn't exist or `path` already exists.
    func mkdir(path: String, recursive: Bool) async throws

    /// Remove a file or directory. `recursive` is required to remove
    /// a non-empty directory; otherwise the call mirrors `rm -d` and
    /// refuses.
    func remove(path: String, recursive: Bool) async throws

    /// List `path`'s contents as `FsEntry` records. Symlinks are not
    /// followed when reporting `isDir` / `isFile` — pass through
    /// `metadata(path:)` on the entry path if you need that.
    func readDir(path: String) async throws -> [FsEntry]

    /// Copy `from` to `to`. Behaves like `cp` for files; for
    /// directories the entire tree is copied. `to` must not exist.
    func copy(from: String, to: String) async throws

    /// Move / rename. `to` must not exist. Cross-volume renames work
    /// (`FileManager.moveItem` falls back to copy + delete).
    func rename(from: String, to: String) async throws

    /// File / directory metadata. `modified` is millisecond Unix epoch
    /// for compatibility with JS `new Date(...)`.
    func metadata(path: String) async throws -> FsMetadata

    // MARK: - Archive (content packs)

    /// Whether `fs.extractZip` / `fs.listZip` are available — true only
    /// when an `ArchiveExtractor` is injected (`SystemFs(extractor:)`).
    /// `FsPlugin` registers the zip commands only when this is true, so an
    /// app that doesn't import packs links neither ZIPFoundation nor the
    /// commands.
    var supportsZip: Bool { get }

    /// List a zip's central directory without extracting — lets a caller
    /// validate a manifest entry before committing to a multi-GB extract.
    func listZip(path: String) async throws -> [ArchiveEntry]

    /// Extract `from` (a `.zip`) into `to` (created if absent), enforcing
    /// `limits` (zip-bomb / traversal / symlink guards). `onProgress`, if
    /// given, fires per entry. Bytes are read and written entry-by-entry —
    /// they never cross the bridge.
    func extractZip(
        from: String,
        to: String,
        limits: ExtractLimits,
        onProgress: (@Sendable (ExtractProgress) -> Void)?
    ) async throws -> ExtractResult

    /// Create a zip at `to` from the directory tree rooted at `from` — the
    /// inverse of `extractZip`. `compression` picks stored vs deflate.
    /// `onProgress`, if given, fires per entry. Bytes are read and written
    /// entry-by-entry; they never cross the bridge.
    func createZip(
        from: String,
        to: String,
        compression: ZipCompression,
        onProgress: (@Sendable (CreateProgress) -> Void)?
    ) async throws -> CreateResult
}

/// Default archive surface: unsupported. Only `SystemFs` (with an injected
/// extractor) overrides these, so `MockFs` and any other `Fs` get the
/// no-op-but-clear-error behavior for free.
public extension Fs {
    var supportsZip: Bool {
        false
    }

    func listZip(path _: String) async throws -> [ArchiveEntry] {
        throw BridgeError(
            code: BridgeError.handler,
            message: "fs.listZip: no archive extractor configured — use FsPlugin(SystemFs(extractor: ZIPExtractor()))"
        )
    }

    func extractZip(
        from _: String,
        to _: String,
        limits _: ExtractLimits,
        onProgress _: (@Sendable (ExtractProgress) -> Void)?
    ) async throws -> ExtractResult {
        throw BridgeError(
            code: BridgeError.handler,
            message: "fs.extractZip: no archive extractor configured — use FsPlugin(SystemFs(extractor: ZIPExtractor()))"
        )
    }

    func createZip(
        from _: String,
        to _: String,
        compression _: ZipCompression,
        onProgress _: (@Sendable (CreateProgress) -> Void)?
    ) async throws -> CreateResult {
        throw BridgeError(
            code: BridgeError.handler,
            message: "fs.createZip: no archive extractor configured — use FsPlugin(SystemFs(extractor: ZIPExtractor()))"
        )
    }
}

/// Backend hook for resolving `content://` URIs. Android's Storage
/// Access Framework hands SAF picker results back as
/// `content://authority/...` URIs rather than filesystem paths, so the
/// otherwise platform-agnostic `SystemFs` defers URI-shaped paths to a
/// resolver supplied by `SwiftPWAAndroid` (see `AndroidContentResolver`).
///
/// `mkdir` / `readDir` / `copy` / `rename` aren't part of the contract:
/// SAF doesn't expose directory-style operations on content URIs in a
/// shape that maps cleanly onto the POSIX-flavoured Fs surface, so
/// those operations throw on a `content://` argument rather than
/// silently misbehaving. `exists` is satisfied by a successful
/// `metadata` call.
public protocol FsContentResolver: Sendable {
    func readBinary(uri: String) async throws -> Data
    func writeBinary(uri: String, data: Data) async throws
    func metadata(uri: String) async throws -> FsMetadata
}

// MARK: - DTOs

public struct FsEntry: Sendable, Codable, Equatable {
    public var name: String
    public var path: String
    public var isDir: Bool
    public var isFile: Bool

    public init(name: String, path: String, isDir: Bool, isFile: Bool) {
        self.name = name
        self.path = path
        self.isDir = isDir
        self.isFile = isFile
    }
}

public struct FsMetadata: Sendable, Codable, Equatable {
    public var size: Int64
    public var isDir: Bool
    public var isFile: Bool
    /// Milliseconds since the Unix epoch.
    public var modified: Int64?

    public init(size: Int64, isDir: Bool, isFile: Bool, modified: Int64?) {
        self.size = size
        self.isDir = isDir
        self.isFile = isFile
        self.modified = modified
    }
}

// MARK: - Argument DTOs (used by `FsPlugin`)

public struct FsPathArgs: Sendable, Codable, Equatable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct FsWriteTextArgs: Sendable, Codable, Equatable {
    public var path: String
    public var contents: String
    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public struct FsWriteBinaryArgs: Sendable, Codable, Equatable {
    public var path: String
    public var dataBase64: String
    public init(path: String, dataBase64: String) {
        self.path = path
        self.dataBase64 = dataBase64
    }
}

public struct FsMkdirArgs: Sendable, Codable, Equatable {
    public var path: String
    public var recursive: Bool?
    public init(path: String, recursive: Bool? = nil) {
        self.path = path
        self.recursive = recursive
    }
}

public struct FsRemoveArgs: Sendable, Codable, Equatable {
    public var path: String
    public var recursive: Bool?
    public init(path: String, recursive: Bool? = nil) {
        self.path = path
        self.recursive = recursive
    }
}

public struct FsCopyArgs: Sendable, Codable, Equatable {
    public var from: String
    public var to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

// MARK: - Result envelopes

public struct FsTextResult: Sendable, Codable, Equatable {
    public var contents: String
    public init(contents: String) { self.contents = contents }
}

public struct FsBinaryResult: Sendable, Codable, Equatable {
    public var dataBase64: String
    public init(dataBase64: String) { self.dataBase64 = dataBase64 }
}

public struct FsExistsResult: Sendable, Codable, Equatable {
    public var exists: Bool
    public init(exists: Bool) { self.exists = exists }
}

public struct FsReadDirResult: Sendable, Codable, Equatable {
    public var entries: [FsEntry]
    public init(entries: [FsEntry]) { self.entries = entries }
}

// MARK: - Archive argument / result DTOs

public struct FsListZipArgs: Sendable, Codable, Equatable {
    public var from: String
    public init(from: String) { self.from = from }
}

public struct FsListZipResult: Sendable, Codable, Equatable {
    public var entries: [ArchiveEntry]
    public init(entries: [ArchiveEntry]) { self.entries = entries }
}

public struct FsExtractZipArgs: Sendable, Codable, Equatable {
    public var from: String
    public var to: String
    /// Zip-bomb guards. Omitted fields fall back to `ExtractLimits.default`
    /// (generous-but-finite), never to unbounded — untrusted input.
    public var maxUncompressedBytes: Int64?
    public var maxEntries: Int?
    public var maxCompressionRatio: Double?

    public init(
        from: String,
        to: String,
        maxUncompressedBytes: Int64? = nil,
        maxEntries: Int? = nil,
        maxCompressionRatio: Double? = nil
    ) {
        self.from = from
        self.to = to
        self.maxUncompressedBytes = maxUncompressedBytes
        self.maxEntries = maxEntries
        self.maxCompressionRatio = maxCompressionRatio
    }

    /// Merge the supplied guards over the safe defaults.
    public var limits: ExtractLimits {
        ExtractLimits(
            maxUncompressedBytes: maxUncompressedBytes ?? ExtractLimits.default.maxUncompressedBytes,
            maxEntries: maxEntries ?? ExtractLimits.default.maxEntries,
            maxCompressionRatio: maxCompressionRatio ?? ExtractLimits.default.maxCompressionRatio
        )
    }
}

/// One event of the streaming `fs.extractZipProgress` subscription. `type`
/// is `"progress"` (carries `entriesDone` / `bytesDone` / `totalEntries`)
/// or `"done"` (carries the final `entries` / `uncompressedBytes`). Errors
/// arrive as the stream's error termination, not a `type: "error"` event.
public struct FsExtractEvent: Sendable, Codable, Equatable {
    public var type: String
    public var entriesDone: Int?
    public var bytesDone: Int64?
    public var totalEntries: Int?
    public var entries: Int?
    public var uncompressedBytes: Int64?

    public static func progress(_ p: ExtractProgress) -> FsExtractEvent {
        FsExtractEvent(
            type: "progress",
            entriesDone: p.entriesDone,
            bytesDone: p.bytesDone,
            totalEntries: p.totalEntries
        )
    }

    public static func done(_ r: ExtractResult) -> FsExtractEvent {
        FsExtractEvent(type: "done", entries: r.entries, uncompressedBytes: r.uncompressedBytes)
    }

    public init(
        type: String,
        entriesDone: Int? = nil,
        bytesDone: Int64? = nil,
        totalEntries: Int? = nil,
        entries: Int? = nil,
        uncompressedBytes: Int64? = nil
    ) {
        self.type = type
        self.entriesDone = entriesDone
        self.bytesDone = bytesDone
        self.totalEntries = totalEntries
        self.entries = entries
        self.uncompressedBytes = uncompressedBytes
    }
}

public struct FsCreateZipArgs: Sendable, Codable, Equatable {
    /// Source directory to zip.
    public var from: String
    /// Output `.zip` path.
    public var to: String
    /// `"stored"` (default) or `"deflate"`. Packs default to stored —
    /// already-compressed media gains nothing from deflate.
    public var compression: String?

    public init(from: String, to: String, compression: String? = nil) {
        self.from = from
        self.to = to
        self.compression = compression
    }

    /// Parse `compression`, defaulting to `.stored` for an absent or
    /// unrecognised value.
    public var zipCompression: ZipCompression {
        compression.flatMap(ZipCompression.init(rawValue:)) ?? .stored
    }
}

/// One event of the streaming `fs.createZipProgress` subscription. Mirrors
/// `FsExtractEvent`: `type` is `"progress"` (carries `entriesDone` /
/// `bytesDone` / `totalEntries`) or `"done"` (carries `entries` /
/// `uncompressedBytes`). Errors arrive as the stream's error termination.
public struct FsCreateEvent: Sendable, Codable, Equatable {
    public var type: String
    public var entriesDone: Int?
    public var bytesDone: Int64?
    public var totalEntries: Int?
    public var entries: Int?
    public var uncompressedBytes: Int64?

    public static func progress(_ p: CreateProgress) -> FsCreateEvent {
        FsCreateEvent(
            type: "progress",
            entriesDone: p.entriesDone,
            bytesDone: p.bytesDone,
            totalEntries: p.totalEntries
        )
    }

    public static func done(_ r: CreateResult) -> FsCreateEvent {
        FsCreateEvent(type: "done", entries: r.entries, uncompressedBytes: r.uncompressedBytes)
    }

    public init(
        type: String,
        entriesDone: Int? = nil,
        bytesDone: Int64? = nil,
        totalEntries: Int? = nil,
        entries: Int? = nil,
        uncompressedBytes: Int64? = nil
    ) {
        self.type = type
        self.entriesDone = entriesDone
        self.bytesDone = bytesDone
        self.totalEntries = totalEntries
        self.entries = entries
        self.uncompressedBytes = uncompressedBytes
    }
}
