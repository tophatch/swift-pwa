import Foundation
@testable import SwiftPWACore
import Testing

/// The Linux half of #263: a bundled binary learns its name from the
/// `.desktop` entry installed beside it.
@Suite("Desktop entry name")
struct DesktopEntryTests {
    @Test("reads the unlocalised Name of the main group")
    func mainGroupName() {
        let entry = """
        [Desktop Entry]
        Type=Application
        Name[fi]=Esimerkkilukija
        Name=Example Reader
        Exec=ExampleReader

        [Desktop Action new-window]
        Name=New Window
        """
        #expect(DesktopEntry.name(in: entry) == "Example Reader")
    }

    @Test("a Name outside [Desktop Entry] is not the app's")
    func actionGroupNameIgnored() {
        #expect(DesktopEntry.name(in: "[Desktop Action open]\nName=Open\n") == nil)
        #expect(DesktopEntry.name(in: "[Desktop Entry]\nNameless=x\n") == nil)
        #expect(DesktopEntry.name(in: "[Desktop Entry]\nName=\n") == nil)
    }

    @Test("applies the spec's escapes")
    func escapes() {
        #expect(DesktopEntry.name(in: "[Desktop Entry]\nName=A\\sB\\\\C\n") == "A B\\C")
    }

    @Test("finds the entry at <prefix>/share/applications beside <prefix>/bin")
    func installedLayout() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-entry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let applications = prefix.appendingPathComponent("share/applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true
        )
        let executable = prefix.appendingPathComponent("bin/ExampleReader")
        #expect(DesktopEntry.installedName(forExecutable: executable) == nil) // a `swift build` binary
        try "[Desktop Entry]\nName=Example Reader\n"
            .write(to: applications.appendingPathComponent("ExampleReader.desktop"), atomically: true, encoding: .utf8)
        #expect(DesktopEntry.installedName(forExecutable: executable) == "Example Reader")
    }
}
