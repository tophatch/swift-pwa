#if !(canImport(CoreGraphics) && canImport(ImageIO)) && !os(Linux) && !os(Windows) && !os(Android)
    import Foundation

    /// Fallback `ImageCodec` for any platform without a real implementation —
    /// none of the ones this package targets (Apple uses CoreGraphics,
    /// Linux/Windows use stb_image via `CStbImage`, Android uses BitmapFactory
    /// over the Kotlin RPC). Kept as a safety stub so the target still compiles
    /// on an unexpected destination, throwing a clear `E_AI_GENERATION` rather
    /// than mis-decoding.
    package extension ImageCodec {
        static func decodeRGB(
            path _: String?,
            dataBase64 _: String?,
            size _: (width: Int, height: Int)?
        ) async throws -> RawImage {
            throw ImageCodecError.decodeFailed("image decode is not implemented on this platform")
        }

        static func decodeGray(
            path _: String?,
            dataBase64 _: String?,
            size _: (width: Int, height: Int)?
        ) async throws -> RawImage {
            throw ImageCodecError.decodeFailed("image decode is not implemented on this platform")
        }

        static func encodePNG(_: RawImage) async throws -> Data {
            throw ImageCodecError.encodeFailed("PNG encode is not implemented on this platform")
        }

        static func decodeRGBFit(path _: String?, dataBase64 _: String?, maxSide _: Int) async throws -> RawImage {
            throw ImageCodecError.decodeFailed("image decode is not implemented on this platform")
        }

        static func resizeRGB(_: RawImage, toWidth _: Int, height _: Int) async throws -> RawImage {
            throw ImageCodecError.encodeFailed("image resize is not implemented on this platform")
        }
    }
#endif
