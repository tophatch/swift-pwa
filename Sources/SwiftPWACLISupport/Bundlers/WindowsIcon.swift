import Foundation
#if os(Windows)
    import WinSDK // BeginUpdateResourceW / UpdateResourceW / EndUpdateResourceW
#endif
// stb-based PNG decode/encode (Linux + Windows; no CoreGraphics there). Present
// only on those hosts — see the `.when(platforms:)` gate in Package.swift — so
// the resize path is `#if canImport(CStbImage)`. In practice it's only ever
// exercised on Windows, where the portable `.exe` bundler runs.
#if canImport(CStbImage)
    import CStbImage
#endif

/// Embeds an app icon into an already-linked Windows `.exe`.
///
/// The other platforms hand icon generation to a single OS tool
/// (`iconutil`, `actool`, `makeappx`); Windows has no equivalent for the
/// *portable* `.exe`, so we do it in two steps ourselves:
///
///   1. Wrap the source PNG in the `RT_GROUP_ICON` / `RT_ICON` resource
///      pair Windows reads for a module's display icon. A PNG can be
///      embedded verbatim as an `RT_ICON` payload — the shell decodes
///      PNG-compressed icon images on Vista and later — so no BMP
///      re-encoding is needed. To keep the small shell sizes crisp we
///      pre-render **several** sizes (16/32/48/256) into the group rather
///      than shipping one image and letting the shell downscale it (which
///      looked soft); each rendered size is its own `RT_ICON` and the
///      `GRPICONDIR` lists them all.
///   2. Inject those resources into the linked `.exe` via the Win32
///      `BeginUpdateResource` / `UpdateResource` / `EndUpdateResource`
///      API. That's the same "edit the PE resource section after link"
///      approach the bundler already uses for the Common Controls v6
///      manifest (`mt.exe`) and the WINDOWS subsystem flip (`editbin`),
///      but the API is in `kernel32`, so unlike those two it needs no
///      tool on `PATH`.
enum WindowsIcon {
    /// The lowest integer resource id wins as a module's shell icon, so
    /// the group goes in at id 1. The individual `RT_ICON` images take ids
    /// 1, 2, 3, … in their own resource-type namespace (a `RT_ICON` id and
    /// the `RT_GROUP_ICON` id don't clash — different types).
    static let groupID: UInt16 = 1

    /// The pixel sizes we pre-render into the group, largest first. Covers
    /// Explorer small-icon view (16), the taskbar / Alt-Tab (32), Explorer
    /// medium icons (48), and the extra-large / jumbo view (256). Sizes at
    /// or above the source's own dimension are dropped (we down-render only;
    /// upscaling a small source just bloats the `.exe`), and the source's
    /// exact size is embedded verbatim rather than re-encoded.
    static let renderedSizes: [Int] = [256, 48, 32, 16]

