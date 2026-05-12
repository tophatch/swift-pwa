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
