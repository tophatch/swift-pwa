import Foundation
@testable import SwiftPWACLISupport
import Testing

/// Layout checks for the `VS_VERSIONINFO` the Windows bundler embeds (#263).
/// These can only prove the bytes are shaped the way the format says; whether
/// Windows agrees is checked on a real box, where `VerQueryValueW` and
/// PowerShell's `VersionInfo` both read it back.
@Suite("Windows version resource")
struct WindowsVersionInfoTests {
    private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(uint16(data, offset)) | UInt32(uint16(data, offset + 2)) << 16
    }

    private func utf16(_ string: String) -> Data {
        var data = Data()
        for unit in string.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    @Test("the root block is VS_VERSION_INFO with a fixed-info value and its own length")
    func rootBlock() {
        let data = WindowsVersionInfo.build(name: "Example Reader", version: "1.4.2", exeName: "ExampleReader.exe")
        #expect(Int(uint16(data, 0)) == data.count)
        #expect(uint16(data, 2) == 52) // sizeof(VS_FIXEDFILEINFO)
        #expect(uint16(data, 4) == 0) // binary value
        #expect(data.subdata(in: 6 ..< 36) == utf16("VS_VERSION_INFO"))
        // 6-byte header + 32 bytes of key and terminator = 38, padded to 40.
        #expect(uint32(data, 40) == 0xFEEF_04BD)
        #expect(uint32(data, 48) == 0x0001_0004) // FileVersionMS: 1.4
        #expect(uint32(data, 52) == 0x0002_0000) // FileVersionLS: 2.0
    }

    @Test("ProductName carries the manifest name, spaces and all, as a NUL-terminated string")
    func productName() {
        let data = WindowsVersionInfo.build(name: "Example Reader", version: "1.0.0", exeName: "ExampleReader.exe")
        let key = utf16("ProductName") + Data([0, 0])
        guard let keyRange = data.range(of: key) else { Issue.record("no ProductName"); return }
        // The value starts on the next 32-bit boundary after the key.
        let valueStart = (keyRange.upperBound + 3) & ~3
        let expected = utf16("Example Reader") + Data([0, 0])
        #expect(data.subdata(in: valueStart ..< valueStart + expected.count) == expected)
        // wValueLength is in WCHARs for text, terminator included.
        let blockStart = keyRange.lowerBound - 6
        #expect(uint16(data, blockStart + 2) == UInt16("Example Reader".utf16.count + 1))
        #expect(uint16(data, blockStart + 4) == 1)
    }

    @Test("the translation names the string table that holds the strings")
    func translationMatchesTable() {
        let data = WindowsVersionInfo.build(name: "App", version: "1.0", exeName: "App.exe")
        #expect(data.range(of: utf16(WindowsVersionInfo.stringTableKey)) != nil)
        #expect(WindowsVersionInfo.stringTableKey == "040904B0")
        let key = utf16("Translation") + Data([0, 0])
        guard let keyRange = data.range(of: key) else { Issue.record("no Translation"); return }
        let valueStart = (keyRange.upperBound + 3) & ~3
        #expect(uint16(data, valueStart) == 0x0409)
        #expect(uint16(data, valueStart + 2) == 0x04B0)
    }

    @Test("numeric version reads leading digits and pads to four parts")
    func numericVersion() {
        #expect(WindowsVersionInfo.numericVersion("1.2.3") == (1, 2, 3, 0))
        #expect(WindowsVersionInfo.numericVersion("2.0.0-beta.1") == (2, 0, 0, 0))
        #expect(WindowsVersionInfo.numericVersion("10") == (10, 0, 0, 0))
        #expect(WindowsVersionInfo.numericVersion("1.2.3.4.5") == (1, 2, 3, 4))
        #expect(WindowsVersionInfo.numericVersion("") == (0, 0, 0, 0))
        #expect(WindowsVersionInfo.numericVersion("99999.1") == (65535, 1, 0, 0))
    }
}
