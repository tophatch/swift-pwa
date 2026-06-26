import Foundation
import SwiftPWACore

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession / URLRequest live here on non-Apple platforms
#endif

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// A model file to make available on disk: where to fetch it, what it
/// should hash to, and the filename to cache it under.
public struct ModelSpec: Sendable, Equatable {
    /// Remote URL to download from.
    public let url: URL
    /// Expected SHA-256, lowercase hex. `nil` skips integrity verification
    /// (not recommended for untrusted sources).
    public let sha256: String?
    /// Filename to cache under, inside the downloader's directory.
    public let fileName: String

    public init(url: URL, sha256: String? = nil, fileName: String) {
        self.url = url
        self.sha256 = sha256?.lowercased()
        self.fileName = fileName
    }
}

/// Resumable, checksum-pinned downloader behind `ai.ensureModel`. The
/// reusable half of the downloadable-model tier: a backend that ships a
/// downloadable model (llama.cpp, the Gemma fallback) keeps a registry of
/// `ModelSpec`s and calls this from its `AIBackend.ensureModel`.
///
/// Behavior:
/// - **Cache reuse** — if the cached file is present and (when a checksum
///   is given) matches, returns it immediately without a network call.
/// - **Resumable** — an interrupted download leaves a `.part` file; the
///   next call resumes it with an HTTP `Range` request (restarting only if
///   the server ignores the range).
/// - **Atomic** — bytes land in `<file>.part`, are checksum-verified, then
///   renamed into place, so a half-written file is never seen as ready.
/// - **Progress** — `onProgress(bytesDone, totalBytes?)` after each buffer
///   flush (`totalBytes` is `nil` when the server sends no length).
///
/// The network download path is **currently macOS/iOS only** — it uses
/// `URLSession.bytes(for:)`, which swift-corelibs-foundation doesn't ship
/// yet. On other platforms `ensure` throws `modelDownloadFailed` for a
/// missing file (cache reuse and checksum still work). Linux/Windows
/// download lands with the portable backends (llama.cpp), implemented and
/// verified on those hosts.
public struct ModelDownloader: Sendable {
    /// Directory the models are cached in (created on demand). Typically a
    /// subdirectory of the app's data directory.
    public let directory: URL
    private let session: URLSession

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    /// The on-disk location a spec resolves to (whether or not present yet).
    public func localURL(for spec: ModelSpec) -> URL {
        directory.appendingPathComponent(spec.fileName)
    }

    /// Ensure the model is present and (if pinned) intact, downloading or
    /// resuming as needed. Returns the local file URL.
    @discardableResult
    public func ensure(
        _ spec: ModelSpec,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = localURL(for: spec)

        if fm.fileExists(atPath: final.path) {
            if let want = spec.sha256 {
                if try await sha256Hex(of: final) == want { return final }
                try? fm.removeItem(at: final) // stale/corrupt — re-fetch
            } else {
                return final
            }
        }

        let part = final.appendingPathExtension("part")
        try await download(spec, to: part, onProgress: onProgress)

        if let want = spec.sha256 {
            let got = try await sha256Hex(of: part)
            guard got == want else {
                try? fm.removeItem(at: part)
                throw AIError.modelDownloadFailed("checksum mismatch (expected \(want), got \(got))")
            }
        }

        try? fm.removeItem(at: final)
        try fm.moveItem(at: part, to: final)
        return final
    }

    /// `ensure` adapted to the `AIBackend.ensureModel` shape — emits
    /// `AIDownloadEvent` progress frames, then a terminal `done`.
    public func events(for spec: ModelSpec) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await ensure(spec) { bytesDone, totalBytes in
                        continuation.yield(.progress(bytesDone: bytesDone, totalBytes: totalBytes))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIError.modelDownloadFailed("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Download

    private func download(
        _ spec: ModelSpec,
        to part: URL,
        onProgress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws {
        // The streamed, resumable download uses `URLSession.bytes(for:)`,
        // which isn't available on swift-corelibs-foundation yet — so the
        // network path is currently macOS/iOS only. Linux/Windows support
        // lands with the portable backends (llama.cpp), implemented and
        // verified on those hosts. Everything else here (cache reuse,
        // checksum, the API) is cross-platform.
        #if canImport(Darwin)
            let fm = FileManager.default
            var offset: Int64 = 0
            if let size = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64 { offset = size }

            var request = URLRequest(url: spec.url)
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.modelDownloadFailed("no HTTP response from \(spec.url)")
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw AIError.modelDownloadFailed("download failed (HTTP \(http.statusCode))")
            }
            // Range honored → 206 Partial Content; a plain 200 means the server
            // ignored it, so discard the stale partial and restart from zero.
            if offset > 0, http.statusCode != 206 {
                try? fm.removeItem(at: part)
                offset = 0
            }

            // `expectedContentLength` is the remaining length for a 206.
            let total: Int64? = http.expectedContentLength >= 0 ? offset + http.expectedContentLength : nil

            if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seekToEnd()

            var done = offset
            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    try handle.write(contentsOf: buffer)
                    done += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress?(done, total)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                done += Int64(buffer.count)
                onProgress?(done, total)
            }
        #else
            throw AIError.modelDownloadFailed("on-device model download is currently macOS/iOS only")
        #endif
    }

    // MARK: - Hashing

    /// Stream the file through SHA-256 so a multi-GB model isn't read into
    /// memory at once.
    private func sha256Hex(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = try handle.read(upToCount: 1 << 20), let data = chunk, !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
