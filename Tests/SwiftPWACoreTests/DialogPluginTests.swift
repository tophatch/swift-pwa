import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("DialogPlugin")
@MainActor
struct DialogPluginTests {
    private func makeApp() -> (MockAppContext, MockDialog) {
        let app = MockAppContext()
        let dialog = MockDialog()
        app.use(DialogPlugin(dialog))
        return (app, dialog)
    }

    @Test("dialog.message forwards args and returns void")
    func message() async throws {
        let (app, dialog) = makeApp()
        let args = DialogMessageArgs(title: "Title", message: "Hi", kind: .warning)
        let inv = try Invocation(id: 1, command: "dialog.message", payload: JSONEncoder().encode(args))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        #expect(dialog.actions == [.message(args, parent: nil)])
    }

    @Test("dialog.message threads the originating WindowID through to the backend")
    func messagePropagatesParent() async throws {
        let (app, dialog) = makeApp()
        let originID = WindowID()
        let args = DialogMessageArgs(message: "Hi")
        let inv = try Invocation(id: 1, command: "dialog.message", payload: JSONEncoder().encode(args))
        let ctx = CommandContext(invocation: inv, originWindow: originID, appContext: app)
        _ = await app.registry.dispatch(ctx)
        #expect(dialog.actions == [.message(args, parent: originID)])
    }

