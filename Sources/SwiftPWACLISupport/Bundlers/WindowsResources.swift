import Foundation
#if os(Windows)
    import WinSDK // BeginUpdateResourceW / UpdateResourceW / EndUpdateResourceW
#endif

/// Writes resources into an already-linked `.exe`, preserving the ones
/// already there (the Common Controls manifest, an icon written earlier).
///
/// The Win32 update API lives in `kernel32`, so unlike `mt.exe` and `editbin`
/// it needs no tool on `PATH`. It must run before the single-file overlay is
/// appended: rewriting resources afterwards drops the trailing data.
enum WindowsResources {
    static let rtIcon: UInt16 = 3
    static let rtGroupIcon: UInt16 = 14
    static let rtVersion: UInt16 = 16

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

    /// Write every entry in one update pass. Language 0 (neutral), so a
    /// resource written here is the one a lookup finds whatever the user's
    /// locale. Throws `notSupportedOnHost` off Windows — the Windows bundler
    /// only runs there, so that branch is never reached in practice.
    static func update(_ exe: URL, with entries: [Entry]) throws {
        #if os(Windows)
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
        #else
            _ = (exe, entries)
            throw UpdateError.notSupportedOnHost
        #endif
    }
}
