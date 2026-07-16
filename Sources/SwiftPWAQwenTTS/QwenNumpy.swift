import Foundation

/// Failures loading a `.npy` array.
public enum QwenNumpyError: Error, Equatable {
    case loadFailed(String)
    case unsupported(String)
}

/// A minimal reader for NumPy `.npy` v1.0 arrays of a **2-D, C-order, float32
/// or float16** matrix — exactly what the Qwen3-TTS host-side embedding tables
/// are (`text_embedding` 151936×2048, `talker_codec_embedding` 3072×1024, the
/// `cp_codec_embedding_*` 2048×1024, the text-projection weights/biases).
///
/// Memory-**mapped**: the file is mapped, not copied, so the 1.2 GB fp32
/// `text_embedding` (or 0.6 GB fp16) costs no resident RAM until rows are
/// touched, and a lookup copies just one row. This is the on-device-critical
/// property — loading that table as a `[Float]` would cost 1.2 GB.
///
/// `@unchecked Sendable`: the mapped `Data` is immutable after init and only
/// read, so sharing it across the backend actor's tasks is safe.
public struct QwenNumpyArray: Sendable {
    /// dtype of the stored elements (only float32 / float16 are supported).
    public enum DType: Sendable { case float32, float16 }

    private let data: Data
    private let headerLength: Int
    public let shape: [Int]
    public let dtype: DType

    /// Rows (`shape[0]`) for a 2-D array; a 1-D array (a bias) reports 1.
    public var rows: Int {
        shape.count >= 2 ? shape[0] : 1
    }
    /// Columns — `shape[1]` for 2-D, `shape[0]` for 1-D.
    public var columns: Int {
        shape.count >= 2 ? shape[1] : shape[0]
    }

    /// Memory-map `url` and parse its `.npy` header. Throws if the file isn't a
    /// v1.0 float32/float16 C-order array.
    public init(url: URL) throws {
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw QwenNumpyError.loadFailed("\(url.lastPathComponent): \(error)")
        }
        let parsed = try Self.parseHeader(data, name: url.lastPathComponent)
        headerLength = parsed.headerLength
        shape = parsed.shape
        dtype = parsed.dtype
    }

    /// Parse the `\x93NUMPY` magic, version, header length, and the header dict
    /// (`descr`, `fortran_order`, `shape`). Returns where the raw data starts.
    private static func parseHeader(_ data: Data, name: String) throws
        -> (headerLength: Int, shape: [Int], dtype: DType)
    {
        // Magic (6) + major/minor (2) + header-len (2, little-endian u16 for v1.0).
        guard data.count > 10, data[0] == 0x93,
              data[1] == 0x4E, data[2] == 0x55, data[3] == 0x4D, data[4] == 0x50, data[5] == 0x59
        else { throw QwenNumpyError.loadFailed("\(name): not a .npy file") }
        let major = data[6]
        guard major == 1 else { throw QwenNumpyError.unsupported("\(name): only .npy v1.0 supported (got v\(major))") }
        let headerLen = Int(data[8]) | (Int(data[9]) << 8)
        let dictStart = 10
        let dictEnd = dictStart + headerLen
        guard data.count >= dictEnd else { throw QwenNumpyError.loadFailed("\(name): truncated header") }
        let header = String(decoding: data[dictStart ..< dictEnd], as: UTF8.self)

        let dtype: DType
        if header.contains("'<f4'") { dtype = .float32 }
        else if header.contains("'<f2'") { dtype = .float16 }
        else { throw QwenNumpyError.unsupported("\(name): only <f4/<f2 dtypes supported — header: \(header)") }

        if header.contains("'fortran_order': True") {
            throw QwenNumpyError.unsupported("\(name): fortran_order arrays not supported")
        }

        // shape tuple, e.g. "(151936, 2048)" or "(2048,)".
        guard let open = header.firstIndex(of: "("), let close = header.firstIndex(of: ")") else {
            throw QwenNumpyError.loadFailed("\(name): no shape in header")
        }
        let shape = header[header.index(after: open) ..< close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !shape.isEmpty else { throw QwenNumpyError.loadFailed("\(name): empty shape") }
        return (dictEnd, shape, dtype)
    }

    private var bytesPerElement: Int {
        dtype == .float32 ? 4 : 2
    }

    /// Copy row `index` (`columns` elements) out as float32 — a fp16 row is
    /// converted up. This is the hot path: one row of an embedding table.
    public func row(_ index: Int) -> [Float] {
        let cols = columns
        let start = headerLength + index * cols * bytesPerElement
        return read(byteOffset: start, count: cols)
    }

    /// Copy the whole array out as a flat float32 `[Float]` (row-major). Use for
    /// the small tables (projection weights, 1-D biases); avoid for the giant
    /// `text_embedding` — use `row(_:)` there.
    public func flat() -> [Float] {
        read(byteOffset: headerLength, count: rows * columns)
    }

    private func read(byteOffset: Int, count: Int) -> [Float] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            let base = raw.baseAddress!.advanced(by: byteOffset)
            switch dtype {
            case .float32:
                let p = base.assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: p, count: count))
            case .float16:
                let p = base.assumingMemoryBound(to: Float16.self)
                return UnsafeBufferPointer(start: p, count: count).map { Float($0) }
            }
        }
    }
}