    /// Width/height of the source PNG, read from its IHDR chunk (the
    /// eight-byte signature is followed by a length + `IHDR` tag + the
    /// 32-bit big-endian width and height). Returns `nil` if the bytes
    /// aren't a PNG we can read.
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24, Array(data.prefix(8)) == signature else { return nil }
        /// IHDR width is bytes 16..<20, height 20..<24, both big-endian.
        func be32(at offset: Int) -> Int {
            let b = data[data.startIndex + offset ..< data.startIndex + offset + 4]
            return b.reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = be32(at: 16)
        let height = be32(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// One image in an icon group: the size the shell uses to pick it, the
    /// PNG bytes for the `RT_ICON` payload, and the `RT_ICON` resource id
    /// the group entry names.
    struct IconImage {
        var width: Int
        var height: Int
        var png: Data
        var id: UInt16
    }

    /// The `RT_GROUP_ICON` payload: a `GRPICONDIR` header (reserved,
    /// type=1, count=N) followed by one 14-byte `GRPICONDIRENTRY` per
    /// image, each pointing at its `RT_ICON` resource by id. A dimension of
    /// 256-or-more is stored as the byte `0`, the format's sentinel for
    /// "≥ 256".
    static func groupIconDirectory(images: [IconImage]) -> Data {
        groupIconDirectory(entries: images.map { ($0.width, $0.height, $0.png.count, $0.id) })
    }

    /// Single-image convenience — kept for the earlier callers/tests that
    /// build a one-entry directory.
    static func groupIconDirectory(pngByteCount: Int, width: Int, height: Int, iconID: UInt16) -> Data {
        groupIconDirectory(entries: [(width, height, pngByteCount, iconID)])
    }

    private static func groupIconDirectory(
        entries: [(width: Int, height: Int, byteCount: Int, id: UInt16)]
    ) -> Data {
        var data = Data()
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        // GRPICONDIR
        appendUInt16(0) // idReserved
        appendUInt16(1) // idType — 1 = icon
        appendUInt16(UInt16(entries.count)) // idCount

        for entry in entries {
            // GRPICONDIRENTRY
            data.append(UInt8(entry.width >= 256 ? 0 : entry.width))
            data.append(UInt8(entry.height >= 256 ? 0 : entry.height))
            data.append(0) // bColorCount — 0 for a true-colour image
            data.append(0) // bReserved
            appendUInt16(1) // wPlanes
            appendUInt16(32) // wBitCount
            appendUInt32(UInt32(entry.byteCount)) // dwBytesInRes
            appendUInt16(entry.id) // nID — the RT_ICON resource this entry names
        }
        return data
    }

    // MARK: - Resize

    /// Area-average (box) downscale of a tightly-packed RGBA8 buffer, done
    /// in **premultiplied-alpha** space so transparent edges don't pick up a
    /// dark fringe (straight-alpha averaging bleeds a transparent pixel's
    /// undefined RGB into its neighbours). Pure Swift — no platform image
    /// APIs — so it's deterministic and unit-testable on any host. Each
    /// destination pixel averages the fractional source rectangle it covers,
    /// which is a high-quality filter for the integer-ish downscales icons
    /// use (256→16/32/48). Works for upscales too (degenerates to a box
    /// interpolation), though the caller only ever down-renders.
    static func downscaleRGBA(_ src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [UInt8] {
        precondition(src.count == srcW * srcH * 4, "src is not tightly-packed RGBA8")
        var out = [UInt8](repeating: 0, count: dstW * dstH * 4)
        let sx = Double(srcW) / Double(dstW)
        let sy = Double(srcH) / Double(dstH)

        for dy in 0 ..< dstH {
            let y0 = Double(dy) * sy
            let y1 = Double(dy + 1) * sy
            let iy0 = Int(y0.rounded(.down))
            let iy1 = min(srcH, Int(y1.rounded(.up)))
            for dx in 0 ..< dstW {
                let x0 = Double(dx) * sx
                let x1 = Double(dx + 1) * sx
                let ix0 = Int(x0.rounded(.down))
                let ix1 = min(srcW, Int(x1.rounded(.up)))

                var sumW = 0.0 // Σ area
                var sumA = 0.0 // Σ alpha-fraction · area
                var sumR = 0.0, sumG = 0.0, sumB = 0.0 // Σ (channel · alpha-fraction) · area
                for yy in iy0 ..< iy1 {
                    let wy = min(y1, Double(yy + 1)) - max(y0, Double(yy))
                    if wy <= 0 { continue }
                    let row = yy * srcW * 4
                    for xx in ix0 ..< ix1 {
                        let wx = min(x1, Double(xx + 1)) - max(x0, Double(xx))
                        if wx <= 0 { continue }
                        let w = wx * wy
                        let p = row + xx * 4
                        let af = Double(src[p + 3]) / 255.0
                        sumW += w
                        sumA += af * w
                        sumR += Double(src[p]) * af * w
                        sumG += Double(src[p + 1]) * af * w
                        sumB += Double(src[p + 2]) * af * w
                    }
                }

                let o = (dy * dstW + dx) * 4
                guard sumW > 0 else { continue } // leaves a fully transparent black pixel
                let alpha = sumA / sumW // average alpha fraction
                // Unpremultiply: straight channel = Σ(c·af·area) / Σ(af·area).
                // When the covered region is fully transparent (sumA == 0) the
                // colour is undefined, so leave it black.
                let r = sumA > 0 ? sumR / sumA : 0
                let g = sumA > 0 ? sumG / sumA : 0
                let b = sumA > 0 ? sumB / sumA : 0
                out[o] = clampByte(r)
                out[o + 1] = clampByte(g)
                out[o + 2] = clampByte(b)
                out[o + 3] = clampByte(alpha * 255)
            }
        }
        return out
    }

    private static func clampByte(_ v: Double) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }

    /// Decode `pngData`, down-render it to `size`×`size`, and re-encode as a
    /// PNG suitable for an `RT_ICON` payload (alpha preserved). Returns `nil`
    /// if the bytes can't be decoded or the stb path isn't available on this
    /// host (macOS — never reached, the Windows bundler only runs on Windows).
    static func resizePNG(_ pngData: Data, to size: Int) -> Data? {
        #if canImport(CStbImage)
            var w: Int32 = 0
            var h: Int32 = 0
            let decoded: UnsafeMutablePointer<UInt8>? = pngData.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return swiftpwa_decode_image_rgba(base, Int32(pngData.count), &w, &h)
            }
            guard let decoded, w > 0, h > 0 else { return nil }
            defer { swiftpwa_free_image(decoded) }
            let srcW = Int(w)
            let srcH = Int(h)
            let src = Array(UnsafeBufferPointer(start: decoded, count: srcW * srcH * 4))
            let dst = downscaleRGBA(src, srcW: srcW, srcH: srcH, dstW: size, dstH: size)

            var outLen: Int32 = 0
            let encoded: UnsafeMutablePointer<UInt8>? = dst.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return nil }
                return swiftpwa_encode_png_rgba(base, Int32(size), Int32(size), &outLen)
            }
            guard let encoded, outLen > 0 else { return nil }
            defer { swiftpwa_free_png(encoded) }
            return Data(bytes: encoded, count: Int(outLen))
        #else
            _ = (pngData, size)
            return nil
        #endif
    }

    /// Build the icon group for a source PNG: the source itself (verbatim,
    /// clamped to a 256 sentinel dimension in the directory) plus a
    /// down-rendered image for each of `renderedSizes` strictly smaller than
    /// the source. Ids are assigned 1, 2, 3, … in embed order. Returns just
    /// the single source image if the resize path is unavailable or every
    /// resize fails, so the caller always gets *an* icon.
    static func buildImages(source pngData: Data, width: Int, height: Int) -> [IconImage] {
        var images: [IconImage] = []
        var nextID: UInt16 = 1
        // Largest slot: the source verbatim (no re-encode, no quality loss).
        images.append(IconImage(width: width, height: height, png: pngData, id: nextID))
        nextID += 1

        let sourceSide = min(width, height)
        for size in renderedSizes where size < sourceSide {
            guard let resized = resizePNG(pngData, to: size) else { continue }
            images.append(IconImage(width: size, height: size, png: resized, id: nextID))
            nextID += 1
        }
        return images
    }

    enum EmbedError: Error, CustomStringConvertible {
        case notSupportedOnHost
        case beginFailed(UInt32)
        case updateFailed(UInt32)
        case endFailed(UInt32)

        var description: String {
            switch self {
            case .notSupportedOnHost: "icon embedding requires a Windows host"
            case let .beginFailed(code): "BeginUpdateResource failed (error \(code))"
            case let .updateFailed(code): "UpdateResource failed (error \(code))"
            case let .endFailed(code): "EndUpdateResource failed (error \(code))"
            }
        }
    }

    /// Inject each image in `images` as an `RT_ICON` at its `id`, plus the
    /// `groupDirectory` as `RT_GROUP_ICON` at `groupID`, into `exe`,
    /// preserving any resources already there (e.g. the Common Controls
    /// manifest). Windows-only — throws `notSupportedOnHost` elsewhere (the
    /// portable Windows build only runs on Windows, so this branch is never
    /// hit in practice).
    static func embed(images: [IconImage], groupDirectory: Data, groupID: UInt16, into exe: URL) throws {
        #if os(Windows)
            // RT_ICON = 3, RT_GROUP_ICON = 14, passed as MAKEINTRESOURCE
            // (an integer-valued LPWSTR). The resource *name* is the id,
            // encoded the same way.
            let RT_ICON = UnsafePointer<WCHAR>(bitPattern: 3)
            let RT_GROUP_ICON = UnsafePointer<WCHAR>(bitPattern: 14)

            let handle = exe.path.withCString(encodedAs: UTF16.self) { BeginUpdateResourceW($0, false) }
            guard let handle else { throw EmbedError.beginFailed(GetLastError()) }

            func put(_ type: UnsafePointer<WCHAR>?, _ id: UInt16, _ bytes: Data) throws {
                let name = UnsafePointer<WCHAR>(bitPattern: Int(id))
                let ok = bytes.withUnsafeBytes { raw in
                    UpdateResourceW(
                        handle, type, name, 0,
                        UnsafeMutableRawPointer(mutating: raw.baseAddress), DWORD(raw.count)
                    )
                }
                if ok == false {
                    let code = GetLastError()
                    _ = EndUpdateResourceW(handle, true) // discard
                    throw EmbedError.updateFailed(code)
                }
            }

            for image in images {
                try put(RT_ICON, image.id, image.png)
            }
            try put(RT_GROUP_ICON, groupID, groupDirectory)

            if EndUpdateResourceW(handle, false) == false {
                throw EmbedError.endFailed(GetLastError())
            }
        #else
            _ = (images, groupDirectory, groupID, exe)
            throw EmbedError.notSupportedOnHost
        #endif
    }
}
