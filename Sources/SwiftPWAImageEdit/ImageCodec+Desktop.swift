#if os(Linux) || os(Windows)
    import CStbImage
    import Foundation

    /// Desktop (Linux/Windows) `ImageCodec` — no CoreGraphics/ImageIO, so decode
    /// goes through the vendored public-domain stb_image and PNG encode through
    /// stb_image_write (both in `CStbImage`); resize is a pure-Swift bilinear
    /// resample (the same convention `SwiftPWASegmentation`'s
    /// `DesktopImagePreprocessing` uses). Produces the same `RawImage` / PNG
    /// bytes as the Apple path.
    extension ImageCodec {
        static func decodeRGB(
            path: String?,
            dataBase64: String?,
            size: (width: Int, height: Int)?
        ) async throws -> RawImage {
            let native = try decodeNativeRGB(path: path, dataBase64: dataBase64)
            guard let size, size.width != native.width || size.height != native.height else { return native }
            return resample(native, toWidth: size.width, height: size.height)
        }

        static func decodeGray(
            path: String?,
            dataBase64: String?,
            size: (width: Int, height: Int)?
        ) async throws -> RawImage {
            let rgb = try await decodeRGB(path: path, dataBase64: dataBase64, size: size)
            var gray = [UInt8](repeating: 0, count: rgb.width * rgb.height)
            for pixel in 0 ..< (rgb.width * rgb.height) {
                let r = Int(rgb.pixels[pixel * 3])
                let g = Int(rgb.pixels[pixel * 3 + 1])
                let b = Int(rgb.pixels[pixel * 3 + 2])
                gray[pixel] = UInt8((299 * r + 587 * g + 114 * b) / 1000) // Rec. 601 luma
            }
            return RawImage(pixels: gray, width: rgb.width, height: rgb.height, channels: 1)
        }

        static func encodePNG(_ image: RawImage) async throws -> Data {
            guard image.channels == 3 else {
                throw ImageCodecError.encodeFailed("encodePNG expects RGB (3 channels), got \(image.channels)")
            }
            var outLen: Int32 = 0
            let encoded: UnsafeMutablePointer<UInt8>? = image.pixels.withUnsafeBufferPointer { buffer in
                swiftpwa_encode_png_rgb(buffer.baseAddress, Int32(image.width), Int32(image.height), &outLen)
            }
            guard let encoded, outLen > 0 else {
                throw ImageCodecError.encodeFailed("stb_image_write returned no PNG bytes")
            }
            defer { swiftpwa_free_png(encoded) }
            return Data(bytes: encoded, count: Int(outLen))
        }

        static func resizeRGB(_ image: RawImage, toWidth width: Int, height: Int) async throws -> RawImage {
            if image.width == width, image.height == height { return image }
            return resample(image, toWidth: width, height: height)
        }

        private static func decodeNativeRGB(path: String?, dataBase64: String?) throws -> RawImage {
            let data: Data
            if let path {
                guard let contents = FileManager.default.contents(atPath: path) else {
                    throw ImageCodecError.decodeFailed(path)
                }
                data = contents
            } else if let dataBase64, let bytes = Data(base64Encoded: dataBase64) {
                data = bytes
            } else {
                throw ImageCodecError.decodeFailed("neither a path nor valid base64 image data")
            }

            var width: Int32 = 0
            var height: Int32 = 0
            // stb returns a freshly malloc'd RGB8 buffer (alpha dropped),
            // independent of `data`'s storage — safe to copy out then free.
            let pixels: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
                swiftpwa_decode_image_rgb(
                    raw.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &width, &height
                )
            }
            guard let pixels, width > 0, height > 0 else {
                throw ImageCodecError.decodeFailed(path ?? "<in-memory image data>")
            }
            defer { swiftpwa_free_image(pixels) }
            let w = Int(width), h = Int(height)
            return RawImage(
                pixels: Array(UnsafeBufferPointer(start: pixels, count: w * h * 3)),
                width: w, height: h, channels: 3
            )
        }

        /// Bilinear resample of a packed multi-channel `RawImage` (pixel-center
        /// mapping, align_corners = false — matching the Apple/Android paths).
        private static func resample(_ image: RawImage, toWidth: Int, height dstH: Int) -> RawImage {
            let c = image.channels, srcW = image.width, srcH = image.height
            let dstW = toWidth
            var out = [UInt8](repeating: 0, count: dstW * dstH * c)
            let sxScale = Double(srcW) / Double(dstW)
            let syScale = Double(srcH) / Double(dstH)
            for dy in 0 ..< dstH {
                let syf = (Double(dy) + 0.5) * syScale - 0.5
                let sy0 = max(0, min(srcH - 1, Int(syf.rounded(.down))))
                let sy1 = min(srcH - 1, sy0 + 1)
                let wy = max(0.0, min(1.0, syf - Double(sy0)))
                for dx in 0 ..< dstW {
                    let sxf = (Double(dx) + 0.5) * sxScale - 0.5
                    let sx0 = max(0, min(srcW - 1, Int(sxf.rounded(.down))))
                    let sx1 = min(srcW - 1, sx0 + 1)
                    let wx = max(0.0, min(1.0, sxf - Double(sx0)))
                    let row0 = sy0 * srcW, row1 = sy1 * srcW
                    let dst = (dy * dstW + dx) * c
                    for channel in 0 ..< c {
                        let p00 = Double(image.pixels[(row0 + sx0) * c + channel])
                        let p01 = Double(image.pixels[(row0 + sx1) * c + channel])
                        let p10 = Double(image.pixels[(row1 + sx0) * c + channel])
                        let p11 = Double(image.pixels[(row1 + sx1) * c + channel])
                        let top = p00 + (p01 - p00) * wx
                        let bottom = p10 + (p11 - p10) * wx
                        out[dst + channel] = UInt8(max(0, min(255, (top + (bottom - top) * wy).rounded())))
                    }
                }
            }
            return RawImage(pixels: out, width: dstW, height: dstH, channels: c)
        }
    }
#endif
