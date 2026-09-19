import Foundation
@testable import SwiftPWACore
import Testing

/// `SystemFs` cross-platform routing through `FsContentResolver` for
/// `content://` URIs. The Android backend installs an
/// `AndroidContentResolver` at startup; on every other backend the
/// resolver slot stays nil and content URIs surface a clear error
/// rather than silently misbehaving when `FileManager` tries to open
/// `content://` as a filesystem path.
@Suite("SystemFs — content:// URI routing", .serialized)
struct SystemFsContentURITests {
    /// Records every call to make assertions trivial. Each method
    /// returns the pre-seeded result so tests can drive the failure /
    /// success paths uniformly.
    final class RecordingResolver: FsContentResolver, @unchecked Sendable {
        var reads: [String] = []
        var writes: [(String, Data)] = []
        var metas: [String] = []
        var lists: [String] = []
        var nextRead: Result<Data, any Error> = .success(Data())
        var nextWrite: (any Error)?
        var nextMeta: Result<FsMetadata, any Error> = .success(
            FsMetadata(size: 0, isDir: false, isFile: true, modified: nil)
        )
        var nextList: Result<[FsEntry], any Error> = .success([])

        func readBinary(uri: String) async throws -> Data {
            reads.append(uri)
            return try nextRead.get()
        }

        func writeBinary(uri: String, data: Data) async throws {
            writes.append((uri, data))
            if let err = nextWrite { throw err }
        }

        func metadata(uri: String) async throws -> FsMetadata {
            metas.append(uri)
            return try nextMeta.get()
        }

        func readDir(uri: String) async throws -> [FsEntry] {
            lists.append(uri)
            return try nextList.get()
        }
    }

    /// A resolver written before tree listing existed. The protocol's default
    /// is what keeps it compiling; this pins that it refuses rather than
    /// returning an empty listing, which an app would read as "the folder the
    /// user picked is empty".
    final class ListlessResolver: FsContentResolver, @unchecked Sendable {
        func readBinary(uri _: String) async throws -> Data { Data() }
        func writeBinary(uri _: String, data _: Data) async throws {}
        func metadata(uri _: String) async throws -> FsMetadata {
            FsMetadata(size: 0, isDir: false, isFile: true, modified: nil)
        }
    }

    /// Always clear the resolver after each test — the slot is
    /// process-wide and leaks would cross-contaminate suites.
    private func withResolver(
        _ resolver: RecordingResolver?,
        _ body: () async throws -> Void
    ) async rethrows {
        SystemFs.setContentResolver(resolver)
        defer { SystemFs.setContentResolver(nil) }
        try await body()
    }

    @Test("readBinary on content:// hits the resolver, not the filesystem")
    func readBinaryRoutes() async throws {
        let r = RecordingResolver()
        r.nextRead = .success(Data("hello".utf8))
        try await withResolver(r) {
            let fs = SystemFs()
            let data = try await fs.readBinary(path: "content://example/file.txt")
            #expect(data == Data("hello".utf8))
            #expect(r.reads == ["content://example/file.txt"])
        }
    }

    @Test("writeBinary on content:// hits the resolver, not the filesystem")
    func writeBinaryRoutes() async throws {
        let r = RecordingResolver()
        try await withResolver(r) {
            let fs = SystemFs()
            try await fs.writeBinary(path: "content://example/out.bin", data: Data([0xDE, 0xAD]))
            #expect(r.writes.count == 1)
            #expect(r.writes[0].0 == "content://example/out.bin")
            #expect(r.writes[0].1 == Data([0xDE, 0xAD]))
        }
    }

    @Test("readText on content:// decodes UTF-8 from the resolver's bytes")
    func readTextRoutes() async throws {
        let r = RecordingResolver()
        r.nextRead = .success(Data("héllo".utf8))
        try await withResolver(r) {
            let fs = SystemFs()
            let text = try await fs.readText(path: "content://example/text.txt")
            #expect(text == "héllo")
        }
    }

    @Test("metadata on content:// hits the resolver")
    func metadataRoutes() async throws {
        let r = RecordingResolver()
        r.nextMeta = .success(FsMetadata(size: 42, isDir: false, isFile: true, modified: 1_700_000_000_000))
        try await withResolver(r) {
            let fs = SystemFs()
            let m = try await fs.metadata(path: "content://example/doc.pdf")
            #expect(m.size == 42)
            #expect(m.isFile == true)
            #expect(m.modified == 1_700_000_000_000)
            #expect(r.metas == ["content://example/doc.pdf"])
        }
    }

    @Test("exists on content:// uses metadata as the presence probe")
    func existsViaMetadata() async throws {
        let r = RecordingResolver()
        // Success: presence reported true.
        r.nextMeta = .success(FsMetadata(size: 0, isDir: false, isFile: true, modified: nil))
        try await withResolver(r) {
            let fs = SystemFs()
            let present = try await fs.exists(path: "content://example/here")
            #expect(present == true)
        }
        // Failure: presence reported false (no throw).
        r.nextMeta = .failure(
            BridgeError(code: BridgeError.handler, message: "content resolver: not found")
        )
        try await withResolver(r) {
            let fs = SystemFs()
            let present = try await fs.exists(path: "content://example/missing")
            #expect(present == false)
        }
    }

