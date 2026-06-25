import Foundation

/// Outcome of interpreting an HTTP `Range` header against a known file size.
public enum ByteRangeResolution: Equatable, Sendable {
    /// No range (or an unsupported form) — serve the whole resource (200).
    case full
    /// Serve `length` bytes starting at `offset` (206 + `Content-Range`).
    case partial(offset: Int64, length: Int64)
    /// The range can't be satisfied for this file size (416).
    case unsatisfiable
}

/// Parses a single-range HTTP `Range` header so every backend's scheme
/// handler can answer `206 Partial Content` the same way — which is what
/// lets a large `<video>` seek/stream instead of buffering the whole file.
///
/// Supports one `bytes=` range in the three common forms; a multi-range
/// (comma-separated) request falls back to `.full` rather than emitting a
/// `multipart/byteranges` body (media elements don't need it).
public enum ByteRange {
    public static func resolve(header: String?, fileSize: Int64) -> ByteRangeResolution {
        guard let header, fileSize >= 0 else { return .full }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = trimmed.dropFirst("bytes=".count)
        if spec.contains(",") { return .full } // multi-range — serve full instead
        guard let dash = spec.firstIndex(of: "-") else { return .unsatisfiable }

        let startStr = spec[spec.startIndex ..< dash].trimmingCharacters(in: .whitespaces)
        let endStr = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        // Suffix range: `bytes=-N` → the last N bytes.
        if startStr.isEmpty {
            guard let suffix = Int64(endStr), suffix > 0, fileSize > 0 else { return .unsatisfiable }
            let length = min(suffix, fileSize)
            return .partial(offset: fileSize - length, length: length)
        }

        guard let start = Int64(startStr), start >= 0 else { return .unsatisfiable }
        if start >= fileSize { return .unsatisfiable }

        let end: Int64
        if endStr.isEmpty {
            end = fileSize - 1 // `bytes=start-` → to EOF
        } else {
            guard let parsed = Int64(endStr), parsed >= start else { return .unsatisfiable }
            end = min(parsed, fileSize - 1)
        }
        return .partial(offset: start, length: end - start + 1)
    }
}
