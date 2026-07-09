#if os(Android)
    import Foundation
    import SwiftPWAAndroid

    /// The Android `ImagePreprocessing.load` implementation. There's no
    /// CoreGraphics/ImageIO on Android, so image decode + resize happens
    /// Kotlin-side (`android.graphics.BitmapFactory` /
    /// `Bitmap.createScaledBitmap`, `vision.preprocessImage` in the
    /// generated `SwiftPWASystemPlugins`) over the same generic JNI RPC
    /// bridge `AndroidArchiveExtractor` uses for zip work — Kotlin returns
    /// the already-resized raw RGB bytes base64-encoded, which this file
    /// just decodes into the shared `[Float]` HWC tensor. See
    /// `ImagePreprocessing.swift` for the Apple counterpart.
    extension ImagePreprocessing {
        /// `path` may be a plain filesystem path or a SAF `content://` URI
        /// (the Kotlin side branches on the scheme, same convention as
        /// `AndroidArchiveExtractor`).
        static func load(path: String, targetSize: Int = 1024) async throws -> PreprocessedImage {
            try await request(path: path, dataBase64: nil, targetSize: targetSize)
        }

        static func load(dataBase64: String, targetSize: Int = 1024) async throws -> PreprocessedImage {
            try await request(path: nil, dataBase64: dataBase64, targetSize: targetSize)
        }

        private static func request(path: String?, dataBase64: String?, targetSize: Int) async throws
            -> PreprocessedImage
        {
            let result: PreprocessImageResult
            do {
                result = try await AndroidRPC.call(
                    "vision.preprocessImage",
                    PreprocessImageArgs(path: path, dataBase64: dataBase64, targetSize: targetSize),
                    as: PreprocessImageResult.self
                )
            } catch {
                throw ImagePreprocessingError.decodeFailed("\(error)")
            }

            guard let rgb = Data(base64Encoded: result.rgbBase64) else {
                throw ImagePreprocessingError.decodeFailed("Android RPC returned invalid rgbBase64")
            }
            let pixelCount = result.resizedWidth * result.resizedHeight
            guard rgb.count == pixelCount * 3 else {
                throw ImagePreprocessingError
                    .decodeFailed("Android RPC returned \(rgb.count) RGB bytes, expected \(pixelCount * 3)")
            }

            var tensor = [Float](repeating: 0, count: pixelCount * 3)
            for i in 0 ..< tensor.count {
                tensor[i] = Float(rgb[i])
            }
            let scale = Double(result.resizedWidth) / Double(result.originalWidth)
            return PreprocessedImage(
                tensor: tensor,
                originalWidth: result.originalWidth, originalHeight: result.originalHeight,
                resizedWidth: result.resizedWidth, resizedHeight: result.resizedHeight,
                scale: scale
            )
        }

        private struct PreprocessImageArgs: Encodable {
            let path: String?
            let dataBase64: String?
            let targetSize: Int
        }

        private struct PreprocessImageResult: Decodable {
            let rgbBase64: String
            let originalWidth: Int
            let originalHeight: Int
            let resizedWidth: Int
            let resizedHeight: Int
        }
    }
#endif
