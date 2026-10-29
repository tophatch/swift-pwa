import Foundation
#if os(Windows)
    import WinSDK // BeginUpdateResourceW / UpdateResourceW / EndUpdateResourceW
#endif

/// Writes resources into an already-linked `.exe`, preserving the ones
/// already there (the Common Controls manifest, an icon written earlier).
///
/// The Win32 update API lives in `kernel32`, so unlike `mt.exe` and `editbin`
/// it needs no tool on `PATH`. Rewriting resources drops everything after the
/// last section, which is why the COFF symbol table is carried across it
/// (#276).
enum WindowsResources {
    static let rtIcon: UInt16 = 3
    static let rtGroupIcon: UInt16 = 14
    static let rtVersion: UInt16 = 16
    static let rtManifest: UInt16 = 24

    struct Entry {
        var type: UInt16
        var id: UInt16
        var data: Data
    }

    enum UpdateError: Error, CustomStringConvertible {
        case notSupportedOnHost
        case beginFailed(UInt32)
        case updateFailed(UInt32)
        case endFailed(UInt32)

        var description: String {
            switch self {
            case .notSupportedOnHost: "editing an .exe's resources requires a Windows host"
            case let .beginFailed(code): "BeginUpdateResource failed (error \(code))"
            case let .updateFailed(code): "UpdateResource failed (error \(code))"
            case let .endFailed(code): "EndUpdateResource failed (error \(code))"
            }
        }
    }

    /// The COFF symbol table, carried across a resource update (#276).
    ///
    /// lld-link writes one after the last section: the string table that
    /// names each long-named section (`.debug_info`, and the rest of the DWARF
    /// a debugger reads) lives in it. The resource update API drops everything
    /// past the last section and leaves the COFF header pointing where the
    /// table was. Measured on an arm64 build: 7.8 MB gone, and `dumpbin` failing
    /// with `LNK1106: cannot seek`; `mt.exe` goes through the same API and did
    /// the same. Clearing the pointer isn't enough — the section headers still
    /// name themselves by string-table offset (`LNK1328: missing string
    /// table`) — so the table is read before the update and appended after it,
    /// with the pointer moved to where it now is.
    static func symbolTable(of exe: URL) throws -> Data? {
        let file = try FileHandle(forReadingFrom: exe)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        let header = try file.read(upToCount: 4096) ?? Data()
        guard let field = symbolTableField(header: header),
              danglingSymbolTableField(header: header, fileSize: size, stringTableSize: { at in
                  read32(file, at)
              }) == nil
        else { return nil }
        let pointer = UInt64(field.pointer)
        let strings = pointer + UInt64(field.symbols) * 18
        guard let length = read32(file, strings) else { return nil }
        try file.seek(toOffset: pointer)
        return try file.read(upToCount: Int(strings - pointer) + Int(length))
    }

    /// After an update: `table` appended and pointed at, when the update
    /// dropped it; the pointer cleared when there's nothing to put back.
    static func restoreSymbolTable(_ table: Data?, to exe: URL) throws {
        let file = try FileHandle(forUpdating: exe)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        let header = try file.read(upToCount: 4096) ?? Data()
        guard let offset = danglingSymbolTableField(header: header, fileSize: size, stringTableSize: { at in
            read32(file, at)
        }) else { return }
        guard let table, size + UInt64(table.count) < UInt64(UInt32.max) else {
            try file.seek(toOffset: UInt64(offset))
            try file.write(contentsOf: Data(count: 8))
            return
        }
        try file.seek(toOffset: size)
        try file.write(contentsOf: table)
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: Data((0 ..< 4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) }))
    }

    private static func read32(_ file: FileHandle, _ at: UInt64) -> UInt32? {
        try? file.seek(toOffset: at)
        return (try? file.read(upToCount: 4)).flatMap { $0.count == 4 ? $0 : nil }.map(littleEndian32)
    }

    /// The COFF header's `PointerToSymbolTable` and `NumberOfSymbols`, and
    /// where the pointer sits; nil when `header` isn't a PE or has no table.
    static func symbolTableField(header: Data) -> (offset: Int, pointer: UInt32, symbols: UInt32)? {
        let bytes = [UInt8](header)
        guard bytes.count >= 0x40 else { return nil }
        let pe = Int(littleEndian32(Data(bytes[0x3C ..< 0x40])))
        guard pe + 24 <= bytes.count, bytes[pe ..< pe + 4] == [0x50, 0x45, 0, 0] else { return nil }
        let field = pe + 12
        let pointer = littleEndian32(Data(bytes[field ..< field + 4]))
        guard pointer != 0 else { return nil }
        return (field, pointer, littleEndian32(Data(bytes[field + 4 ..< field + 8])))
    }

    /// Where `PointerToSymbolTable` sits in `header` when the table it names
    /// doesn't fit in a file of `fileSize` bytes; nil when there's none, or it
    /// fits. `stringTableSize` reads the 32-bit length at the start of the
    /// string table, which follows the 18-byte symbols.
    static func danglingSymbolTableField(
        header: Data, fileSize: UInt64, stringTableSize: (UInt64) -> UInt32?
    ) -> Int? {
        guard let field = symbolTableField(header: header) else { return nil }
        let strings = UInt64(field.pointer) + UInt64(field.symbols) * 18
        guard strings + 4 <= fileSize, let length = stringTableSize(strings),
              strings + UInt64(length) <= fileSize
        else {
            return field.offset
        }
        return nil
    }

    private static func littleEndian32(_ data: Data) -> UInt32 {
        data.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    /// Write every entry in one update pass. Language 0 (neutral), so a
    /// resource written here is the one a lookup finds whatever the user's
    /// locale. Throws `notSupportedOnHost` off Windows — the Windows bundler
    /// only runs there, so that branch is never reached in practice.
    static func update(_ exe: URL, with entries: [Entry]) throws {
        #if os(Windows)
            let symbols = try symbolTable(of: exe)
            let handle = exe.path.withCString(encodedAs: UTF16.self) { BeginUpdateResourceW($0, false) }
            guard let handle else { throw UpdateError.beginFailed(GetLastError()) }

            for entry in entries {
                // MAKEINTRESOURCE: an integer type or name travels as the
                // pointer value itself.
                let type = UnsafePointer<WCHAR>(bitPattern: Int(entry.type))
                let name = UnsafePointer<WCHAR>(bitPattern: Int(entry.id))
                let ok = entry.data.withUnsafeBytes { raw in
                    UpdateResourceW(
                        handle, type, name, 0,
                        UnsafeMutableRawPointer(mutating: raw.baseAddress), DWORD(raw.count)
                    )
                }
                if ok == false {
                    let code = GetLastError()
                    _ = EndUpdateResourceW(handle, true) // discard
                    throw UpdateError.updateFailed(code)
                }
            }

            if EndUpdateResourceW(handle, false) == false {
                throw UpdateError.endFailed(GetLastError())
            }
            try restoreSymbolTable(symbols, to: exe)
        #else
            _ = (exe, entries)
            throw UpdateError.notSupportedOnHost
        #endif
    }
}
