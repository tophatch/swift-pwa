import Foundation

/// The mark drawn in the tray while agent access is open: a ring, with an inset
/// dot once a client is actually connected.
///
/// Drawn rather than shipped as bytes. It varies along two axes — state (waiting
/// / connected) and polarity (dark art for a light tray, light art for a dark
/// one) — and four hand-authored PNG blobs would be four things to keep in
/// agreement, none of them reviewable in a diff. Rendering is ~40 lines and the
/// geometry is legible as code.
///
/// Deliberately airy: at tray size the shape has to read at a glance, and a
/// filled disc that large just reads as a blob. The ring carries the identity
/// and the inset dot is the state, with a clear gap between them so the two
/// don't merge when the shell scales this down to 16px.
enum AgentIndicatorMark {
    /// Side length in pixels of the rendered mark. 22 matches the macOS menu
    /// bar's icon size; Windows and Linux scale from it.
    static let side = 22

    /// A PNG of the mark, cached in the temp directory.
    ///
    /// The file is content-addressed by its inputs, so a state change reuses a
    /// file already written rather than accumulating one per update — the
    /// indicator republishes on every attach and detach.
    static func pngPath(connected: Bool, lightForeground: Bool) -> String? {
        let name = "swift-pwa-agent-\(connected ? "on" : "idle")-\(lightForeground ? "light" : "dark").png"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            let png = png(connected: connected, lightForeground: lightForeground)
            guard (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        }
        return url.path
    }

    static func png(connected: Bool, lightForeground: Bool) -> Data {
        PNG.encode(
            rgba: raster(connected: connected, lightForeground: lightForeground),
            width: side, height: side
        )
    }

    /// Row-major RGBA, `side * side * 4` bytes.
    ///
    /// Coverage is sampled on a 4×4 grid per pixel rather than computed
    /// analytically: at this size the cost is nothing and it antialiases both
    /// the ring's edges and the dot uniformly.
    static func raster(connected: Bool, lightForeground: Bool) -> [UInt8] {
        let n = Double(side)
        let center = (n - 1) / 2
        // Fractions of the side, so the shape holds if `side` ever changes.
        // The radius leaves ~2px of margin at 22px rather than filling the
        // canvas: a menu-bar mark sits next to the system's own, which are
        // inset, and a ring drawn to the edge reads as heavier than it is.
        let ringRadius = n * 0.36
        let ringHalfStroke = n * 0.045
        let dotRadius = n * 0.15

        let channel: UInt8 = lightForeground ? 255 : 0
        let samples = 4
        let step = 1.0 / Double(samples)

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0 ..< side {
            for x in 0 ..< side {
                var hits = 0
                for sy in 0 ..< samples {
                    for sx in 0 ..< samples {
                        let px = Double(x) + (Double(sx) + 0.5) * step - 0.5
                        let py = Double(y) + (Double(sy) + 0.5) * step - 0.5
                        let d = ((px - center) * (px - center) + (py - center) * (py - center)).squareRoot()
                        let onRing = abs(d - ringRadius) <= ringHalfStroke
                        let inDot = connected && d <= dotRadius
                        if onRing || inDot { hits += 1 }
                    }
                }
                guard hits > 0 else { continue }
                let alpha = UInt8((Double(hits) / Double(samples * samples) * 255).rounded())
                let i = (y * side + x) * 4
                // Straight (non-premultiplied) alpha: what PNG stores, and what
                // every platform's loader expects from one.
                pixels[i] = channel
                pixels[i + 1] = channel
                pixels[i + 2] = channel
                pixels[i + 3] = alpha
            }
        }
        return pixels
    }
}

/// Just enough PNG to write an RGBA image.
///
/// Hand-rolled because the alternative is a dependency or reaching into a
/// platform codec, and Core has neither: it needs one small image on every
/// platform including the ones with no image library at all. Deflate is used in
/// its **stored** (uncompressed) mode — a real compressor would be a lot more
/// code to save a kilobyte on a 22×22 icon.
enum PNG {
    static func encode(rgba: [UInt8], width: Int, height: Int) -> Data {
        precondition(rgba.count == width * height * 4)

        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 4 + 1))
        for y in 0 ..< height {
            raw.append(0) // filter: none
            raw.append(contentsOf: rgba[(y * width * 4) ..< ((y + 1) * width * 4)])
        }

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(UInt32(width)))
        ihdr.append(be32(UInt32(height)))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit, RGBA, deflate, no filter, no interlace
        out.append(chunk("IHDR", ihdr))
        out.append(chunk("IDAT", zlibStored(raw)))
        out.append(chunk("IEND", Data()))
        return out
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        out.append(be32(UInt32(payload.count)))
        let body = Data(type.utf8) + payload
        out.append(body)
        out.append(be32(crc32(body)))
        return out
    }

    private static func zlibStored(_ raw: [UInt8]) -> Data {
        // 0x78 0x01: deflate, 32K window, fastest — and (0x7801 % 31 == 0),
        // which is the header check zlib readers apply.
        var out = Data([0x78, 0x01])
        var offset = 0
        while offset < raw.count {
            let len = min(65535, raw.count - offset)
            let isLast = offset + len == raw.count
            out.append(isLast ? 1 : 0) // BFINAL, BTYPE = stored
            out.append(UInt8(len & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            let nlen = ~UInt16(len)
            out.append(UInt8(nlen & 0xFF))
            out.append(UInt8((nlen >> 8) & 0xFF))
            out.append(contentsOf: raw[offset ..< (offset + len)])
            offset += len
        }
        out.append(be32(adler32(raw)))
        return out
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ])
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
