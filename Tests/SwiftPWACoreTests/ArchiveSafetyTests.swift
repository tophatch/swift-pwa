import Foundation
@testable import SwiftPWACore
import Testing

@Suite("ArchiveSafety (path-traversal guard)")
struct ArchiveSafetyTests {
    private let root = URL(fileURLWithPath: "/tmp/packs/dest")

    @Test("accepts a normal nested entry")
    func acceptsNested() {
        let dest = ArchiveSafety.resolveDestination(entry: "pack/clip.webm", within: root)
        #expect(dest?.path == "/tmp/packs/dest/pack/clip.webm")
    }

    @Test("accepts the root entry itself")
    func acceptsRoot() {
        #expect(ArchiveSafety.resolveDestination(entry: "manifest.json", within: root) != nil)
    }

    @Test("rejects ../ traversal that escapes the root")
    func rejectsTraversal() {
        #expect(ArchiveSafety.resolveDestination(entry: "../evil.sh", within: root) == nil)
        #expect(ArchiveSafety.resolveDestination(entry: "pack/../../evil", within: root) == nil)
    }

    @Test("rejects absolute and drive-rooted entries")
    func rejectsAbsolute() {
        #expect(ArchiveSafety.resolveDestination(entry: "/etc/passwd", within: root) == nil)
        #expect(ArchiveSafety.resolveDestination(entry: "\\\\windows\\system32", within: root) == nil)
        #expect(ArchiveSafety.resolveDestination(entry: "C:\\evil", within: root) == nil)
    }

    @Test("internal ../ that stays within root is fine")
    func internalDotDotStaysInside() {
        // pack/sub/../keep.txt → pack/keep.txt, still inside root
        let dest = ArchiveSafety.resolveDestination(entry: "pack/sub/../keep.txt", within: root)
        #expect(dest?.path == "/tmp/packs/dest/pack/keep.txt")
    }
}
