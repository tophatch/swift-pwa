#if os(Windows)
    import CWicShim
    import Foundation

    /// Windows `ImageCodec`, over the Windows Imaging Component — the platform
    /// codec, and the counterpart to ImageIO on Apple and BitmapFactory on
    /// Android. It replaced the vendored stb_image here (which stays on Linux,
    /// the one target with no system codec) because WIC reads far more than
    /// stb's PNG + JPEG, and because HEIC is the whole point: Chromium has no
    /// HEIC decoder, so a WebView2 app cannot display an iPhone photo, but the
    /// machine underneath usually can.
    ///
    /// **What it can read is a property of the machine, not the build.** HEIC
    /// needs the HEVC codec extension — the paid/OEM-supplied one — and AVIF
    /// needs the AV1 extension, so ``capabilities()`` enumerates the registered
    /// decoders instead of claiming a fixed list. Never advertise HEIC on
    /// Windows statically; ask.
    package extension ImageCodec {
        static func decodeRGB(
            path: String?,
            dataBase64: String?,
            size: (width: Int, height: Int)?
        ) async throws -> RawImage {
            let native = try decodeNative(path: path, dataBase64: dataBase64, maxSide: 0)
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

        /// Asks WIC which decoders are registered right now. On a machine
        /// without the HEVC extension this simply won't contain `heic`, which
        /// is the honest answer and what `image.info` reports to the page.
        static func capabilities() -> (decode: [String], encode: [String]) {
            var buffer = [CChar](repeating: 0, count: 2048)
            let written = swiftpwa_wic_decode_extensions(&buffer, Int32(buffer.count))
            guard written > 0 else {
                // WIC unavailable (or COM refused): claim only what the encoder
                // side is built on rather than inventing a decode list.
                return (decode: [], encode: ["png", "jpeg", "jpg"])
            }
            let joined = String(cString: buffer)
            let decode = joined.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            return (decode: decode, encode: ["png", "jpeg", "jpg"])
        }

        static func encode(_ image: RawImage, format: ImageEncoding, quality: Double?) async throws -> Data {
            guard image.channels == 3 else {
                throw ImageCodecError.encodeFailed("encode expects RGB (3 channels), got \(image.channels)")
            }
            let isJPEG = format == .jpeg
            let clamped = Int32(min(max((quality ?? 0.85) * 100, 1), 100).rounded())
            var outLen: Int32 = 0
            let encoded: UnsafeMutablePointer<UInt8>? = image.pixels.withUnsafeBufferPointer { buffer in
                swiftpwa_wic_encode_rgb(
                    buffer.baseAddress, Int32(image.width), Int32(image.height),
                    isJPEG ? 1 : 0, clamped, &outLen
                )
            }
            guard let encoded, outLen > 0 else {
                throw ImageCodecError.encodeFailed("WIC returned no \(format.rawValue) bytes")
            }
            defer { swiftpwa_wic_free(encoded) }
            return Data(bytes: encoded, count: Int(outLen))
        }

        static func encodePNG(_ image: RawImage) async throws -> Data {
            try await encode(image, format: .png, quality: nil)
        }

        static func decodeRGBFit(path: String?, dataBase64: String?, maxSide: Int) async throws -> RawImage {
            // WIC scales during decode, so a large photo never exists at full
            // size in memory — unlike the resample-after-decode path the other
            // desktop backend has to take.
            try decodeNative(path: path, dataBase64: dataBase64, maxSide: maxSide)
        }

        static func resizeRGB(_ image: RawImage, toWidth width: Int, height: Int) async throws -> RawImage {
            if image.width == width, image.height == height { return image }
            return resample(image, toWidth: width, height: height)
        }

        // MARK: - Internals

        private static func decodeNative(path: String?, dataBase64: String?, maxSide: Int) throws -> RawImage {
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
            var length: Int32 = 0
            let pixels: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
                swiftpwa_wic_decode_rgb(
                    raw.bindMemory(to: UInt8.self).baseAddress, Int32(data.count),
                    Int32(max(0, maxSide)), &width, &height, &length
                )
            }
            guard let pixels, width > 0, height > 0, length > 0 else {
                // The common cause is a container this machine has no decoder
                // for (HEIC without the HEVC extension), not a corrupt file.
                throw ImageCodecError.decodeFailed(
                    "\(path ?? "<in-memory image data>") — no registered WIC decoder, or the data is not an image"
                )
            }
            defer { swiftpwa_wic_free(pixels) }
            let w = Int(width), h = Int(height)
            return RawImage(
                pixels: Array(UnsafeBufferPointer(start: pixels, count: Int(length))),
                width: w, height: h, channels: 3
            )
        }

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
