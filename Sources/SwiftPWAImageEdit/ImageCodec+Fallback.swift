#if !(canImport(CoreGraphics) && canImport(ImageIO))
    import Foundation

    /// Non-Apple `ImageCodec` placeholder. The desktop (stb_image /
    /// stb_image_write, reusing `CStbImage`) and Android (`BitmapFactory` over
    /// the Kotlin RPC, as `SwiftPWASegmentation`'s `AndroidImagePreprocessing`
    /// does) decode/encode paths are the immediate follow-up to the Apple-first
    /// `LaMaBackend` cut — see `docs/proposals/image-generation-editing.md`.
    /// Until they land, `ai.generateImage` on this backend throws a clear
    /// `E_AI_GENERATION` here rather than mis-decoding.
    extension ImageCodec {
        static func decodeRGB(
            path _: String?,
            dataBase64 _: String?,
            size _: (width: Int, height: Int)?
        ) throws -> RawImage {
            throw ImageCodecError
                .decodeFailed("image decode is not yet implemented on this platform (Apple-only for now)")
        }

        static func decodeGray(
            path _: String?,
            dataBase64 _: String?,
            size _: (width: Int, height: Int)?
        ) throws -> RawImage {
            throw ImageCodecError
                .decodeFailed("image decode is not yet implemented on this platform (Apple-only for now)")
        }

        static func encodePNG(_: RawImage) throws -> Data {
            throw ImageCodecError
                .encodeFailed("PNG encode is not yet implemented on this platform (Apple-only for now)")
        }
    }
#endif
