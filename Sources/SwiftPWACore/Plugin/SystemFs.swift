import Foundation

/// Default `Fs` implementation backed by `FileManager` and
/// `Data(contentsOf:)`. Portable across every backend: Apple
/// Foundation, swift-corelibs-foundation on Linux, and the Windows
/// port all expose the same surface.
///
/// Operations are `async` because some hosts (notably the Windows
/// port of swift-corelibs-foundation) can take observable wall-clock
/// time on large directory walks; running the calls inside a
/// `Task.detached`-style hop keeps the JS-facing latency consistent
/// across platforms even though most operations are quick.
public final class SystemFs: Fs, @unchecked Sendable {
    private let extractor: (any ArchiveExtractor)?

    /// `extractor` is the optional zip backend. Pass `ZIPExtractor()` (from
    /// `SwiftPWAArchive`) to enable `fs.extractZip` / `fs.listZip`; leave nil
    /// for an app that doesn't import content packs (no ZIPFoundation link).
    public init(extractor: (any ArchiveExtractor)? = nil) {
        self.extractor = extractor
    }

    // MARK: - Content URI resolver (Android SAF)

    /// Prefix used to recognise an Android SAF / content-provider URI
    /// in the otherwise filesystem-path-shaped `Fs` surface.
    static let contentURIScheme = "content://"

    private static let resolverLock = NSLock()
    private nonisolated(unsafe) static var sharedContentResolver: (any FsContentResolver)?

    /// Install a process-wide resolver for `content://` URIs.
    /// `SwiftPWAAndroid.AndroidAppContext` registers an
    /// `AndroidContentResolver` on init; other backends never call
    /// this and the slot stays nil.
    public static func setContentResolver(_ resolver: (any FsContentResolver)?) {
        resolverLock.withLock { sharedContentResolver = resolver }
    }

    /// Look up the resolver under lock; nil on non-Android (or before
    /// the Android backend registers one).
    static func contentResolver() -> (any FsContentResolver)? {
        resolverLock.withLock { sharedContentResolver }
    }

    /// Whether `path` should route through the content-URI resolver.
    static func isContentURI(_ path: String) -> Bool {
        path.hasPrefix(contentURIScheme)
    }

    private func requireContentResolver(_ op: String) throws -> any FsContentResolver {
        guard let r = Self.contentResolver() else {
            throw BridgeError(
                code: BridgeError.handler,
                message: "\(op): content:// URIs require AndroidContentResolver — only the Android backend supplies one"
            )
        }
        return r
    }

    private func contentURIOperationUnsupported(_ op: String, path: String) -> BridgeError {
        BridgeError(
            code: BridgeError.handler,
            message: "\(op): not supported on a content:// URI (\(path)) — SAF doesn't expose this operation"
        )
    }

