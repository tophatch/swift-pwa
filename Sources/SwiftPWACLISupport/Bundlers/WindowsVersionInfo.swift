import Foundation

/// The `VS_VERSIONINFO` resource the Windows bundler writes into the `.exe`.
///
/// It is where Windows keeps a program's name and version — Explorer's Details
/// tab, Task Manager's description column and the "open with" list all read
/// it — and it is the Windows counterpart of the `Info.plist` a `.app`
/// carries. That matters beyond the shell: an unbundled binary otherwise has
/// only its executable name to answer `app.name` with, and a SwiftPM target
/// name can't contain a space, so an app called "Example Reader" put the user's
/// library in `Documents\ExampleReader` (#263). The runtime reads
/// `ProductName` back at startup. A resource rather than the `pwa.json` staged
/// beside the exe, because a single-file build has no `pwa.json` beside it.
enum WindowsVersionInfo {
    /// US English, Unicode — the pair nearly every Windows binary declares, and
    /// the one `\VarFileInfo\Translation` points a reader at.
    static let language: UInt16 = 0x0409
    static let codePage: UInt16 = 0x04B0

    static var stringTableKey: String {
        String(format: "%04X%04X", language, codePage)
    }

    /// The resource bytes for an app called `name` at `version`.
    /// `ProductName` and `FileDescription` both carry the name: the first is
    /// what the runtime reads, the second is what Task Manager shows.
    static func build(name: String, version: String, exeName: String) -> Data {
        let numeric = numericVersion(version)
        let strings = [
            ("CompanyName", ""),
            ("FileDescription", name),
            ("FileVersion", version),
            ("InternalName", exeName),
            ("OriginalFilename", exeName),
            ("ProductName", name),
            ("ProductVersion", version)
        ].filter { !$0.1.isEmpty }

        let table = node(
            key: stringTableKey, type: 1, value: Data(), valueLength: 0,
            children: strings.map { key, value in
                let text = utf16z(value)
                return node(key: key, type: 1, value: text, valueLength: UInt16(text.count / 2), children: [])
            }
        )
        let stringFileInfo = node(key: "StringFileInfo", type: 1, value: Data(), valueLength: 0, children: [table])

        var translation = Data()
        append(&translation, language)
        append(&translation, codePage)
        let varFileInfo = node(
            key: "VarFileInfo", type: 1, value: Data(), valueLength: 0,
            children: [node(key: "Translation", type: 0, value: translation, valueLength: 4, children: [])]
        )

        let fixed = fixedFileInfo(numeric)
        return node(
            key: "VS_VERSION_INFO", type: 0, value: fixed, valueLength: UInt16(fixed.count),
            children: [stringFileInfo, varFileInfo]
        )
    }

    /// `"1.2.3"` → `(1, 2, 3, 0)`. Reads up to the first character that is
    /// neither a digit nor a dot, so a semver pre-release (`"2.0.0-beta.1"`)
    /// is 2.0.0 rather than 2.0.0.1; the string fields keep the original
    /// spelling. Missing parts are 0, and each clamps to 16 bits.
    static func numericVersion(_ version: String) -> (UInt16, UInt16, UInt16, UInt16) {
        let numeric = version.prefix { ($0.isASCII && $0.isNumber) || $0 == "." }
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false).prefix(4).map {
            UInt16(clamping: Int($0) ?? 0)
        }
        func at(_ i: Int) -> UInt16 {
            i < parts.count ? parts[i] : 0
        }
        return (at(0), at(1), at(2), at(3))
    }

    // MARK: - Layout

    /// `VS_FIXEDFILEINFO`: signature, structure version, file and product
    /// version as two DWORDs each, then flags, OS (`VOS_NT_WINDOWS32`), type
    /// (`VFT_APP`) and an unused date.
    private static func fixedFileInfo(_ v: (UInt16, UInt16, UInt16, UInt16)) -> Data {
        let ms = UInt32(v.0) << 16 | UInt32(v.1)
        let ls = UInt32(v.2) << 16 | UInt32(v.3)
        var data = Data()
        for value: UInt32 in [0xFEEF_04BD, 0x0001_0000, ms, ls, ms, ls, 0x3F, 0, 0x0004_0004, 1, 0, 0, 0] {
            append(&data, value)
        }
        return data
    }

    /// One block of the version tree: `wLength`, `wValueLength`, `wType`, the
    /// NUL-terminated UTF-16 key, padding to 32 bits, the value, then each
    /// child on a 32-bit boundary. `wLength` covers the children but not
    /// padding after the last one; `wValueLength` is in bytes for binary
    /// values and in WCHARs for text, which is why the caller passes it.
    private static func node(key: String, type: UInt16, value: Data, valueLength: UInt16, children: [Data]) -> Data {
        var data = Data(count: 6)
        data.append(utf16z(key))
        pad(&data)
        data.append(value)
        for child in children {
            pad(&data)
            data.append(child)
        }
        write(&data, UInt16(data.count), at: 0)
        write(&data, valueLength, at: 2)
        write(&data, type, at: 4)
        return data
    }

    private static func utf16z(_ string: String) -> Data {
        var data = Data()
        for unit in string.utf16 {
            append(&data, unit)
        }
        append(&data, UInt16(0))
        return data
    }

    private static func pad(_ data: inout Data) {
        while data.count % 4 != 0 {
            data.append(0)
        }
    }

    private static func append(_ data: inout Data, _ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func write(_ data: inout Data, _ value: UInt16, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8(value >> 8)
    }
}
