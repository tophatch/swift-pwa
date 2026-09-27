import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The PE import reader and the runtime walk behind a portable Windows bundle
/// (#239). The images are built here, byte by byte, so this runs on every host;
/// a real Swift exe is read on a Windows box by Scripts/bundle-smoke-windows.ps1.
@Suite("Windows runtime staging")
struct SwiftRuntimeStagingTests {
    /// A minimal PE image: headers, one section at RVA 0x1000 holding an import
    /// table that names `dlls`, and nothing else a loader would need.
    static func image(importing dlls: [String], pe32Plus: Bool = true) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put16(_ value: Int, at offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8(value >> 8 & 0xFF)
        }
        func put32(_ value: Int, at offset: Int) {
            for index in 0 ..< 4 { bytes[offset + index] = UInt8(value >> (8 * index) & 0xFF) }
        }
        bytes[0] = 0x4D; bytes[1] = 0x5A // MZ
        let pe = 0x80
        put32(pe, at: 0x3C)
        put32(0x0000_4550, at: pe) // "PE\0\0"
        put16(1, at: pe + 6) // one section
        let optionalSize = pe32Plus ? 240 : 224
        put16(optionalSize, at: pe + 20)
        let optional = pe + 24
        put16(pe32Plus ? 0x20B : 0x10B, at: optional)
        let directories = optional + (pe32Plus ? 112 : 96)
        put32(16, at: optional + (pe32Plus ? 108 : 92))
        put32(0x1000, at: directories + 8) // import table RVA

        let section = optional + optionalSize
        put32(0x1000, at: section + 8) // VirtualSize
        put32(0x1000, at: section + 12) // VirtualAddress
        put32(0x1000, at: section + 16) // SizeOfRawData
        put32(0x400, at: section + 20) // PointerToRawData

        var raw = [UInt8](repeating: 0, count: 0x1000)
        let namesStart = (dlls.count + 1) * 20
        var cursor = namesStart
        for (index, dll) in dlls.enumerated() {
            let rva = 0x1000 + cursor
            for byte in 0 ..< 4 { raw[index * 20 + 12 + byte] = UInt8(rva >> (8 * byte) & 0xFF) }
            raw.replaceSubrange(cursor ..< cursor + dll.utf8.count, with: Array(dll.utf8))
            cursor += dll.utf8.count + 1
        }
        return Data(bytes + raw)
    }

    @Test("reads the imported DLL names from a PE32+ and a PE32 image")
    func readsImports() throws {
        let dlls = ["KERNEL32.dll", "swiftCore.dll", "Foundation.dll"]
        #expect(try PEImports.dllNames(in: Self.image(importing: dlls)) == dlls)
        #expect(try PEImports.dllNames(in: Self.image(importing: dlls, pe32Plus: false)) == dlls)
    }

    @Test("an image that imports nothing reads as no imports")
    func noImports() throws {
        #expect(try PEImports.dllNames(in: Self.image(importing: [])) == [])
    }

    @Test("something that isn't a PE image is an error, not an empty list")
    func notAnImage() {
        #expect(throws: PEImports.ReadError.self) { try PEImports.dllNames(in: Data("#!/bin/sh\n".utf8)) }
        let truncated = Self.image(importing: ["swiftCore.dll"]).prefix(0x100)
        #expect(throws: PEImports.ReadError.self) { try PEImports.dllNames(in: Data(truncated)) }
    }

    /// Real directories rather than Windows-style strings: how a host's
    /// Foundation reads `C:\…` differs between toolchains, and that isn't
    /// what's under test.
    @Test("finds the runtime folder on a semicolon-separated PATH")
    func runtimeDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-path-\(UUID().uuidString)")
        let system = root.appendingPathComponent("system32")
        let runtime = root.appendingPathComponent("Runtimes")
        for dir in [system, runtime] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: runtime.appendingPathComponent("swiftCore.dll"))

        let path = [system.path, "", runtime.path, root.appendingPathComponent("missing").path]
            .joined(separator: ";")
        #expect(SwiftRuntimeStaging.runtimeDirectory(path: path)?.lastPathComponent == "Runtimes")
        #expect(SwiftRuntimeStaging.runtimeDirectory(path: system.path) == nil)
        #expect(SwiftRuntimeStaging.runtimeDirectory(path: nil) == nil)
    }

    @Test("walks the closure through the runtime, case-insensitively, and leaves Windows' own DLLs")
    func closure() throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-pwa-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }
        for dll in ["swiftCore.dll", "Foundation.dll", "FoundationNetworking.dll", "vcruntime140.dll", "unused.dll"] {
            try Data().write(to: runtime.appendingPathComponent(dll))
        }
        let graph: [String: [String]] = [
            "App.exe": ["KERNEL32.dll", "SWIFTCORE.dll", "FoundationNetworking.dll"],
            "FoundationNetworking.dll": ["Foundation.dll", "WS2_32.dll"],
            "Foundation.dll": ["swiftCore.dll", "vcruntime140.dll"],
            "swiftCore.dll": ["vcruntime140.dll"],
            "vcruntime140.dll": []
        ]
        let found = try SwiftRuntimeStaging.closure(
            of: URL(fileURLWithPath: "/App.exe"), searchDirs: [runtime]
        ) { graph[$0.lastPathComponent] ?? [] }
        #expect(found.map(\.lastPathComponent) == [
            "swiftCore.dll", "FoundationNetworking.dll", "vcruntime140.dll", "Foundation.dll"
        ])
    }
}