    public func readText(path: String) async throws -> String {
        let data = try await readBinary(path: path)
        guard let str = String(data: data, encoding: .utf8) else {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.readText: \(path) is not valid UTF-8"
            )
        }
        return str
    }

    public func writeText(path: String, contents: String) async throws {
        try await writeBinary(path: path, data: Data(contents.utf8))
    }

    public func readBinary(path: String) async throws -> Data {
        if Self.isContentURI(path) {
            return try await requireContentResolver("fs.readBinary").readBinary(uri: path)
        }
        let url = URL(fileURLWithPath: path)
        // `FileManager.contents(atPath:)` is more reliable than
        // `Data(contentsOf:)` on swift-corelibs-foundation under
        // Windows (the latter returns NSCocoaError 260 on real files,
        // a wart the bundler hit during v0.3 — see CHANGELOG).
        if let data = FileManager.default.contents(atPath: url.path) {
            return data
        }
        throw mapPosixError("fs.readBinary", path: path)
    }

    public func writeBinary(path: String, data: Data) async throws {
        if Self.isContentURI(path) {
            try await requireContentResolver("fs.writeBinary").writeBinary(uri: path, data: data)
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.writeBinary failed at \(path): \(error.localizedDescription)"
            )
        }
    }

    public func exists(path: String) async throws -> Bool {
        if Self.isContentURI(path) {
            // A content URI "exists" if the resolver can produce
            // metadata for it. SAF doesn't have a cheaper presence
            // probe — `query()` with a single projected column is
            // the minimum the platform supports.
            guard let r = Self.contentResolver() else { return false }
            do {
                _ = try await r.metadata(uri: path)
                return true
            } catch {
                return false
            }
        }
        return FileManager.default.fileExists(atPath: path)
    }

    public func mkdir(path: String, recursive: Bool) async throws {
        if Self.isContentURI(path) {
            throw contentURIOperationUnsupported("fs.mkdir", path: path)
        }
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: recursive,
                attributes: nil
            )
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.mkdir failed at \(path): \(error.localizedDescription)"
            )
        }
    }

    public func remove(path: String, recursive: Bool) async throws {
        if Self.isContentURI(path) {
            throw contentURIOperationUnsupported("fs.remove", path: path)
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.remove: \(path) does not exist"
            )
        }
        // For directories with content, refuse without `recursive`
        // — matches the `rm -d` / `rmdir` distinction. For an empty
        // directory either flag works.
        if isDir.boolValue, !recursive {
            let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            if !contents.isEmpty {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "fs.remove: \(path) is non-empty (pass recursive: true)"
                )
            }
        }
        do {
            try fm.removeItem(atPath: path)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.remove failed at \(path): \(error.localizedDescription)"
            )
        }
    }

    public func readDir(path: String) async throws -> [FsEntry] {
        if Self.isContentURI(path) {
            throw contentURIOperationUnsupported("fs.readDir", path: path)
        }
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: path)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.readDir failed at \(path): \(error.localizedDescription)"
            )
        }
        // Sort for deterministic output — JS callers expect a stable
        // order for "list and render" patterns. `contentsOfDirectory`
        // is unordered on some platforms.
        let sorted = entries.sorted()
        let baseURL = URL(fileURLWithPath: path, isDirectory: true)
        return sorted.map { name in
            let full = baseURL.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: full, isDirectory: &isDir)
            return FsEntry(
                name: name,
                path: full,
                isDir: exists && isDir.boolValue,
                isFile: exists && !isDir.boolValue
            )
        }
    }

    public func copy(from: String, to: String) async throws {
        if Self.isContentURI(from) || Self.isContentURI(to) {
            throw contentURIOperationUnsupported("fs.copy", path: "\(from) → \(to)")
        }
        do {
            try FileManager.default.copyItem(atPath: from, toPath: to)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.copy failed (\(from) → \(to)): \(error.localizedDescription)"
            )
        }
    }

    public func rename(from: String, to: String) async throws {
        if Self.isContentURI(from) || Self.isContentURI(to) {
            throw contentURIOperationUnsupported("fs.rename", path: "\(from) → \(to)")
        }
        do {
            try FileManager.default.moveItem(atPath: from, toPath: to)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.rename failed (\(from) → \(to)): \(error.localizedDescription)"
            )
        }
    }

    public func metadata(path: String) async throws -> FsMetadata {
        if Self.isContentURI(path) {
            return try await requireContentResolver("fs.metadata").metadata(uri: path)
        }
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: path)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.metadata failed at \(path): \(error.localizedDescription)"
            )
        }
        let kind = attrs[.type] as? FileAttributeType
        let isDir = (kind == .typeDirectory)
        // `typeRegular` is the canonical "plain file"; symlinks /
        // sockets / devices fall through and report `isFile: false`.
        let isFile = (kind == .typeRegular)
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        let modified = (attrs[.modificationDate] as? Date)
            .map { Int64($0.timeIntervalSince1970 * 1000) }
        return FsMetadata(size: size, isDir: isDir, isFile: isFile, modified: modified)
    }

    // MARK: - Archive (content packs)

    public var supportsZip: Bool {
        extractor != nil
    }

    public func listZip(path: String) async throws -> [ArchiveEntry] {
        let extractor = try requireExtractor("fs.listZip")
        let url = try Self.archiveSourceURL(path, op: "fs.listZip")
        do {
            return try await extractor.list(zipAt: url)
        } catch let e as ArchiveError {
            throw Self.mapArchiveError("fs.listZip", e)
        }
    }

    public func extractZip(
        from: String,
        to: String,
        limits: ExtractLimits,
        onProgress: (@Sendable (ExtractProgress) -> Void)?
    ) async throws -> ExtractResult {
        let extractor = try requireExtractor("fs.extractZip")
        // The source archive MAY be a content:// URI (an Android SAF pick), so a
        // user-chosen archive extracts off-bridge instead of forcing a
        // readBinary→base64→writeBinary materialize first (the cost the native
        // extractor exists to avoid). The destination must be a real filesystem
        // path — SAF exposes no writable directory tree to extract into.
        if Self.isContentURI(to) {
            throw contentURIOperationUnsupported("fs.extractZip (destination)", path: to)
        }
        let src = try Self.archiveSourceURL(from, op: "fs.extractZip")
        let dst = URL(fileURLWithPath: to)
        do {
            return try await extractor.extract(zipAt: src, to: dst, limits: limits, onProgress: onProgress)
        } catch let e as ArchiveError {
            throw Self.mapArchiveError("fs.extractZip", e)
        }
    }

    public func createZip(
        from: String,
        to: String,
        compression: ZipCompression,
        onProgress: (@Sendable (CreateProgress) -> Void)?
    ) async throws -> CreateResult {
        let extractor = try requireExtractor("fs.createZip")
        if Self.isContentURI(from) || Self.isContentURI(to) {
            throw contentURIOperationUnsupported("fs.createZip", path: "\(from) → \(to)")
        }
        let src = URL(fileURLWithPath: from)
        let dst = URL(fileURLWithPath: to)
        do {
            return try await extractor.create(zipAt: dst, from: src, compression: compression, onProgress: onProgress)
        } catch let e as ArchiveError {
            throw Self.mapArchiveError("fs.createZip", e)
        }
    }

    // MARK: - Helpers

    /// The archive **source** URL for a zip op. A `content://` path (an Android
    /// SAF pick) is preserved as a scheme'd URL so the Android extractor can
    /// stream it via `ContentResolver`; everything else is a filesystem path.
    /// Only the Android backend ever produces `content://`, so other extractors
    /// only ever see file URLs.
    static func archiveSourceURL(_ path: String, op: String) throws -> URL {
        guard isContentURI(path) else { return URL(fileURLWithPath: path) }
        guard let url = URL(string: path) else {
            throw BridgeError(code: BridgeError.handler, message: "\(op): invalid content:// URI: \(path)")
        }
        return url
    }

    private func requireExtractor(_ op: String) throws -> any ArchiveExtractor {
        guard let extractor else {
            throw BridgeError(
                code: BridgeError.handler,
                message: "\(op): no archive extractor configured — use FsPlugin(SystemFs(extractor: ZIPExtractor()))"
            )
        }
        return extractor
    }

    /// Map an `ArchiveError` to a `BridgeError` with a stable, JS-readable
    /// message. The guard violations carry enough detail for an app to tell
    /// a user *why* a pack was rejected (traversal, symlink, too big).
    static func mapArchiveError(_ op: String, _ error: ArchiveError) -> BridgeError {
        let detail: String = switch error {
        case let .notReadable(path): "not a readable zip: \(path)"
        case let .corrupt(msg): "corrupt archive: \(msg)"
        case let .pathTraversal(entry): "entry escapes destination (path traversal): \(entry)"
        case let .symlinkRejected(entry): "symlink entries are rejected: \(entry)"
        case let .tooManyEntries(limit): "too many entries (limit \(limit))"
        case let .uncompressedTooLarge(limit): "uncompressed size exceeds limit (\(limit) bytes)"
        case let .compressionRatioExceeded(entry, ratio, limit):
            "compression ratio \(ratio) exceeds limit \(limit) for \(entry)"
        case let .unsupportedPlatform(msg): msg
        }
        return BridgeError(code: BridgeError.handler, message: "\(op): \(detail)")
    }

    private func mapPosixError(_ op: String, path: String) -> BridgeError {
        let exists = FileManager.default.fileExists(atPath: path)
        let detail = exists ? "read failed" : "no such file"
        return BridgeError(
            code: BridgeError.handler,
            message: "\(op): \(path) — \(detail)"
        )
    }
}
