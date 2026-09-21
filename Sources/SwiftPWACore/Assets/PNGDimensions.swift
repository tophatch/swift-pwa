import Foundation

/// A PNG's pixel dimensions, read from the bytes rather than decoded.
///
/// Every backend's snapshot comes back as PNG data with no size attached, and
/// the page needs the pixel size to put it on a canvas — but decoding an image
/// to learn how big it is would cost more than taking it. The IHDR chunk is
/// always the first one and always at the same offset, so the answer is 8
/// bytes at a fixed place.
public enum PNGDimensions {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Width and height, or `nil` if `data` doesn't start like a PNG.
    ///
    /// The signature is checked in full: a caller that fed this a JPEG would
    /// otherwise get two plausible-looking numbers out of arbitrary bytes.
    public static func read(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24, Array(data.prefix(8)) == signature else { return nil }
        /// Length (4) + "IHDR" (4) follow the signature, so width is at 16 and
        /// height at 20, both 32-bit big-endian.
        func be32(at offset: Int) -> Int {
            let start = data.index(data.startIndex, offsetBy: offset)
            return data[start ..< data.index(start, offsetBy: 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = be32(at: 16)
        let height = be32(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
