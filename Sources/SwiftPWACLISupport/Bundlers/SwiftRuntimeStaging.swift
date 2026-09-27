import Foundation

/// Puts the Swift runtime a Windows app links beside its `.exe`, so the bundle
/// starts on a machine with no Swift toolchain.
///
/// A Swift executable on Windows loads `swiftCore.dll`, `Foundation.dll` and the
/// rest at launch, and `--static-swift-stdlib` is silently ignored there
/// (#261). The loader searches the exe's own folder before `PATH`, so DLLs
/// staged there win — and without them a bundle only started where a toolchain
/// happened to be on `PATH`: measured on a runner with only Windows on it, it
/// died "FoundationNetworking.dll was not found" (#239).
///
/// The set is the exe's import closure, walked rather than listed: it changes
/// when a dependency does, and a hand-kept list goes stale without failing.
/// Only DLLs found in the given directories are followed — the toolchain's
/// runtime folder (which also carries the matching VC++ runtime) and the build's
/// own products; everything else an exe imports is part of Windows.
enum SwiftRuntimeStaging {
    /// The folder on `PATH` that holds `swiftCore.dll` — the runtime the build
    /// just linked against.
    static func runtimeDirectory(path: String?, fileExists: (String) -> Bool = FileManager.default.fileExists) -> URL? {
        guard let path else { return nil }
        for entry in path.split(separator: ";").map(String.init) where !entry.isEmpty {
            let dir = URL(fileURLWithPath: entry, isDirectory: true)
            if fileExists(dir.appendingPathComponent("swiftCore.dll").path) { return dir }
        }
        return nil
    }

    /// Every DLL in `searchDirs` that `exe` needs, directly or through another
    /// one, in the order the walk reached them. Names compare case-insensitively,
    /// as the loader does.
    static func closure(
        of exe: URL,
        searchDirs: [URL],
        imports: (URL) throws -> [String] = { try PEImports.dllNames(in: Data(contentsOf: $0)) }
    ) throws -> [URL] {
        var available: [String: URL] = [:]
        for dir in searchDirs {
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in entries where file.pathExtension.lowercased() == "dll" {
                let key = file.lastPathComponent.lowercased()
                if available[key] == nil { available[key] = file }
            }
        }
        var found: [URL] = []
        var seen: Set<String> = []
        var queue = [exe]
        while !queue.isEmpty {
            for name in try imports(queue.removeFirst()) {
                let key = name.lowercased()
                guard !seen.contains(key), let dll = available[key] else { continue }
                seen.insert(key)
                found.append(dll)
                queue.append(dll)
            }
        }
        return found
    }

    /// Copy `dlls` into `dir`, replacing any copy already there, and return the
    /// total size in bytes.
    @discardableResult
    static func copy(_ dlls: [URL], into dir: URL) throws -> Int {
        var bytes = 0
        for dll in dlls {
            let destination = dir.appendingPathComponent(dll.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: dll, to: destination)
            bytes += (try? FileManager.default.attributesOfItem(atPath: dll.path)[.size] as? Int) ?? 0
        }
        return bytes
    }
}
