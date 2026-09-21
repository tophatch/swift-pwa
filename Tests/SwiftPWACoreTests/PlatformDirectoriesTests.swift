import Foundation
@testable import SwiftPWACore
import Testing

/// The user-visible documents location (#250), and the Linux half of it that
/// would otherwise only be exercised on a box with a desktop session.
@Suite("PlatformDirectories")
struct PlatformDirectoriesTests {
    // MARK: - Linux user-dirs parsing

    /// `xdg-user-dirs-update` writes shell-ish assignments relative to `$HOME`.
    @Test("XDG_DOCUMENTS_DIR is read out of user-dirs.dirs, expanded against HOME")
    func userDirsBasic() {
        let text = """
        # This file is written by xdg-user-dirs-update
        XDG_DESKTOP_DIR="$HOME/Desktop"
        XDG_DOCUMENTS_DIR="$HOME/Documents"
        XDG_DOWNLOAD_DIR="$HOME/Downloads"
        """
        #expect(
            PlatformDirectories.documentsDirFromUserDirs(text, home: "/home/ben") == "/home/ben/Documents"
        )
    }

    /// A localised install writes a localised folder name, which is the whole
    /// reason for reading the file rather than assuming `~/Documents`.
    @Test("a localised folder name is honoured")
    func userDirsLocalised() {
        let text = #"XDG_DOCUMENTS_DIR="$HOME/Asiakirjat""#
        #expect(
            PlatformDirectories.documentsDirFromUserDirs(text, home: "/home/ben") == "/home/ben/Asiakirjat"
        )
    }

    @Test("an absolute path is taken as-is")
    func userDirsAbsolute() {
        let text = #"XDG_DOCUMENTS_DIR="/mnt/shelf/docs""#
        #expect(
            PlatformDirectories.documentsDirFromUserDirs(text, home: "/home/ben") == "/mnt/shelf/docs"
        )
    }

    /// A commented-out line is not an assignment — reading one would send an
    /// app to a folder the user explicitly turned off.
    @Test("a commented line is ignored, and a missing key reports nil")
    func userDirsCommentsAndAbsence() {
        #expect(PlatformDirectories.documentsDirFromUserDirs(
            "#XDG_DOCUMENTS_DIR=\"$HOME/Documents\"", home: "/home/ben"
        ) == nil)
        #expect(PlatformDirectories.documentsDirFromUserDirs(
            "XDG_DESKTOP_DIR=\"$HOME/Desktop\"", home: "/home/ben"
        ) == nil)
        // `XDG_DOCUMENTS_DIR="$HOME/"` means "disabled" in the spec's own
        // wording; an empty value must not resolve to the home directory.
        #expect(PlatformDirectories.documentsDirFromUserDirs(
            "XDG_DOCUMENTS_DIR=\"\"", home: "/home/ben"
        ) == nil)
    }

    // MARK: - The location itself

    @Test("documentsDirectory is created, user-visible, and not the app's container")
    func documentsDirectory() {
        let name = "SwiftPWAPlatformDirsTest"
        let docs = PlatformDirectories.documentsDirectory(appName: name)
        defer {
            if (try? FileManager.default.contentsOfDirectory(atPath: docs.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: docs)
            }
        }
        #expect(docs.lastPathComponent == name)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        // The private containers are scoped by bundle id and live elsewhere;
        // confusing the two is what this location exists to stop.
        #expect(docs.path != PlatformDirectories.dataDirectory(appID: name).path)
        #expect(docs.path != PlatformDirectories.cacheDirectory(appID: name).path)
    }

    /// The display name reaches the filesystem here, and since #254 it can come
    /// from the environment — so a name has to stop being able to change the
    /// folder's depth.
    @Test("a name becomes exactly one folder, whatever is in it")
    func documentsLeafIsOneComponent() {
        #expect(PlatformDirectories.documentsLeaf("Aether Reader") == "Aether Reader")
        // Separators would otherwise put the library somewhere else entirely.
        #expect(PlatformDirectories.documentsLeaf("../../evil") == "..-..-evil")
        #expect(PlatformDirectories.documentsLeaf("a\\b") == "a-b")
        #expect(PlatformDirectories.documentsLeaf("..") == "App")
        #expect(PlatformDirectories.documentsLeaf(".") == "App")
        #expect(PlatformDirectories.documentsLeaf("   ") == "App")
        #expect(PlatformDirectories.documentsLeaf("") == "App")
        // Reserved on Windows, so they go the same way everywhere — one folder
        // name per app, not one per platform.
        #expect(PlatformDirectories.documentsLeaf("Reader: Pro") == "Reader- Pro")
        #expect(PlatformDirectories.documentsLeaf("Who?") == "Who-")
        // Windows strips a trailing dot, which would silently merge two names.
        #expect(PlatformDirectories.documentsLeaf("Reader.") == "Reader")
        #expect(PlatformDirectories.documentsLeaf("Reader\n") == "Reader")
    }

    /// iOS is the one platform where the visible folder goes with the app, and
    /// an app that doesn't know will promise the user something false.
    @Test("survivesUninstall is false on iOS alone")
    func survivesUninstall() {
        #if os(iOS)
            #expect(PlatformDirectories.documentsSurviveUninstall == false)
        #else
            #expect(PlatformDirectories.documentsSurviveUninstall == true)
        #endif
    }
}
