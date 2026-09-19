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
            // `isDir` is the document's own MIME type being
            // `vnd.android.document/directory`. Through 0.11.1 this reported
            // `isFile` for everything, on the reasoning that a picked URI is
            // always a document — which stopped being true the moment a tree
            // could be listed (#246), because every subdirectory in that
            // listing is a content URI an app asks about before descending.
            return FsMetadata(
                size: result.size,
                isDir: result.isDir ?? false,
                isFile: !(result.isDir ?? false),
                modified: result.modified
            )
        }

        public func readDir(uri: String) async throws -> [FsEntry] {
            try await AndroidRPC.call(
                "fs.readDirContentUri",
                ContentURIArgs(uri: uri),
                as: ContentURIEntriesResult.self
            ).entries
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

    /// `{"size": Int64?, "modified": Int64?, "isDir": Bool}` returned by
    /// `fs.contentUriMetadata`. `modified` is millis since the Unix
    /// epoch; both it and `size` are absent when the underlying
    /// `DocumentsContract` row had no such column.
    struct ContentURIMetadataResult: Decodable {
        /// Absent when the provider omitted `COLUMN_SIZE` — which a
        /// network-backed one (Drive, OneDrive, Dropbox) is entitled to do,
        /// and does.
        let size: Int64?
        let modified: Int64?
        /// Absent on a provider row with no MIME type; the caller reads that
        /// as a file, which is what every URI a picker hands back is.
        let isDir: Bool?
    }

    /// `{"entries": [FsEntry]}` returned by `fs.readDirContentUri`. The Kotlin
    /// side emits exactly `FsEntry`'s field names, so it decodes straight into
    /// the shape a filesystem path returns.
    struct ContentURIEntriesResult: Decodable {
        let entries: [FsEntry]
    }
#endif
