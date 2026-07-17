import Foundation
#if canImport(FoundationXML)
    // On swift-corelibs Foundation (Linux / Windows) XMLParser lives in the
    // separate FoundationXML module; on Apple it's part of Foundation.
    import FoundationXML
#endif
@testable import SwiftPWACLISupport
import Testing

@Suite("File-type association declaration")
struct FileAssociationTests {
    private func manifest(
        linuxDocs: [PWAManifest.MimeDocumentType]? = nil,
        windowsDocs: [PWAManifest.ExtensionDocumentType]? = nil
    ) -> PWAManifest {
        var m = PWAManifest(
            id: "com.example.myapp",
            name: "My App",
            executableName: nil,
            version: "1.2.3",
            description: "An app.",
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "My App")
        )
        if let linuxDocs { m.linux = .init(desktopCategories: nil, executableName: nil, documentTypes: linuxDocs) }
        if let windowsDocs { m.windows = .init(documentTypes: windowsDocs) }
        return m
    }

    // MARK: - Linux .desktop

    @Test("no doc types → bare Exec, no MimeType (unchanged)")
    func desktopNoDocTypes() {
        let entry = AppImageBundler.desktopEntry(manifest: manifest(), exeName: "myapp")
        #expect(entry.contains("Exec=myapp\n"))
        #expect(!entry.contains("%F"))
        #expect(!entry.contains("MimeType="))
    }

    @Test("doc types → MimeType list + %F field code")
    func desktopWithDocTypes() {
        let entry = AppImageBundler.desktopEntry(
            manifest: manifest(linuxDocs: [.init(mimeTypes: ["image/png", "application/pdf"])]),
            exeName: "myapp"
        )
        #expect(entry.contains("Exec=myapp %F"))
        #expect(entry.contains("MimeType=image/png;application/pdf;"))
    }

    @Test("multiple linux doc-type entries flatten into one MimeType list")
    func desktopMultipleGroups() {
        let entry = AppImageBundler.desktopEntry(
            manifest: manifest(linuxDocs: [
                .init(mimeTypes: ["image/png"]),
                .init(mimeTypes: ["text/plain"])
            ]),
            exeName: "myapp"
        )
        #expect(entry.contains("MimeType=image/png;text/plain;"))
    }

    // MARK: - Windows MSIX

    @Test("no windows doc types → no FileTypeAssociation extension")
    func msixNoDocTypes() {
        let xml = AppxManifestGenerator.render(manifest: manifest())
        #expect(!xml.contains("fileTypeAssociation"))
        #expect(!xml.contains("<Extensions>"))
    }

    @Test("windows doc types → a FileTypeAssociation per group with normalized file types")
    func msixWithDocTypes() {
        let xml = AppxManifestGenerator.render(manifest: manifest(windowsDocs: [
            .init(extensions: ["FOO", ".bar"], name: "My Docs")
        ]))
        #expect(xml.contains("<Extensions>"))
        #expect(xml.contains("Category=\"windows.fileTypeAssociation\""))
        // Association name is sanitized (lowercased, no spaces).
        #expect(xml.contains("<uap:FileTypeAssociation Name=\"mydocs\">"))
        // Extensions normalized to lowercase + leading dot.
        #expect(xml.contains("<uap:FileType>.foo</uap:FileType>"))
        #expect(xml.contains("<uap:FileType>.bar</uap:FileType>"))
        // The whole manifest must remain well-formed XML with the extension spliced in.
        #expect(isWellFormedXML(xml), "generated AppxManifest is not well-formed XML")
    }

    /// Parse `xml` with Foundation's `XMLParser` to catch malformed nesting the
    /// string `contains` checks would miss.
    private func isWellFormedXML(_ xml: String) -> Bool {
        final class Delegate: NSObject, XMLParserDelegate {}
        let parser = XMLParser(data: Data(xml.utf8))
        let delegate = Delegate()
        parser.delegate = delegate
        return parser.parse()
    }

    @Test("unnamed windows doc type gets an auto-numbered association name")
    func msixAutoName() {
        let xml = AppxManifestGenerator.render(manifest: manifest(windowsDocs: [
            .init(extensions: [".foo"])
        ]))
        #expect(xml.contains("Name=\"filetype1\""))
    }

    // MARK: - Windows portable registration scripts

    @Test("registration scripts point HKCU classes at the exe via %~dp0")
    func portableScripts() throws {
        let scripts = try #require(FileAssociationSupport.registrationScripts(
            docTypes: [.init(extensions: ["foo"], name: "My Docs")],
            exeName: "MyApp.exe",
            appID: "com.example.myapp",
            appName: "My App"
        ))
        let reg = scripts.register.joined(separator: "\n")
        // The exe path is resolved at run time from the script's own folder.
        #expect(reg.contains("set \"EXE=%~dp0MyApp.exe\""))
        // ProgID derived from app id + association name; extension mapped to it.
        #expect(reg.contains("com.example.myapp.mydocs"))
        #expect(reg.contains("HKCU\\Software\\Classes\\.foo"))
        #expect(reg.contains("open\\command"))
        // Unregister mirrors with deletes.
        let unreg = scripts.unregister.joined(separator: "\n")
        #expect(unreg.contains("reg delete"))
        #expect(unreg.contains("HKCU\\Software\\Classes\\.foo"))
    }

    @Test("no windows doc types → no registration scripts")
    func portableNoScripts() {
        #expect(FileAssociationSupport.registrationScripts(
            docTypes: [], exeName: "MyApp.exe", appID: "com.example.myapp", appName: "My App"
        ) == nil)
    }

    // MARK: - Normalization

    @Test("extension normalization: dot, case, dedupe, invalid stripped")
    func normalization() {
        let out = FileAssociationSupport.normalizedExtensions(["FOO", ".foo", " .Bar ", "", ".", "b*z"])
        #expect(out == [".foo", ".bar", ".bz"])
    }
}
