import Foundation
@testable import SwiftPWACore
import Testing

/// `SystemFs` zip-source routing: an Android SAF pick arrives as a `content://`
/// URI, which `fs.listZip` / `fs.extractZip` must forward to the extractor
/// (preserving the scheme) rather than rejecting — so a user-chosen archive
/// extracts off-bridge instead of forcing a base64 materialize. The
/// destination must stay a real filesystem path.
@Suite("SystemFs — zip content:// source")
struct SystemFsZipSourceTests {
    /// Records the URLs `SystemFs` hands the extractor.
    final class RecordingExtractor: ArchiveExtractor, @unchecked Sendable {
        var listed: [URL] = []
        var extractedFrom: [URL] = []

        func list(zipAt url: URL) async throws -> [ArchiveEntry] {
            listed.append(url)
            return []
        }

        func extract(
            zipAt url: URL,
            to _: URL,
            limits _: ExtractLimits,
            onProgress _: (@Sendable (ExtractProgress) -> Void)?
        ) async throws -> ExtractResult {
            extractedFrom.append(url)
            return ExtractResult(entries: 0, uncompressedBytes: 0)
        }
    }

    @Test("archiveSourceURL preserves a content:// URI and round-trips its encoding")
    func archiveSourceURLContent() throws {
        // A realistic SAF document URI with a percent-encoded ':' — the
        // round-trip must not corrupt it (the bug if we naively rebuilt URLs).
        let uri = "content://com.android.providers.media.documents/document/image%3A42"
        let url = try SystemFs.archiveSourceURL(uri, op: "fs.listZip")
        #expect(url.scheme == "content")
        #expect(url.absoluteString == uri)
    }

    @Test("archiveSourceURL maps a real path to a file URL")
    func archiveSourceURLFile() throws {
        let url = try SystemFs.archiveSourceURL("/data/user/0/app/files/pack.zip", op: "fs.extractZip")
        #expect(url.isFileURL)
        #expect(url.path == "/data/user/0/app/files/pack.zip")
    }

    @Test("listZip forwards a content:// source to the extractor unchanged")
    func listZipForwardsContent() async throws {
        let ex = RecordingExtractor()
        let fs = SystemFs(extractor: ex)
        let uri = "content://authority/document/pack.zip"
        _ = try await fs.listZip(path: uri)
        #expect(ex.listed.map(\.absoluteString) == [uri])
    }

    @Test("extractZip forwards a content:// source to the extractor unchanged")
    func extractZipForwardsContent() async throws {
        let ex = RecordingExtractor()
        let fs = SystemFs(extractor: ex)
        let uri = "content://authority/document/pack.zip"
        _ = try await fs.extractZip(from: uri, to: "/tmp/out", limits: .default, onProgress: nil)
        #expect(ex.extractedFrom.map(\.absoluteString) == [uri])
    }

    @Test("extractZip rejects a content:// destination (SAF has no writable tree)")
    func extractZipRejectsContentDestination() async throws {
        let ex = RecordingExtractor()
        let fs = SystemFs(extractor: ex)
        await #expect(throws: BridgeError.self) {
            _ = try await fs.extractZip(
                from: "/tmp/in.zip", to: "content://authority/out", limits: .default, onProgress: nil
            )
        }
        #expect(ex.extractedFrom.isEmpty)
    }
}
