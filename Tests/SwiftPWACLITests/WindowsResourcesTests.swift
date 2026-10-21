import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("Windows resources")
struct WindowsResourcesTests {
    /// A PE header: the DOS stub's `e_lfanew` at 0x3C, `PE\0\0` at 0x80, then
    /// the COFF header with `PointerToSymbolTable` / `NumberOfSymbols`.
    private func header(pointer: UInt32, symbols: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        bytes[0x3C] = 0x80
        bytes[0x80 ..< 0x84] = [0x50, 0x45, 0, 0]
        for (index, value) in [pointer, symbols].enumerated() {
            for byte in 0 ..< 4 {
                bytes[0x8C + index * 4 + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte)))
            }
        }
        return Data(bytes)
    }

    @Test("a symbol table the file no longer holds is found, so it can be cleared (#276)")
    func danglingSymbolTable() {
        // What a resource update leaves: the pointer past the end of the file.
        #expect(WindowsResources.danglingSymbolTableField(
            header: header(pointer: 0x1D07600, symbols: 0x13DC2), fileSize: 30_439_424
        ) { _ in nil } == 0x8C)
        // In the file, but its string table runs past the end.
        #expect(WindowsResources.danglingSymbolTableField(
            header: header(pointer: 0x1000, symbols: 2), fileSize: 0x2000
        ) { _ in 0x5000 } == 0x8C)
        // The table as lld-link wrote it: left alone.
        #expect(WindowsResources.danglingSymbolTableField(
            header: header(pointer: 0x1000, symbols: 2), fileSize: 0x2000
        ) { offset in offset == 0x1000 + 36 ? 64 : nil } == nil)
        // No symbol table, or not a PE: nothing to do.
        #expect(WindowsResources.danglingSymbolTableField(
            header: header(pointer: 0, symbols: 0), fileSize: 0x2000
        ) { _ in nil } == nil)
        #expect(WindowsResources.danglingSymbolTableField(
            header: Data(count: 0x200), fileSize: 0x2000
        ) { _ in nil } == nil)
    }

    /// An image of `body` bytes after the header, then a symbol table of
    /// `symbols` 18-byte records and a string table, as lld-link lays it out.
    private func image(body: Int, symbols: UInt32, strings: [UInt8]) -> (file: Data, table: Data) {
        var table = Data((0 ..< Int(symbols) * 18).map { UInt8(truncatingIfNeeded: $0) })
        let length = UInt32(4 + strings.count)
        table += Data((0 ..< 4).map { UInt8(truncatingIfNeeded: length >> (8 * UInt32($0))) }) + Data(strings)
        let pointer = UInt32(0x200 + body)
        var file = header(pointer: pointer, symbols: symbols)
        file += Data(repeating: 0xAB, count: body)
        return (file + table, table)
    }

    @Test("the symbol table survives a resource update that drops it, pointed at where it now is (#276)")
    func carriesTheSymbolTable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pe-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: url) }
        let (file, table) = image(body: 0x400, symbols: 3, strings: Array(".debug_info\0".utf8))
        try file.write(to: url)
        let saved = try WindowsResources.symbolTable(of: url)
        #expect(saved == table)

        // What the update API does: the image changes size and the table goes.
        var updated = Data(file.prefix(0x200)) + Data(repeating: 0xCD, count: 0x300)
        try updated.write(to: url)
        try WindowsResources.restoreSymbolTable(saved, to: url)
        let restored = try Data(contentsOf: url)
        #expect(restored.suffix(table.count) == table)
        #expect(restored.count == updated.count + table.count)
        let header = Data(restored.prefix(0x200))
        #expect(WindowsResources.symbolTableField(header: header)?.pointer == UInt32(updated.count))
        #expect(WindowsResources.danglingSymbolTableField(header: header, fileSize: UInt64(restored.count)) { at in
            let bytes = restored[Int(at) ..< Int(at) + 4]
            return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        } == nil)

        // Nothing saved to put back: the pointer and count are cleared instead.
        updated = Data(file.prefix(0x200)) + Data(repeating: 0xCD, count: 0x300)
        try updated.write(to: url)
        try WindowsResources.restoreSymbolTable(nil, to: url)
        let cleared = try Data(contentsOf: url)
        #expect(cleared[0x8C ..< 0x94] == Data(count: 8))
        #expect(cleared.count == updated.count)

        // A table the update left in place is left alone.
        try file.write(to: url)
        try WindowsResources.restoreSymbolTable(saved, to: url)
        #expect(try Data(contentsOf: url) == file)
    }
}
