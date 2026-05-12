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
        var nextRead: Result<Data, any Error> = .success(Data())
        var nextWrite: (any Error)?
        var nextMeta: Result<FsMetadata, any Error> = .success(
            FsMetadata(size: 0, isDir: false, isFile: true, modified: nil)
        )

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

    @Test("directory-style ops on content:// throw unsupported")
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
                _ = try await fs.readDir(path: "content://example/dir")
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
