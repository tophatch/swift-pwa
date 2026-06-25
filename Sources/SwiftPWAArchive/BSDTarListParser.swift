import Foundation
import SwiftPWACore

/// Parses `bsdtar -tvf` (a.k.a. `tar.exe` on Windows 10 1803+, which is
/// libarchive's bsdtar) verbose listing output into `ArchiveEntry` records.
///
/// Factored out of `WindowsZIPExtractor` so the parsing — the brittle part —
/// is unit-testable on any host (macOS `/usr/bin/tar` is the same libarchive
/// bsdtar, so tests drive it against real output). The `Process` invocation
/// that produces the output stays Windows-gated in the extractor.
///
/// A verbose line looks like:
/// ```
/// -rw-r--r--  0 501    20         12 Jun 25 10:00 path/with spaces.txt
/// drwxr-xr-x  0 501    20          0 Jun 25 10:00 dir/
/// lrwxrwxrwx  0 501    20          3 Jun 25 10:00 link -> target
/// ```
/// i.e. `perms links owner group size month day time name…`. The name is
/// everything after the time field and may contain spaces; a symlink line
/// has a `name -> target` tail we strip.
enum BSDTarListParser {
    static func parse(_ output: String) -> [ArchiveEntry] {
        output.split(separator: "\n").compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ raw: String) -> ArchiveEntry? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        // Permissions token is the first field; its first char encodes the
        // type ('d' dir, 'l' symlink, '-' regular).
        let typeChar = line.first!
        guard typeChar == "d" || typeChar == "l" || typeChar == "-" else { return nil }

        // Split off the leading 8 metadata fields (perms, links, owner,
        // group, size, month, day, time); the remainder is the name. Owner
        // and group can be names or numbers, but there are always exactly 8
        // whitespace-delimited fields before the name in bsdtar's format.
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 9 else { return nil }
        guard let size = Int64(fields[4]) else { return nil }

        // Reconstruct the name by dropping the first 8 fields from the
        // original (whitespace-collapsed) line, so names with spaces survive.
        let collapsed = fields.joined(separator: " ")
        let metaPrefix = fields.prefix(8).joined(separator: " ")
        var name = String(collapsed.dropFirst(metaPrefix.count)).trimmingCharacters(in: .whitespaces)

        let isSymlink = typeChar == "l"
        if isSymlink, let arrow = name.range(of: " -> ") {
            name = String(name[name.startIndex ..< arrow.lowerBound])
        }
        let isDirectory = typeChar == "d" || name.hasSuffix("/")
        if isDirectory, name.hasSuffix("/") { name.removeLast() }
        guard !name.isEmpty else { return nil }

        return ArchiveEntry(
            path: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            uncompressedSize: size,
            // bsdtar's listing doesn't expose the per-entry compressed size;
            // the ratio guard degrades to "size only" on Windows (still
            // bounded by maxUncompressedBytes / maxEntries).
            compressedSize: size
        )
    }
}
