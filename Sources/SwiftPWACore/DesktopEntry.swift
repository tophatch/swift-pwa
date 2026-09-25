import Foundation

/// Reads the name out of the freedesktop `.desktop` entry installed beside a
/// Linux binary — the closest thing Linux has to the `Info.plist` a `.app`
/// carries.
///
/// The AppImage bundler writes `usr/share/applications/<exe>.desktop` next to
/// `usr/bin/<exe>` with `Name=` taken from `pwa.json`, and a distro package
/// puts them in the same relative places under `/usr`. So the runtime can
/// learn the name the bundler knew without trusting anything but files that
/// shipped with the binary (#263).
package enum DesktopEntry {
    /// `<prefix>/bin/<exe>` → `<prefix>/share/applications/<exe>.desktop`'s
    /// name, or `nil` when there is no such file — a `swift build` binary.
    package static func installedName(forExecutable executable: URL) -> String? {
        let entry = executable
            .deletingLastPathComponent() // bin
            .deletingLastPathComponent() // prefix
            .appendingPathComponent("share/applications")
            .appendingPathComponent(executable.lastPathComponent + ".desktop")
        guard let contents = try? String(contentsOf: entry, encoding: .utf8) else { return nil }
        return name(in: contents)
    }

    /// The unlocalised `Name=` of the `[Desktop Entry]` group. A localised
    /// `Name[fi]=` is a translation, not the name, and a `Name=` in an action
    /// group names the action.
    package static func name(in contents: String) -> String? {
        var inMainGroup = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inMainGroup = line == "[Desktop Entry]"
                continue
            }
            guard inMainGroup, line.hasPrefix("Name") else { continue }
            let key = line.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
            guard key == "Name", let equals = line.firstIndex(of: "=") else { continue }
            let value = unescape(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The spec's string escapes: `\s`, `\n`, `\t`, `\r`, `\\`.
    private static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var out = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                out.append(character)
                continue
            }
            switch next {
            case "s": out.append(" ")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            default: out.append(next)
            }
        }
        return out
    }
}
