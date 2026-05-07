import Foundation

/// Default `Fs` implementation backed by `FileManager` and
/// `Data(contentsOf:)`. Portable across every backend: Apple
/// Foundation, swift-corelibs-foundation on Linux, and the Windows
/// port all expose the same surface.
///
/// Operations are `async` because some hosts (notably the Windows
/// port of swift-corelibs-foundation) can take observable wall-clock
/// time on large directory walks; running the calls inside a
/// `Task.detached`-style hop keeps the JS-facing latency consistent
/// across platforms even though most operations are quick.
public final class SystemFs: Fs, @unchecked Sendable {
    public init() {}

    public func readText(path: String) async throws -> String {
        let data = try await readBinary(path: path)
        guard let str = String(data: data, encoding: .utf8) else {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.readText: \(path) is not valid UTF-8"
            )
        }
        return str
    }

    public func writeText(path: String, contents: String) async throws {
        try await writeBinary(path: path, data: Data(contents.utf8))
    }

    public func readBinary(path: String) async throws -> Data {
        let url = URL(fileURLWithPath: path)
        // `FileManager.contents(atPath:)` is more reliable than
        // `Data(contentsOf:)` on swift-corelibs-foundation under
        // Windows (the latter returns NSCocoaError 260 on real files,
        // a wart the bundler hit during v0.3 — see CHANGELOG).
        if let data = FileManager.default.contents(atPath: url.path) {
            return data
        }
        throw mapPosixError("fs.readBinary", path: path)
    }

    public func writeBinary(path: String, data: Data) async throws {
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.writeBinary failed at \(path): \(error.localizedDescription)"
            )
        }
    }

    public func exists(path: String) async throws -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func mkdir(path: String, recursive: Bool) async throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: recursive,
                attributes: nil
            )
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.mkdir failed at \(path): \(error.localizedDescription)"
            )
        }
    }

    public func remove(path: String, recursive: Bool) async throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.remove: \(path) does not exist"
            )
        }
        // For directories with content, refuse without `recursive`
        // — matches the `rm -d` / `rmdir` distinction. For an empty
        // directory either flag works.
        if isDir.boolValue, !recursive {
            let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            if !contents.isEmpty {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "fs.remove: \(path) is non-empty (pass recursive: true)"
                )
            }
        }
        do {
            try fm.removeItem(atPath: path)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.remove failed at \(path): \(error.localizedDescription)"
            )
        }
    }

    public func readDir(path: String) async throws -> [FsEntry] {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: path)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.readDir failed at \(path): \(error.localizedDescription)"
            )
        }
        // Sort for deterministic output — JS callers expect a stable
        // order for "list and render" patterns. `contentsOfDirectory`
        // is unordered on some platforms.
        let sorted = entries.sorted()
        let baseURL = URL(fileURLWithPath: path, isDirectory: true)
        return sorted.map { name in
            let full = baseURL.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: full, isDirectory: &isDir)
            return FsEntry(
                name: name,
                path: full,
                isDir: exists && isDir.boolValue,
                isFile: exists && !isDir.boolValue
            )
        }
    }

    public func copy(from: String, to: String) async throws {
        do {
            try FileManager.default.copyItem(atPath: from, toPath: to)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.copy failed (\(from) → \(to)): \(error.localizedDescription)"
            )
        }
    }

    public func rename(from: String, to: String) async throws {
        do {
            try FileManager.default.moveItem(atPath: from, toPath: to)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.rename failed (\(from) → \(to)): \(error.localizedDescription)"
            )
        }
    }

    public func metadata(path: String) async throws -> FsMetadata {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: path)
        } catch {
            throw BridgeError(
                code: BridgeError.handler,
                message: "fs.metadata failed at \(path): \(error.localizedDescription)"
            )
        }
        let kind = attrs[.type] as? FileAttributeType
        let isDir = (kind == .typeDirectory)
        // `typeRegular` is the canonical "plain file"; symlinks /
        // sockets / devices fall through and report `isFile: false`.
        let isFile = (kind == .typeRegular)
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        let modified = (attrs[.modificationDate] as? Date)
            .map { Int64($0.timeIntervalSince1970 * 1000) }
        return FsMetadata(size: size, isDir: isDir, isFile: isFile, modified: modified)
    }

    // MARK: - Helpers

    private func mapPosixError(_ op: String, path: String) -> BridgeError {
        let exists = FileManager.default.fileExists(atPath: path)
        let detail = exists ? "read failed" : "no such file"
        return BridgeError(
            code: BridgeError.handler,
            message: "\(op): \(path) — \(detail)"
        )
    }
}
