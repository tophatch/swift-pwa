#if os(Android)
    import Foundation
    import SwiftPWAAndroid

    /// Android `ImageCodec`. No CoreGraphics/ImageIO and no filesystem access to
    /// SAF `content://` URIs, so decode/encode run Kotlin-side over the same
    /// generic JNI RPC bridge `SwiftPWASegmentation`'s `AndroidImagePreprocessing`
    /// uses: `image.decode` (BitmapFactory decode + optional exact resize →
    /// raw RGB/gray bytes) and `image.encodePng` (Bitmap.compress) — both
    /// generated into the app's Kotlin `MainActivity` (see AndroidTemplates.swift).
    /// This is why the whole `ImageCodec` surface is `async`. `path` may be a
    /// plain path or a `content://` URI (Kotlin branches on the scheme).
    extension ImageCodec {
        package static func decodeRGB(
            path: String?,
            dataBase64: String?,
            size: (width: Int, height: Int)?
        ) async throws -> RawImage {
            try await decode(path: path, dataBase64: dataBase64, size: size, maxSide: nil, channels: 3)
        }

        package static func decodeGray(
            path: String?,
            dataBase64: String?,
            size: (width: Int, height: Int)?
        ) async throws -> RawImage {
            try await decode(path: path, dataBase64: dataBase64, size: size, maxSide: nil, channels: 1)
        }

        package static func decodeRGBFit(path: String?, dataBase64: String?, maxSide: Int) async throws -> RawImage {
            try await decode(path: path, dataBase64: dataBase64, size: nil, maxSide: maxSide, channels: 3)
        }

        package static func encodePNG(_ image: RawImage) async throws -> Data {
            guard image.channels == 3 else {
                throw ImageCodecError.encodeFailed("encodePNG expects RGB (3 channels), got \(image.channels)")
            }
            let result: EncodeResult
            do {
                result = try await AndroidRPC.call(
                    "image.encodePng",
                    EncodeArgs(
                        rgbBase64: Data(image.pixels).base64EncodedString(),
                        width: image.width,
                        height: image.height
                    ),
                    as: EncodeResult.self
                )
            } catch {
                throw ImageCodecError.encodeFailed("\(error)")
            }
            guard let data = Data(base64Encoded: result.dataBase64) else {
                throw ImageCodecError.encodeFailed("Android RPC returned invalid PNG base64")
            }
            return data
        }

        package static func resizeRGB(_ image: RawImage, toWidth width: Int, height: Int) async throws -> RawImage {
            if image.width == width, image.height == height { return image }
            // Round-trip through the encode + resizing-decode RPCs (there's no
            // dedicated resize method; the decode path already resizes).
            let png = try await encodePNG(image)
            return try await decodeRGB(path: nil, dataBase64: png.base64EncodedString(), size: (width, height))
        }

        private static func decode(
            path: String?, dataBase64: String?, size: (width: Int, height: Int)?, maxSide: Int?, channels: Int
        ) async throws -> RawImage {
            let result: DecodeResult
            do {
                result = try await AndroidRPC.call(
                    "image.decode",
                    DecodeArgs(
                        path: path,
                        dataBase64: dataBase64,
                        width: size?.width,
                        height: size?.height,
                        maxSide: maxSide,
                        channels: channels
                    ),
                    as: DecodeResult.self
                )
            } catch {
                throw ImageCodecError.decodeFailed("\(error)")
            }
            guard let pixels = Data(base64Encoded: result.pixelsBase64) else {
                throw ImageCodecError.decodeFailed("Android RPC returned invalid pixel base64")
            }
            let expected = result.width * result.height * channels
            guard pixels.count == expected else {
                throw ImageCodecError.decodeFailed("Android RPC returned \(pixels.count) bytes, expected \(expected)")
            }
            return RawImage(pixels: [UInt8](pixels), width: result.width, height: result.height, channels: channels)
        }

        private struct DecodeArgs: Encodable {
            let path: String?
            let dataBase64: String?
            let width: Int?
            let height: Int?
            let maxSide: Int?
            let channels: Int
        }

        private struct DecodeResult: Decodable {
            let pixelsBase64: String
            let width: Int
            let height: Int
        }

        private struct EncodeArgs: Encodable {
            let rgbBase64: String
            let width: Int
            let height: Int
        }

        private struct EncodeResult: Decodable {
            let dataBase64: String
        }
    }
#endif
