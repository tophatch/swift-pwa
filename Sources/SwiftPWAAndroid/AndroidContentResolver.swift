#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `FsContentResolver` implementation that routes `content://` URI
    /// operations through Kotlin's `android.content.ContentResolver`.
    ///
    /// SAF / Storage Access Framework dialogs (`dialog.openFile`,
    /// `dialog.saveFile`, `dialog.openDirectory` on Android) return
    /// `content://authority/...` URIs instead of POSIX paths, because
    /// scoped storage means apps don't get a raw path for user-selected
    /// files. `SystemFs.readBinary` / `writeBinary` / `metadata` /
    /// `exists` check for the `content://` prefix and delegate to this
    /// resolver, which RPCs into the Kotlin scaffold's
    /// `SwiftPWASystemPlugins` (`fs.readContentUri`,
    /// `fs.writeContentUri`, `fs.contentUriMetadata`). Apps wire it up
    /// once on startup:
    ///
    /// ```swift
    /// SystemFs.setContentResolver(AndroidContentResolver())
    /// ```
    ///
    /// The Android `AndroidAppContext` does that automatically on
    /// process init, so `FsPlugin(SystemFs())` "just works" for SAF
    /// dialog results out of the box — apps don't have to special-case
    /// URI-shaped paths in JS.
    public final class AndroidContentResolver: FsContentResolver, @unchecked Sendable {
        public init() {}

        public func readBinary(uri: String) async throws -> Data {
            let result = try await AndroidRPC.call(
                "fs.readContentUri",
                ContentURIArgs(uri: uri),
                as: ContentURIDataResult.self
            )
            guard let data = Data(base64Encoded: result.dataBase64) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "fs.readBinary: content resolver returned malformed base64 for \(uri)"
                )
            }
            return data
        }

        public func writeBinary(uri: String, data: Data) async throws {
            _ = try await AndroidRPC.call(
                "fs.writeContentUri",
                ContentURIWriteArgs(uri: uri, dataBase64: data.base64EncodedString()),
                as: NoResult.self
            )
        }

        public func metadata(uri: String) async throws -> FsMetadata {
            let result = try await AndroidRPC.call(
                "fs.contentUriMetadata",
                ContentURIArgs(uri: uri),
                as: ContentURIMetadataResult.self
            )
            // SAF doesn't expose a "this URI is a directory" concept
            // the way POSIX does — content URIs returned by
            // `OpenDocument` / `CreateDocument` are always documents
            // (files). `OpenDocumentTree` returns a tree URI, but
            // those are handled separately (apps that need to walk a
            // tree should use the SAF DocumentFile API; out of scope
            // for v0.5.x). We therefore always report `isDir: false`,
            // `isFile: true` for content URIs that resolve.
            return FsMetadata(
                size: result.size,
                isDir: false,
                isFile: true,
                modified: result.modified
            )
        }
    }

    // MARK: - On-the-wire arg / result shapes

    /// `{"uri": "content://..."}`. Used by readBinary + metadata.
    struct ContentURIArgs: Encodable {
        let uri: String
    }

    /// `{"uri": "...", "dataBase64": "..."}`.
    struct ContentURIWriteArgs: Encodable {
        let uri: String
        let dataBase64: String
    }

    /// `{"dataBase64": "..."}` returned by `fs.readContentUri`.
    struct ContentURIDataResult: Decodable {
        let dataBase64: String
    }

    /// `{"size": Int64, "modified": Int64?}` returned by
    /// `fs.contentUriMetadata`. `modified` is millis since the Unix
    /// epoch, or nil if the underlying `DocumentsContract` row had
    /// no `LAST_MODIFIED` column.
    struct ContentURIMetadataResult: Decodable {
        let size: Int64
        let modified: Int64?
    }
#endif