    @Test("dialog.confirm returns the boolean from the backend")
    func confirmTrue() async throws {
        let (app, dialog) = makeApp()
        dialog.nextConfirm = true
        let args = DialogConfirmArgs(message: "Sure?", okLabel: "Yes", cancelLabel: "No")
        let inv = try Invocation(id: 1, command: "dialog.confirm", payload: JSONEncoder().encode(args))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogConfirmResult.self, from: data)
        #expect(out.ok == true)
        #expect(dialog.actions == [.confirm(args, parent: nil)])
    }

    @Test("dialog.confirm returns false when the user cancels")
    func confirmFalse() async throws {
        let (app, dialog) = makeApp()
        dialog.nextConfirm = false
        let inv = Invocation(
            id: 1,
            command: "dialog.confirm",
            payload: Data(#"{"message":"Sure?"}"#.utf8)
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogConfirmResult.self, from: data)
        #expect(out.ok == false)
    }

    @Test("dialog.openFile returns picked paths")
    func openFile() async throws {
        let (app, dialog) = makeApp()
        dialog.nextOpenFilePaths = ["/tmp/a.png", "/tmp/b.png"]
        let args = DialogOpenFileArgs(
            filters: [DialogFileFilter(name: "Images", extensions: ["png", "jpg"])],
            multiple: true
        )
        let inv = try Invocation(id: 1, command: "dialog.openFile", payload: JSONEncoder().encode(args))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogOpenFileResult.self, from: data)
        #expect(out.paths == ["/tmp/a.png", "/tmp/b.png"])
    }

    @Test("dialog.openFile returns an empty array when the user cancels")
    func openFileCancel() async throws {
        let (app, _) = makeApp()
        let inv = Invocation(id: 1, command: "dialog.openFile", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogOpenFileResult.self, from: data)
        #expect(out.paths == [])
    }

    @Test("dialog.saveFile returns the picked path or null")
    func saveFile() async throws {
        let (app, dialog) = makeApp()
        dialog.nextSaveFilePath = "/tmp/out.png"
        let inv = Invocation(
            id: 1,
            command: "dialog.saveFile",
            payload: Data(#"{"defaultName":"out.png"}"#.utf8)
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogPathResult.self, from: data)
        #expect(out.path == "/tmp/out.png")
    }

    @Test("dialog.saveFile cancel surfaces as null")
    func saveFileCancel() async throws {
        let (app, _) = makeApp()
        let inv = Invocation(id: 1, command: "dialog.saveFile", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogPathResult.self, from: data)
        #expect(out.path == nil)
    }

    @Test("dialog.exportFile forwards args and returns the destination path")
    func exportFile() async throws {
        let (app, dialog) = makeApp()
        dialog.nextExportFilePath = "/Users/me/Downloads/report.csv"
        let args = DialogExportFileArgs(defaultName: "report.csv", dataBase64: "aGk=")
        let inv = try Invocation(id: 1, command: "dialog.exportFile", payload: JSONEncoder().encode(args))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogPathResult.self, from: data)
        #expect(out.path == "/Users/me/Downloads/report.csv")
        #expect(dialog.actions == [.exportFile(args, parent: nil)])
    }

    @Test("dialog.exportFile cancel surfaces as null")
    func exportFileCancel() async throws {
        let (app, _) = makeApp()
        let inv = Invocation(
            id: 1,
            command: "dialog.exportFile",
            payload: Data(#"{"dataBase64":"aGk="}"#.utf8)
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogPathResult.self, from: data)
        #expect(out.path == nil)
    }

    @Test("dialog.openDirectory returns the picked path (with backward-compat `path`)")
    func openDirectory() async throws {
        let (app, dialog) = makeApp()
        dialog.nextOpenDirectoryPaths = ["/Users/me/Documents"]
        let inv = Invocation(id: 1, command: "dialog.openDirectory", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogOpenDirectoryResult.self, from: data)
        #expect(out.paths == ["/Users/me/Documents"])
        // Legacy single-path field mirrors the first selection.
        #expect(out.path == "/Users/me/Documents")
    }

    @Test("dialog.openDirectory honors `multiple` and returns every selection")
    func openDirectoryMultiple() async throws {
        let (app, dialog) = makeApp()
        dialog.nextOpenDirectoryPaths = ["/Users/me/A", "/Users/me/B"]
        let args = DialogOpenDirectoryArgs(multiple: true)
        let inv = try Invocation(id: 1, command: "dialog.openDirectory", payload: JSONEncoder().encode(args))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogOpenDirectoryResult.self, from: data)
        #expect(out.paths == ["/Users/me/A", "/Users/me/B"])
        #expect(out.path == "/Users/me/A")
        // The `multiple` flag reached the backend.
        guard case let .openDirectory(seen, _) = dialog.actions.first else {
            Issue.record("expected openDirectory action"); return
        }
        #expect(seen.multiple == true)
    }

    @Test("dialog.openDirectory returns an empty array when the user cancels")
    func openDirectoryCancel() async throws {
        let (app, _) = makeApp()
        let inv = Invocation(id: 1, command: "dialog.openDirectory", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogOpenDirectoryResult.self, from: data)
        #expect(out.paths == [])
        #expect(out.path == nil)
    }

    @Test("dialog.openDirectory carries a bookmark per picked path")
    func openDirectoryBookmarks() async throws {
        let (app, dialog) = makeApp()
        dialog.nextOpenDirectoryPaths = ["/Users/me/A", "/Users/me/B"]
        dialog.nextBookmarksByPath = ["/Users/me/A": "b1:AAA=", "/Users/me/B": "b1:BBB="]
        let inv = Invocation(id: 1, command: "dialog.openDirectory", payload: Data(#"{"multiple":true}"#.utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogOpenDirectoryResult.self, from: data)
        #expect(out.bookmarks == ["b1:AAA=", "b1:BBB="])
        // `bookmark` mirrors `path`, so a single-select caller reads one field.
        #expect(out.bookmark == "b1:AAA=")
        #expect(dialog.actions.contains(.makeBookmark(path: "/Users/me/B")))
    }

    @Test("a path the backend can't vouch for leaves a null in place, keeping indices aligned")
    func openFileBookmarksStayAligned() async throws {
        let (app, dialog) = makeApp()
        dialog.nextOpenFilePaths = ["/tmp/a.png", "/tmp/b.png"]
        dialog.nextBookmarksByPath = ["/tmp/b.png": "b1:BBB="]
        let inv = Invocation(id: 1, command: "dialog.openFile", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogOpenFileResult.self, from: data)
        #expect(out.paths == ["/tmp/a.png", "/tmp/b.png"])
        #expect(out.bookmarks == [nil, "b1:BBB="])
    }

    @Test("a cancelled pick has no bookmarks and asks the backend for none")
    func cancelledPickMintsNothing() async throws {
        let (app, dialog) = makeApp()
        let inv = Invocation(id: 1, command: "dialog.openDirectory", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogOpenDirectoryResult.self, from: data)
        #expect(out.bookmarks == [])
        #expect(out.bookmark == nil)
        #expect(!dialog.actions.contains { if case .makeBookmark = $0 { true } else { false } })
    }

    @Test("dialog.resolveBookmark hands back the location, and a refreshed token when stale")
    func resolveBookmark() async throws {
        let (app, dialog) = makeApp()
        dialog.nextResolveBookmark = DialogResolveBookmarkResult(
            path: "/Users/me/Moved",
            stale: true,
            bookmark: "b1:NEW="
        )
        let args = DialogResolveBookmarkArgs(bookmark: "b1:OLD=")
        let inv = try Invocation(id: 1, command: "dialog.resolveBookmark", payload: JSONEncoder().encode(args))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogResolveBookmarkResult.self, from: data)
        #expect(out.path == "/Users/me/Moved")
        #expect(out.stale == true)
        #expect(out.bookmark == "b1:NEW=")
        #expect(dialog.actions == [.resolveBookmark("b1:OLD=")])
    }

    @Test("a bookmark whose grant is gone resolves to a null path, not an error")
    func resolveBookmarkGone() async throws {
        let (app, dialog) = makeApp()
        dialog.nextResolveBookmark = DialogResolveBookmarkResult(path: nil)
        let inv = Invocation(
            id: 1,
            command: "dialog.resolveBookmark",
            payload: Data(#"{"bookmark":"b1:OLD="}"#.utf8)
        )
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogResolveBookmarkResult.self, from: data)
        #expect(out.path == nil)
        #expect(out.stale == false)
    }

    @Test("DialogKind round-trips through JSON as a string")
    func kindCodable() throws {
        let args = DialogMessageArgs(message: "x", kind: .error)
        let json = try JSONEncoder().encode(args)
        #expect(String(data: json, encoding: .utf8)?.contains("\"kind\":\"error\"") == true)
        let back = try JSONDecoder().decode(DialogMessageArgs.self, from: json)
        #expect(back.kind == .error)
    }
}

