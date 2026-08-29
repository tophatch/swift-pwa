#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// Apple `ImageCodec` — decode/resize via CoreGraphics, encode PNG via
    /// ImageIO. The desktop (stb_image) and Android (RPC) counterparts produce
    /// the same `RawImage` / PNG bytes.
    package extension ImageCodec {
        /// Decode an image file / base64 blob to RGB (`channels == 3`),
        /// resized to `size` when given (nearest-fit exact `width × height`).
        static func decodeRGB(
            path: String?,
            dataBase64: String?,
            size: (width: Int, height: Int)?
        ) async throws -> RawImage {
            let cgImage = try loadCGImage(path: path, dataBase64: dataBase64)
            return try render(cgImage, channels: 3, size: size)
        }

        /// Decode a mask file / base64 blob to a single grayscale channel
        /// (`channels == 1`), resized to `size` when given.
        static func decodeGray(
            path: String?,
            dataBase64: String?,
            size: (width: Int, height: Int)?
        ) async throws -> RawImage {
            let cgImage = try loadCGImage(path: path, dataBase64: dataBase64)
            return try render(cgImage, channels: 1, size: size)
        }

        /// Decode to RGB fitting the longest side to `maxSide` (aspect
        /// preserved), returning the actual decoded dims. Bounds the working
        /// resolution so a huge source photo never materializes at full size.
        static func decodeRGBFit(path: String?, dataBase64: String?, maxSide: Int) async throws -> RawImage {
            let cgImage = try loadCGImage(path: path, dataBase64: dataBase64)
            let longest = max(cgImage.width, cgImage.height)
            guard maxSide > 0, longest > maxSide else { return try render(cgImage, channels: 3, size: nil) }
            let scale = Double(maxSide) / Double(longest)
            let w = max(1, Int((Double(cgImage.width) * scale).rounded()))
            let h = max(1, Int((Double(cgImage.height) * scale).rounded()))
            return try render(cgImage, channels: 3, size: (w, h))
        }

        /// Resize an RGB `RawImage` to `width × height` (no-op if already that
        /// size). Reuses the verified encode/decode paths — a lossless PNG
        /// round-trip through the resizing decoder.
        static func resizeRGB(_ image: RawImage, toWidth width: Int, height: Int) async throws -> RawImage {
            if image.width == width, image.height == height { return image }
            let png = try await encodePNG(image)
            return try await decodeRGB(path: nil, dataBase64: png.base64EncodedString(), size: (width, height))
        }

        /// What ImageIO on *this* OS version can actually read and write.
        /// Enumerated rather than hard-coded: the list genuinely moves between
        /// OS releases (AVIF read arrived in macOS 13 / iOS 16), and a wrong
        /// answer here is a page told it can convert something it can't.
        static func capabilities() -> (decode: [String], encode: [String]) {
            func extensions(for identifiers: [String]) -> [String] {
                var seen: Set<String> = []
                for id in identifiers {
                    guard let type = UTType(id) else { continue }
                    for ext in type.tags[.filenameExtension] ?? [] {
                        seen.insert(ext.lowercased())
                    }
                }
                return seen.sorted()
            }
            let readable = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
            let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            // Encode is narrowed to what `encode(_:format:quality:)` implements,
            // not everything ImageIO could write.
            let supportedOut = extensions(for: writable)
            return (
                decode: extensions(for: readable),
                encode: ["png", "jpeg", "jpg"].filter { supportedOut.contains($0) }
            )
        }

        /// Encode tightly-packed RGB pixels as PNG or JPEG.
        static func encode(_ image: RawImage, format: ImageEncoding, quality: Double?) async throws -> Data {
            let png = try await encodePNG(image)
            guard format == .jpeg else { return png }
            // Re-encode through ImageIO rather than building a second CGImage by
            // hand: the PNG path above already resolved the packed-RGB → RGBA
            // and orientation questions, and getting those subtly different
            // between the two formats is exactly the bug class that produced
            // upside-down output once before.
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw ImageCodecError.encodeFailed("could not re-read intermediate bitmap for JPEG output")
            }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil
            ) else {
                throw ImageCodecError.encodeFailed("could not create a JPEG destination")
            }
            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: min(max(quality ?? 0.85, 0), 1)
            ]
            CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw ImageCodecError.encodeFailed("JPEG finalize failed")
            }
            return data as Data
        }

        /// Encode tightly-packed RGB pixels to PNG bytes.
        static func encodePNG(_ image: RawImage) async throws -> Data {
            guard image.channels == 3 else {
                throw ImageCodecError.encodeFailed("encodePNG expects RGB (3 channels), got \(image.channels)")
            }
            let width = image.width, height = image.height
            // CoreGraphics has no packed-RGB (24bpp) bitmap context, so widen
            // to RGBA with an opaque alpha before handing it to ImageIO. A
            // data-backed bitmap context is **top-row-first** — `makeImage()`
            // treats buffer row 0 as the visual top (the same orientation a
            // no-flip `draw` reads back, see `render` and
            // `SwiftPWASegmentation`'s ImagePreprocessing fix) — so copy the
            // top-row-first `RawImage` straight across with **no vertical flip**.
            // (The prior `(height-1-y)` flip inverted the output; it was masked
            // for decode→encode round-trips like `resizeRGB` and the LaMa
            // decode→edit→encode path by a matching flip in `render`, and only
            // surfaced once a producer — Stable Diffusion's VAE — fed a top-down
            // image straight to encode with no decode to cancel it.)
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0 ..< height {
                let dstRow = y * width
                let srcRow = y * width
                for x in 0 ..< width {
                    rgba[(dstRow + x) * 4] = image.pixels[(srcRow + x) * 3]
                    rgba[(dstRow + x) * 4 + 1] = image.pixels[(srcRow + x) * 3 + 1]
                    rgba[(dstRow + x) * 4 + 2] = image.pixels[(srcRow + x) * 3 + 2]
                }
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: &rgba, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ),
                  let cgImage = context.makeImage()
            else {
                throw ImageCodecError.encodeFailed("could not build a CGImage for PNG output")
            }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil
            ) else {
                throw ImageCodecError.encodeFailed("could not create a PNG destination")
            }
            CGImageDestinationAddImage(dest, cgImage, nil)
            guard CGImageDestinationFinalize(dest) else {
                throw ImageCodecError.encodeFailed("PNG finalize failed")
            }
            return data as Data
        }

        private static func loadCGImage(path: String?, dataBase64: String?) throws -> CGImage {
            let source: CGImageSource?
            if let path {
                source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
            } else if let dataBase64, let bytes = Data(base64Encoded: dataBase64) {
                source = CGImageSourceCreateWithData(bytes as CFData, nil)
            } else {
                throw ImageCodecError.decodeFailed("neither a path nor valid base64 image data")
            }
            guard let source, let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ImageCodecError.decodeFailed(path ?? "<in-memory image data>")
            }
            return cgImage
        }

        /// Draw `cgImage` into a fresh bitmap at `size` (or its native size)
        /// and read back tightly-packed channels. Always renders RGBA then
        /// narrows: to RGB (drop alpha) or to luminance (Rec. 601).
        private static func render(
            _ cgImage: CGImage,
            channels: Int,
            size: (width: Int, height: Int)?
        ) throws -> RawImage {
            let width = size?.width ?? cgImage.width
            let height = size?.height ?? cgImage.height
            guard width > 0, height > 0 else { throw ImageCodecError.decodeFailed("zero-sized image") }

            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: &rgba, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                throw ImageCodecError.decodeFailed("could not create an RGBA bitmap context")
            }
            // No vertical flip: a `CGImage` drawn into a fresh data-backed bitmap
            // context lands **top-down** — buffer row 0 is the visual top — so a
            // plain draw already reads back top-row-first (the SwiftPWASegmentation
            // ImagePreprocessing fix established this; a translateBy/scaleBy(-1)
            // here would invert it). Keeps decode top-down to match `encodePNG`
            // and the desktop/Android codecs.
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

            var pixels = [UInt8](repeating: 0, count: width * height * channels)
            for pixel in 0 ..< (width * height) {
                let r = Int(rgba[pixel * 4]), g = Int(rgba[pixel * 4 + 1]), b = Int(rgba[pixel * 4 + 2])
                if channels == 3 {
                    pixels[pixel * 3] = UInt8(r)
                    pixels[pixel * 3 + 1] = UInt8(g)
                    pixels[pixel * 3 + 2] = UInt8(b)
                } else {
                    // Rec. 601 luma — a mask is usually already gray, this just
                    // collapses any color channel differences deterministically.
                    let luma = (299 * r + 587 * g + 114 * b) / 1000
                    pixels[pixel] = UInt8(luma)
                }
            }
            return RawImage(pixels: pixels, width: width, height: height, channels: channels)
        }
    }
#endif
