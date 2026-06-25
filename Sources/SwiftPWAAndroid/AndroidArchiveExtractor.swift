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
                ListZipArgs(from: url.path),
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
                    from: url.path,
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
    }
#endif
