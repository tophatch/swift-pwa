import Foundation
import SwiftPWACore

/// In-memory `Fs` for unit tests. Backs a path → bytes dictionary;
/// directories are tracked separately as a set of paths so tests can
/// assert "the JS side called mkdir before writing".
///
/// The mock is deliberately permissive — it doesn't enforce parent
/// existence or path normalisation. Tests that care about those edge
/// cases can drive `SystemFs` against a temp directory.
@MainActor
public final class MockFs: Fs {
    public enum Action: Sendable, Equatable {
        case readText(path: String)
        case writeText(path: String, contents: String)
        case readBinary(path: String)
        case writeBinary(path: String, byteCount: Int)
        case exists(path: String)
        case mkdir(path: String, recursive: Bool)
        case remove(path: String, recursive: Bool)
        case readDir(path: String)
        case copy(from: String, to: String)
        case rename(from: String, to: String)
        case metadata(path: String)
    }

    public private(set) var actions: [Action] = []
    public var files: [String: Data] = [:]
    public var directories: Set<String> = []
    public var nextReadDir: [String: [FsEntry]] = [:]
    public var nextMetadata: [String: FsMetadata] = [:]

    public init() {}

    public func readText(path: String) async throws -> String {
        actions.append(.readText(path: path))
        guard let data = files[path] else { throw notFound(path) }
        guard let str = String(data: data, encoding: .utf8) else { throw notUTF8(path) }
        return str
    }

    public func writeText(path: String, contents: String) async throws {
        actions.append(.writeText(path: path, contents: contents))
        files[path] = Data(contents.utf8)
    }

    public func readBinary(path: String) async throws -> Data {
        actions.append(.readBinary(path: path))
        guard let data = files[path] else { throw notFound(path) }
        return data
    }

    public func writeBinary(path: String, data: Data) async throws {
        actions.append(.writeBinary(path: path, byteCount: data.count))
        files[path] = data
    }

    public func exists(path: String) async throws -> Bool {
        actions.append(.exists(path: path))
        return files[path] != nil || directories.contains(path)
    }

    public func mkdir(path: String, recursive: Bool) async throws {
        actions.append(.mkdir(path: path, recursive: recursive))
        directories.insert(path)
    }

    public func remove(path: String, recursive: Bool) async throws {
        actions.append(.remove(path: path, recursive: recursive))
        files.removeValue(forKey: path)
        directories.remove(path)
    }

    public func readDir(path: String) async throws -> [FsEntry] {
        actions.append(.readDir(path: path))
        return nextReadDir[path] ?? []
    }

    public func copy(from: String, to: String) async throws {
        actions.append(.copy(from: from, to: to))
        if let data = files[from] { files[to] = data }
    }

    public func rename(from: String, to: String) async throws {
        actions.append(.rename(from: from, to: to))
        if let data = files.removeValue(forKey: from) { files[to] = data }
    }

    public func metadata(path: String) async throws -> FsMetadata {
        actions.append(.metadata(path: path))
        if let m = nextMetadata[path] { return m }
        if let data = files[path] {
            return FsMetadata(size: Int64(data.count), isDir: false, isFile: true, modified: nil)
        }
        if directories.contains(path) {
            return FsMetadata(size: 0, isDir: true, isFile: false, modified: nil)
        }
        throw notFound(path)
    }

    // MARK: - Helpers

    private func notFound(_ path: String) -> BridgeError {
        BridgeError(code: BridgeError.handler, message: "MockFs: \(path) not found")
    }

    private func notUTF8(_ path: String) -> BridgeError {
        BridgeError(code: BridgeError.handler, message: "MockFs: \(path) is not valid UTF-8")
    }
}
