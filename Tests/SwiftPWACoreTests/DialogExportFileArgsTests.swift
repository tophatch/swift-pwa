import Foundation
@testable import SwiftPWACore
import Testing

@Suite("DialogExportFileArgs content resolution")
struct DialogExportFileArgsTests {
    @Test("resolveData decodes inline base64")
    func resolveInline() throws {
        let args = DialogExportFileArgs(dataBase64: Data("hello".utf8).base64EncodedString())
        #expect(try args.resolveData() == Data("hello".utf8))
    }

    @Test("resolveData reads an on-disk path")
    func resolvePath() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("on disk".utf8).write(to: tmp)
        let args = DialogExportFileArgs(path: tmp.path)
        #expect(try args.resolveData() == Data("on disk".utf8))
    }

    @Test("resolveData rejects neither/both/invalid")
    func resolveErrors() {
        #expect(throws: BridgeError.self) { try DialogExportFileArgs().resolveData() }
        #expect(throws: BridgeError.self) {
            try DialogExportFileArgs(path: "/x", dataBase64: "aGk=").resolveData()
        }
        #expect(throws: BridgeError.self) {
            try DialogExportFileArgs(dataBase64: "not valid base64!!!").resolveData()
        }
    }

    @Test("suggestedName prefers defaultName, then source basename, then export")
    func suggestedName() {
        #expect(DialogExportFileArgs(defaultName: "a.csv").suggestedName == "a.csv")
        #expect(DialogExportFileArgs(path: "/tmp/data/b.json").suggestedName == "b.json")
        #expect(DialogExportFileArgs(dataBase64: "aGk=").suggestedName == "export")
    }

    @Test("materializeTempFile writes inline bytes; returns source path untouched")
    func materialize() throws {
        // Inline → a real temp file containing the bytes.
        let inline = DialogExportFileArgs(defaultName: "note.txt", dataBase64: Data("hi".utf8).base64EncodedString())
        let tempURL = try inline.materializeTempFile()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
        #expect(tempURL.lastPathComponent == "note.txt")
        #expect(try Data(contentsOf: tempURL) == Data("hi".utf8))

        // Path → the same URL, no copy.
        let onDisk = DialogExportFileArgs(path: "/tmp/already/there.txt")
        #expect(try onDisk.materializeTempFile().path == "/tmp/already/there.txt")
    }
}
