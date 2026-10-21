import Foundation

extension PWAManifest.IconArt {
    /// The first of this icon's files that's missing or isn't a PNG, as the
    /// outcome to report, or `nil` when every one is usable.
    ///
    /// Any one file failing fails the whole icon rather than quietly dropping,
    /// say, its dark art: an icon that falls back to the platform default is
    /// noticed on the first build, one merely missing a variant may not be.
    func problem(under projectRoot: URL) -> IconOutcome? {
        for path in paths {
            let url = projectRoot.appendingPathComponent(path)
            guard url.pathExtension.lowercased() == "png" else {
                return .notPNG(source: path, placeholder: false)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .notFound(source: path, placeholder: false)
            }
        }
        return nil
    }
}

/// What a PNG's header says, read without decoding the image.
enum PNGHeader {
    /// Whether the image can carry transparency: a colour type with an alpha
    /// channel, or a `tRNS` chunk before the image data. `nil` when `data`
    /// isn't a PNG.
    ///
    /// Android's themed icon reads only the alpha of its monochrome layer, so
    /// an opaque tinted PNG comes out as a solid tile.
    static func hasAlpha(_ data: Data) -> Bool? {
        let bytes = [UInt8](data.prefix(1 << 16))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // Signature, then IHDR: length (4), "IHDR" (4), width, height, bit
        // depth, then colour type at byte 25.
        guard bytes.count > 33, Array(bytes[0 ..< 8]) == signature, Array(bytes[12 ..< 16]) == Array("IHDR".utf8)
        else { return nil }
        let colourType = bytes[25]
        if colourType == 4 || colourType == 6 { return true } // grayscale + alpha, RGBA
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self)
            if type == "tRNS" { return true }
            if type == "IDAT" || type == "IEND" { return false }
            offset += 12 + length
        }
        return false
    }
}
