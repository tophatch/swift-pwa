import Foundation

/// The DLLs a Windows executable imports, read straight out of its PE import
/// table.
///
/// Read here rather than asked of `dumpbin`, which can't open a bundled exe
/// once its resources have been rewritten (`LNK1106 … cannot seek`) and, asked
/// anyway, returns an error that an import check then reads as "imports
/// nothing". Pure byte parsing, so it compiles and is tested on every host
/// even though only a Windows build ever calls it.
///
/// Direct imports only. A delay-loaded DLL isn't needed to start, and nothing
/// the bundler stages is delay-loaded.
enum PEImports {
    enum ReadError: Error, CustomStringConvertible, Equatable {
        case notPE(String)
        case truncated(String)

        var description: String {
            switch self {
            case let .notPE(why): "not a PE image: \(why)"
            case let .truncated(what): "PE image ends inside its \(what)"
            }
        }
    }

    /// Imported DLL names in table order, as the image spells them.
    static func dllNames(in data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        func u16(_ offset: Int, _ what: String) throws -> Int {
            guard offset >= 0, offset + 2 <= bytes.count else { throw ReadError.truncated(what) }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int, _ what: String) throws -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { throw ReadError.truncated(what) }
            return (0 ..< 4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }

        guard bytes.count >= 64, bytes[0] == 0x4D, bytes[1] == 0x5A else { throw ReadError.notPE("no MZ header") }
        let pe = try u32(0x3C, "DOS header")
        guard try u32(pe, "PE signature") == 0x0000_4550 else { throw ReadError.notPE("no PE signature") }
        let sectionCount = try u16(pe + 6, "COFF header")
        let optionalSize = try u16(pe + 20, "COFF header")
        let optional = pe + 24

        // The data directories sit at a different offset in PE32 and PE32+.
        let directories: Int
        let directoryCount: Int
        switch try u16(optional, "optional header") {
        case 0x10B: (directories, directoryCount) = try (optional + 96, u32(optional + 92, "optional header"))
        case 0x20B: (directories, directoryCount) = try (optional + 112, u32(optional + 108, "optional header"))
        case let magic: throw ReadError.notPE("unknown optional-header magic 0x\(String(magic, radix: 16))")
        }
        guard directoryCount > 1 else { return [] }
        let importRVA = try u32(directories + 8, "data directories")
        guard importRVA != 0 else { return [] }

        struct Section { let address: Int, size: Int, fileOffset: Int }
        var sections: [Section] = []
        let table = optional + optionalSize
        for index in 0 ..< sectionCount {
            let header = table + index * 40
            let virtualSize = try u32(header + 8, "section table")
            let rawSize = try u32(header + 16, "section table")
            try sections.append(Section(
                address: u32(header + 12, "section table"),
                size: max(virtualSize, rawSize),
                fileOffset: u32(header + 20, "section table")
            ))
        }
        func fileOffset(_ rva: Int, _ what: String) throws -> Int {
            guard let section = sections.first(where: { rva >= $0.address && rva < $0.address + $0.size }) else {
                throw ReadError.truncated(what)
            }
            return rva - section.address + section.fileOffset
        }

        var names: [String] = []
        var descriptor = try fileOffset(importRVA, "import table")
        // Bounded: a corrupt table without its all-zero terminator must end.
        while names.count < 4096 {
            let nameRVA = try u32(descriptor + 12, "import table")
            if nameRVA == 0 { break }
            var cursor = try fileOffset(nameRVA, "import names")
            var name: [UInt8] = []
            while cursor < bytes.count, bytes[cursor] != 0, name.count < 260 {
                name.append(bytes[cursor])
                cursor += 1
            }
            names.append(String(decoding: name, as: UTF8.self))
            descriptor += 20
        }
        return names
    }
}
