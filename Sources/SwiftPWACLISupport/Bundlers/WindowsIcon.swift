import Foundation
#if os(Windows)
    import WinSDK // BeginUpdateResourceW / UpdateResourceW / EndUpdateResourceW
#endif

/// Embeds an app icon into an already-linked Windows `.exe`.
///
/// The other platforms hand icon generation to a single OS tool
/// (`iconutil`, `actool`, `makeappx`); Windows has no equivalent for the
/// *portable* `.exe`, so we do it in two steps ourselves:
///
///   1. Wrap the source PNG in the `RT_GROUP_ICON` / `RT_ICON` resource
///      pair Windows reads for a module's display icon. A PNG can be
///      embedded verbatim as the `RT_ICON` payload — the shell decodes
///      PNG-compressed icon images on Vista and later — so no BMP
///      re-encoding is needed.
///   2. Inject those two resources into the linked `.exe` via the Win32
///      `BeginUpdateResource` / `UpdateResource` / `EndUpdateResource`
///      API. That's the same "edit the PE resource section after link"
///      approach the bundler already uses for the Common Controls v6
///      manifest (`mt.exe`) and the WINDOWS subsystem flip (`editbin`),
///      but the API is in `kernel32`, so unlike those two it needs no
///      tool on `PATH`.
///
/// First cut embeds the single source image; the shell downscales it for
/// the 16/32/48 px slots. A future pass can add a WIC resize to ship
/// crisp small sizes.
enum WindowsIcon {
    /// The lowest integer resource id wins as a module's shell icon, so
    /// the group goes in at id 1. `RT_ICON` shares the same id — the two
    /// resource *types* keep them distinct.
    static let groupID: UInt16 = 1

    /// Width/height of the source PNG, read from its IHDR chunk (the
    /// eight-byte signature is followed by a length + `IHDR` tag + the
    /// 32-bit big-endian width and height). Returns `nil` if the bytes
    /// aren't a PNG we can read.
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24, Array(data.prefix(8)) == signature else { return nil }
        /// IHDR width is bytes 16..<20, height 20..<24, both big-endian.
        func be32(at offset: Int) -> Int {
            let b = data[data.startIndex + offset ..< data.startIndex + offset + 4]
            return b.reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = be32(at: 16)
        let height = be32(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The `RT_GROUP_ICON` payload for a single-image icon: a `GRPICONDIR`
    /// header (reserved, type=1, count=1) followed by one 14-byte
    /// `GRPICONDIRENTRY` pointing at the `RT_ICON` resource by id. A
    /// dimension of 256-or-more is stored as the byte `0`, the format's
    /// sentinel for "≥ 256".
    static func groupIconDirectory(pngByteCount: Int, width: Int, height: Int, iconID: UInt16) -> Data {
        var data = Data()
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        // GRPICONDIR
        appendUInt16(0) // idReserved
        appendUInt16(1) // idType — 1 = icon
        appendUInt16(1) // idCount

        // GRPICONDIRENTRY
        data.append(UInt8(width >= 256 ? 0 : width))
        data.append(UInt8(height >= 256 ? 0 : height))
        data.append(0) // bColorCount — 0 for a true-colour image
        data.append(0) // bReserved
        appendUInt16(1) // wPlanes
        appendUInt16(32) // wBitCount
        appendUInt32(UInt32(pngByteCount)) // dwBytesInRes
        appendUInt16(iconID) // nID — the RT_ICON resource this entry names
        return data
    }

    enum EmbedError: Error, CustomStringConvertible {
        case notSupportedOnHost
        case beginFailed(UInt32)
        case updateFailed(UInt32)
        case endFailed(UInt32)

        var description: String {
            switch self {
            case .notSupportedOnHost: "icon embedding requires a Windows host"
            case let .beginFailed(code): "BeginUpdateResource failed (error \(code))"
            case let .updateFailed(code): "UpdateResource failed (error \(code))"
            case let .endFailed(code): "EndUpdateResource failed (error \(code))"
            }
        }
    }

    /// Inject `pngData` (as `RT_ICON` id `iconID`) and `groupDirectory` (as
    /// `RT_GROUP_ICON` id `iconID`) into `exe`, preserving any resources
    /// already there (e.g. the Common Controls manifest). Windows-only —
    /// throws `notSupportedOnHost` elsewhere (the portable Windows build
    /// only runs on Windows, so this branch is never hit in practice).
    static func embed(pngData: Data, groupDirectory: Data, iconID: UInt16, into exe: URL) throws {
        #if os(Windows)
            // RT_ICON = 3, RT_GROUP_ICON = 14, passed as MAKEINTRESOURCE
            // (an integer-valued LPWSTR). The resource *name* is the id,
            // encoded the same way.
            let RT_ICON = UnsafePointer<WCHAR>(bitPattern: 3)
            let RT_GROUP_ICON = UnsafePointer<WCHAR>(bitPattern: 14)
            let name = UnsafePointer<WCHAR>(bitPattern: Int(iconID))

            let handle = exe.path.withCString(encodedAs: UTF16.self) { BeginUpdateResourceW($0, false) }
            guard let handle else { throw EmbedError.beginFailed(GetLastError()) }

            func put(_ type: UnsafePointer<WCHAR>?, _ bytes: Data) throws {
                let ok = bytes.withUnsafeBytes { raw in
                    UpdateResourceW(
                        handle, type, name, 0,
                        UnsafeMutableRawPointer(mutating: raw.baseAddress), DWORD(raw.count)
                    )
                }
                if ok == false {
                    let code = GetLastError()
                    _ = EndUpdateResourceW(handle, true) // discard
                    throw EmbedError.updateFailed(code)
                }
            }

            try put(RT_ICON, pngData)
            try put(RT_GROUP_ICON, groupDirectory)

            if EndUpdateResourceW(handle, false) == false {
                throw EmbedError.endFailed(GetLastError())
            }
        #else
            _ = (pngData, groupDirectory, iconID, exe)
            throw EmbedError.notSupportedOnHost
        #endif
    }
}
