import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("FsPlugin")
@MainActor
struct FsPluginTests {
    private func makeApp() -> (MockAppContext, MockFs) {
        let app = MockAppContext()
        let fs = MockFs()
        app.use(FsPlugin(fs))
        return (app, fs)
    }

    private func dispatch(_ app: MockAppContext, _ command: String, _ payload: String) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data(payload.utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    @Test("fs.readText returns the file contents")
    func readText() async throws {
        let (app, fs) = makeApp()
        fs.files["/x.txt"] = Data("hello".utf8)
        let result = await dispatch(app, "fs.readText", #"{"path":"/x.txt"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(FsTextResult.self, from: data)
        #expect(out.contents == "hello")
        #expect(fs.actions == [.readText(path: "/x.txt")])
    }

    @Test("fs.writeText stores the contents and reports an empty result")
    func writeText() async {
        let (app, fs) = makeApp()
        let result = await dispatch(app, "fs.writeText", #"{"path":"/y.txt","contents":"hi"}"#)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(fs.files["/y.txt"] == Data("hi".utf8))
    }

    @Test("fs.readBinary base64-encodes the bytes")
    func readBinary() async throws {
        let (app, fs) = makeApp()
        fs.files["/bin"] = Data([0x00, 0x01, 0x02, 0xFF])
        let result = await dispatch(app, "fs.readBinary", #"{"path":"/bin"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(FsBinaryResult.self, from: data)
        #expect(Data(base64Encoded: out.dataBase64) == Data([0x00, 0x01, 0x02, 0xFF]))
    }

    @Test("fs.writeBinary decodes base64 and stores the bytes")
    func writeBinary() async {
        let (app, fs) = makeApp()
        let payload = #"{"path":"/bin","dataBase64":"AAH/"}"#
        let result = await dispatch(app, "fs.writeBinary", payload)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(fs.files["/bin"] == Data([0x00, 0x01, 0xFF]))
    }

    @Test("fs.writeBinary rejects malformed base64 with a decode error")
    func writeBinaryBadBase64() async {
        let (app, _) = makeApp()
        let result = await dispatch(app, "fs.writeBinary", #"{"path":"/x","dataBase64":"!!!"}"#)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.message.contains("base64"))
    }

    @Test("fs.exists reports presence")
    func exists() async throws {
        let (app, fs) = makeApp()
        fs.files["/here"] = Data()
        let yes = await dispatch(app, "fs.exists", #"{"path":"/here"}"#)
        let no = await dispatch(app, "fs.exists", #"{"path":"/missing"}"#)
        guard case let .ok(yesData) = yes, case let .ok(noData) = no else {
            Issue.record("expected ok"); return
        }
        #expect(try JSONDecoder().decode(FsExistsResult.self, from: yesData).exists == true)
        #expect(try JSONDecoder().decode(FsExistsResult.self, from: noData).exists == false)
    }

    @Test("fs.mkdir defaults recursive to false")
    func mkdirDefault() async {
        let (app, fs) = makeApp()
        _ = await dispatch(app, "fs.mkdir", #"{"path":"/d"}"#)
        #expect(fs.actions == [.mkdir(path: "/d", recursive: false)])
    }

    @Test("fs.mkdir honours recursive when set")
    func mkdirRecursive() async {
        let (app, fs) = makeApp()
        _ = await dispatch(app, "fs.mkdir", #"{"path":"/a/b/c","recursive":true}"#)
        #expect(fs.actions == [.mkdir(path: "/a/b/c", recursive: true)])
    }

    @Test("fs.remove forwards path and recursive flag")
    func remove() async {
        let (app, fs) = makeApp()
        _ = await dispatch(app, "fs.remove", #"{"path":"/d","recursive":true}"#)
        #expect(fs.actions == [.remove(path: "/d", recursive: true)])
    }

    @Test("fs.readDir returns entries")
    func readDir() async throws {
        let (app, fs) = makeApp()
        fs.nextReadDir["/d"] = [
            FsEntry(name: "a.txt", path: "/d/a.txt", isDir: false, isFile: true),
            FsEntry(name: "sub", path: "/d/sub", isDir: true, isFile: false)
        ]
        let result = await dispatch(app, "fs.readDir", #"{"path":"/d"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(FsReadDirResult.self, from: data)
        #expect(out.entries.count == 2)
        #expect(out.entries.first?.name == "a.txt")
        #expect(out.entries.last?.isDir == true)
    }

    @Test("fs.copy and fs.rename forward both paths")
    func copyAndRename() async {
        let (app, fs) = makeApp()
        fs.files["/src"] = Data("data".utf8)
        _ = await dispatch(app, "fs.copy", #"{"from":"/src","to":"/dst"}"#)
        _ = await dispatch(app, "fs.rename", #"{"from":"/dst","to":"/final"}"#)
        #expect(fs.files["/src"] == Data("data".utf8))
        #expect(fs.files["/final"] == Data("data".utf8))
        #expect(fs.files["/dst"] == nil)
    }

    @Test("fs.metadata returns FsMetadata directly")
    func metadata() async throws {
        let (app, fs) = makeApp()
        fs.files["/file"] = Data(repeating: 0, count: 42)
        let result = await dispatch(app, "fs.metadata", #"{"path":"/file"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(FsMetadata.self, from: data)
        #expect(out.size == 42)
        #expect(out.isFile == true)
        #expect(out.isDir == false)
    }
}

/// Integration smoke test: drive `SystemFs` against a temp directory.
@Suite("SystemFs")
struct SystemFsTests {
    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swift-pwa-fs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("round-trips text through the real filesystem")
    func roundTripText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = SystemFs()
        let path = dir.appendingPathComponent("hello.txt").path
        try await fs.writeText(path: path, contents: "world")
        let read = try await fs.readText(path: path)
        #expect(read == "world")
    }

    @Test("readDir lists entries in deterministic order")
    func readDirSorted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = SystemFs()
        for name in ["c", "a", "b"] {
            try await fs.writeText(path: dir.appendingPathComponent(name).path, contents: "x")
        }
        let entries = try await fs.readDir(path: dir.path)
        #expect(entries.map(\.name) == ["a", "b", "c"])
        let allFiles = entries.allSatisfy(\.isFile)
        #expect(allFiles)
    }

    @Test("metadata reports size and modification time")
    func metadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = SystemFs()
        let path = dir.appendingPathComponent("m").path
        try await fs.writeText(path: path, contents: "abcdef")
        let m = try await fs.metadata(path: path)
        #expect(m.size == 6)
        #expect(m.isFile == true)
        #expect(m.modified != nil)
    }

    @Test("remove refuses non-empty directories without recursive")
    func removeNonEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = SystemFs()
        let sub = dir.appendingPathComponent("d").path
        try await fs.mkdir(path: sub, recursive: false)
        try await fs.writeText(path: sub + "/inner.txt", contents: "x")
        await #expect(throws: BridgeError.self) {
            try await fs.remove(path: sub, recursive: false)
        }
        try await fs.remove(path: sub, recursive: true)
        #expect(try await fs.exists(path: sub) == false)
    }
}
