#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `ArchiveExtractor` for Android. ZIPFoundation can't build against
    /// Bionic libc (`lstat` / `errno` / `S_IF*` / `mode_t` mismatches), so
    /// extraction routes over the JNI bridge to Kotlin's `java.util.zip`
    /// (`fs.listZipNative` / `fs.extractZipNative` in the generated
    /// `SwiftPWASystemPlugins`). The traversal / zip-bomb guards are enforced
    /// Kotlin-side; the contract is identical to `ZIPExtractor`.
    ///
    /// Apps select it per platform:
    /// ```swift
    /// #if os(Android)
    /// let extractor: any ArchiveExtractor = AndroidArchiveExtractor()
    /// #else
    /// let extractor: any ArchiveExtractor = ZIPExtractor()
    /// #endif
    /// ctx.use(FsPlugin(SystemFs(extractor: extractor)))
    /// ```
    public struct AndroidArchiveExtractor: ArchiveExtractor {
        public init() {}

        public func list(zipAt url: URL) async throws -> [ArchiveEntry] {
            let result = try await AndroidRPC.call(
                "fs.listZipNative",
                ListZipArgs(from: Self.sourceArg(url)),
                as: ListZipResult.self
            )
            return result.entries
        }

        @discardableResult
        public func extract(
            zipAt url: URL,
            to destination: URL,
            limits: ExtractLimits,
            onProgress: (@Sendable (ExtractProgress) -> Void)?
        ) async throws -> ExtractResult {
            let result = try await AndroidRPC.call(
                "fs.extractZipNative",
                ExtractZipArgs(
                    from: Self.sourceArg(url),
                    to: destination.path,
                    maxUncompressedBytes: limits.maxUncompressedBytes,
                    maxEntries: limits.maxEntries,
                    maxCompressionRatio: limits.maxCompressionRatio
                ),
                as: ExtractResult.self
            )
            // The Kotlin side extracts in one shot (no per-entry channel over
            // the unary RPC), so emit a single terminal progress tick before
            // the caller's `done` — enough to drive a determinate-on-completion
            // bar without a streaming back-channel.
            onProgress?(ExtractProgress(
                entriesDone: result.entries,
                bytesDone: result.uncompressedBytes,
                totalEntries: result.entries
            ))
            return result
        }

        @discardableResult
        public func create(
            zipAt destination: URL,
            from source: URL,
            compression: ZipCompression,
            onProgress: (@Sendable (CreateProgress) -> Void)?
        ) async throws -> CreateResult {
            let result = try await AndroidRPC.call(
                "fs.createZipNative",
                CreateZipArgs(from: source.path, to: destination.path, compression: compression.rawValue),
                as: CreateResult.self
            )
            // One-shot RPC (no per-entry channel), so emit a single terminal
            // progress tick — enough to drive a determinate-on-completion bar.
            onProgress?(CreateProgress(
                entriesDone: result.entries,
                bytesDone: result.uncompressedBytes,
                totalEntries: result.entries
            ))
            return result
        }

        /// The `from` argument for the Kotlin zip RPCs. A `content://` SAF pick
        /// is sent as the full URI string (the Kotlin side opens it via
        /// `ContentResolver.openInputStream` → `ZipInputStream`); a real file is
        /// sent as its path (Kotlin uses random-access `ZipFile`). `url.path`
        /// would be unusable for a `content://` URI.
        private static func sourceArg(_ url: URL) -> String {
            url.scheme == "content" ? url.absoluteString : url.path
        }

        // MARK: - On-the-wire shapes (match the Kotlin handlers)

        private struct ListZipArgs: Encodable { let from: String }
        private struct ListZipResult: Decodable { let entries: [ArchiveEntry] }

        private struct ExtractZipArgs: Encodable {
            let from: String
            let to: String
            // Nil optionals are omitted by JSONEncoder, so the Kotlin side
            // falls back to its unbounded defaults for any guard not set.
            let maxUncompressedBytes: Int64?
            let maxEntries: Int?
            let maxCompressionRatio: Double?
        }

        private struct CreateZipArgs: Encodable {
            let from: String
            let to: String
            let compression: String // "stored" | "deflate"
        }
    }
#endif