/// The path-token behaviour every filesystem-path platform inherits — the
/// GTK and Windows backends ship exactly this, so it's tested against a
/// `Dialog` that implements nothing but the picker requirements.
@Suite("Dialog bookmarks")
@MainActor
struct DialogBookmarkTests {
    /// A conformance that overrides none of the bookmark methods, standing
    /// in for the backends that have no grant to preserve.
    private final class PathOnlyDialog: Dialog, @unchecked Sendable {
        func message(_: DialogMessageArgs, parent _: WindowID?) async throws {}
        func confirm(_: DialogConfirmArgs, parent _: WindowID?) async throws -> Bool { true }
        func openFile(_: DialogOpenFileArgs, parent _: WindowID?) async throws -> [String] { [] }
        func saveFile(_: DialogSaveFileArgs, parent _: WindowID?) async throws -> String? { nil }
        func openDirectory(_: DialogOpenDirectoryArgs, parent _: WindowID?) async throws -> [String] { [] }
    }

    @Test("path tokens round-trip")
    func pathToken() throws {
        let token = DialogBookmark.token(path: "/Users/me/A Folder/with:colon")
        #expect(try DialogBookmark.payload(of: token) == .path("/Users/me/A Folder/with:colon"))
    }

    @Test("bookmark-data and URI tokens round-trip")
    func otherTokens() throws {
        let data = Data([0x00, 0x01, 0xFE, 0xFF])
        #expect(try DialogBookmark.payload(of: DialogBookmark.token(bookmarkData: data)) == .bookmarkData(data))
        let uri = "content://com.android.externalstorage.documents/tree/primary%3ADocs"
        #expect(try DialogBookmark.payload(of: DialogBookmark.token(uri: uri)) == .uri(uri))
    }

    @Test("a token we didn't mint is rejected rather than guessed at")
    func rejectsGarbage() {
        for bad in ["", "not-a-token", "z9:AAAA", "p1:!!!not-base64"] {
            #expect(throws: BridgeError.self) { try DialogBookmark.payload(of: bad) }
        }
    }

    @Test("the default backend mints a path token and resolves it if the location is still there")
    func pathDefaultRoundTrip() async throws {
        let dialog = PathOnlyDialog()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let token = try await dialog.makeBookmark(forPath: dir.path)
        #expect(token != nil)
        let resolved = try await dialog.resolveBookmark(#require(token))
        #expect(resolved.path == dir.path)
        #expect(resolved.stale == false)

        // Once the folder is gone the token stops resolving — which is the
        // app's cue to ask for a fresh pick.
        try FileManager.default.removeItem(at: dir)
        #expect(try await dialog.resolveBookmark(#require(token)).path == nil)
    }

    @Test("the default backend refuses a token from a platform whose grants it can't honour")
    func pathDefaultRejectsForeignToken() async throws {
        let dialog = PathOnlyDialog()
        await #expect(throws: BridgeError.self) {
            try await dialog.resolveBookmark(DialogBookmark.token(bookmarkData: Data([1, 2, 3])))
        }
    }
}