    @Test("content:// operations without a resolver throw a clear diagnostic")
    func noResolverThrows() async throws {
        try await withResolver(nil) {
            let fs = SystemFs()
            await #expect(throws: BridgeError.self) {
                _ = try await fs.readBinary(path: "content://example/x")
            }
            await #expect(throws: BridgeError.self) {
                try await fs.writeBinary(path: "content://example/x", data: Data())
            }
            await #expect(throws: BridgeError.self) {
                _ = try await fs.metadata(path: "content://example/x")
            }
            // exists() doesn't throw — returns false when no resolver
            // is installed (matches "this path doesn't exist for us").
            let present = try await fs.exists(path: "content://example/x")
            #expect(present == false)
        }
    }

    @Test("the remaining directory-style ops on content:// throw unsupported")
    func directoryOpsUnsupported() async throws {
        // These should fail regardless of whether a resolver is
        // installed — SAF doesn't expose directory-style operations
        // on content URIs in a shape that maps onto POSIX. We pin
        // the unsupported contract here so a future "let's silently
        // try anyway" change shows up as a test failure.
        let r = RecordingResolver()
        try await withResolver(r) {
            let fs = SystemFs()
            await #expect(throws: BridgeError.self) {
                try await fs.mkdir(path: "content://example/dir", recursive: false)
            }
            await #expect(throws: BridgeError.self) {
                try await fs.remove(path: "content://example/dir", recursive: false)
            }
            await #expect(throws: BridgeError.self) {
                try await fs.copy(from: "content://example/a", to: "/tmp/b")
            }
            await #expect(throws: BridgeError.self) {
                try await fs.rename(from: "/tmp/a", to: "content://example/b")
            }
            // None of these should have called into the resolver.
            #expect(r.reads.isEmpty)
            #expect(r.writes.isEmpty)
        }
    }

    /// #246: a picked folder the app can never walk is a picker that returns
    /// nothing — the app holds a durable grant and can't learn the URIs of
    /// anything inside it, which is exactly the read path that does work.
    /// The Android case this optionality exists for: a `DocumentsProvider`
    /// backed by a network — Drive, OneDrive, Dropbox — is entitled to omit
    /// `COLUMN_SIZE`, and does.
    @Test("a provider that doesn't know the size reports nil, not zero")
    func metadataUnknownSizeRoutes() async throws {
        let r = RecordingResolver()
        r.nextMeta = .success(FsMetadata(size: nil, isDir: false, isFile: true, modified: nil))
        try await withResolver(r) {
            let meta = try await SystemFs().metadata(path: "content://example/doc")
            #expect(meta.size == nil)
            #expect(meta.isFile)
        }
    }

    @Test("readDir on a content:// tree hits the resolver and keeps the entry shape")
    func readDirRoutes() async throws {
        let r = RecordingResolver()
        r.nextList = .success([
            FsEntry(name: "a.epub", path: "content://example/tree/doc%3Aa.epub", isDir: false, isFile: true),
            FsEntry(name: "sub", path: "content://example/tree/doc%3Asub", isDir: true, isFile: false)
        ])
        try await withResolver(r) {
            let fs = SystemFs()
            let entries = try await fs.readDir(path: "content://example/tree/root")
            #expect(r.lists == ["content://example/tree/root"])
            #expect(entries.count == 2)
            // Each entry's `path` is its own document URI, so the read that
            // already works can open it and a subdirectory can be listed in
            // turn.
            #expect(entries[0].path.hasPrefix("content://"))
            #expect(entries[1].isDir)
        }
    }

    @Test("a resolver with no listing refuses rather than reporting an empty folder")
    func readDirDefaultRefuses() async throws {
        SystemFs.setContentResolver(ListlessResolver())
        defer { SystemFs.setContentResolver(nil) }
        await #expect(throws: BridgeError.self) {
            _ = try await SystemFs().readDir(path: "content://example/tree/root")
        }
    }

    @Test("readDir on content:// with no resolver at all still refuses")
    func readDirWithoutResolver() async throws {
        SystemFs.setContentResolver(nil)
        await #expect(throws: BridgeError.self) {
            _ = try await SystemFs().readDir(path: "content://example/tree/root")
        }
    }

    @Test("Non-content paths bypass the resolver entirely")
    func filesystemPathsBypassResolver() async throws {
        let r = RecordingResolver()
        try await withResolver(r) {
            let fs = SystemFs()
            // A real filesystem read against a non-existent path
            // should fail in the FileManager branch (not the
            // resolver) and the resolver should report no calls.
            do {
                _ = try await fs.readBinary(path: "/definitely/not/here")
                Issue.record("expected the filesystem read to fail")
            } catch {
                // Expected — verify the resolver was never touched.
                #expect(r.reads.isEmpty)
            }
        }
    }
}
