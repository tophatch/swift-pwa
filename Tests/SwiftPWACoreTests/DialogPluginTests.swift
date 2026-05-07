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

    @Test("dialog.openDirectory returns the picked path")
    func openDirectory() async throws {
        let (app, dialog) = makeApp()
        dialog.nextOpenDirectoryPath = "/Users/me/Documents"
        let inv = Invocation(id: 1, command: "dialog.openDirectory", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(DialogPathResult.self, from: data)
        #expect(out.path == "/Users/me/Documents")
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
