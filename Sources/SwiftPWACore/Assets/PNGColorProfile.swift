import Foundation

/// Moving a PNG's embedded colour profile (`iCCP`) from one image to another.
///
/// One backend needs it: WebView2's DevTools capture writes pixels in the
/// display's colour space and embeds that display's profile, but at any
/// `scale` other than 1 it writes the same pixels *without* the profile, so a
/// viewer reads them as sRGB and a wide-gamut display's red comes back
/// `#eb2f21` (#344). The profile is the display's, whatever the scale, so the
/// chunk from a tiny full-scale capture belongs on the scaled one. It's copied
/// whole, CRC included, which is why there is no compression or checksum code
/// here.
public enum PNGColorProfile {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The whole `iCCP` chunk — length, type, data and CRC — or `nil` when the
    /// image has none, or isn't a PNG.
    public static func profileChunk(in png: Data) -> Data? {
        let bytes = [UInt8](png)
        guard let chunks = Self.chunks(bytes) else { return nil }
        guard let chunk = chunks.first(where: { $0.type == "iCCP" }) else { return nil }
        return Data(bytes[chunk.range])
    }

    /// `png` with `chunk` inserted after its `IHDR`, where the format wants
    /// a profile. Unchanged when it already declares a colour space (`iCCP`
    /// or `sRGB` — two would contradict each other) or isn't a PNG.
    public static func inserting(_ chunk: Data, into png: Data) -> Data {
        let bytes = [UInt8](png)
        guard let chunks = Self.chunks(bytes), let header = chunks.first, header.type == "IHDR",
              !chunks.contains(where: { $0.type == "iCCP" || $0.type == "sRGB" })
        else { return png }
        var out = Data(bytes[0 ..< header.range.upperBound])
        out.append(chunk)
        out.append(contentsOf: bytes[header.range.upperBound...])
        return out
    }

    /// Each chunk's type and byte range, or `nil` if `bytes` isn't a
    /// well-formed PNG up to its `IEND`.
    private static func chunks(_ bytes: [UInt8]) -> [(type: String, range: Range<Int>)]? {
        guard bytes.count >= 8, Array(bytes[0 ..< 8]) == signature else { return nil }
        var found: [(type: String, range: Range<Int>)] = []
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = bytes[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let end = offset + 12 + length
            guard length >= 0, end <= bytes.count else { return nil }
            let type = String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self)
            found.append((type, offset ..< end))
            if type == "IEND" { return found }
            offset = end
        }
        return nil
    }
}
