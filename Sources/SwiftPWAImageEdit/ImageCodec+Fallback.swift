#if !(canImport(CoreGraphics) && canImport(ImageIO)) && !os(Linux) && !os(Windows)
    import Foundation

    /// Fallback `ImageCodec` for platforms without a real implementation yet —
    /// i.e. **Android** (Apple uses CoreGraphics, Linux/Windows use stb_image
    /// via `CStbImage`). The Android decode/encode path — `BitmapFactory` over
    /// the Kotlin RPC, as `SwiftPWASegmentation`'s `AndroidImagePreprocessing`
    /// does — is the remaining follow-up (see
    /// `docs/proposals/image-generation-editing.md`); until it lands,
    /// `ai.generateImage` throws a clear `E_AI_GENERATION` here rather than
    /// mis-decoding.
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

        static func resizeRGB(_: RawImage, toWidth _: Int, height _: Int) throws -> RawImage {
            throw ImageCodecError
                .encodeFailed("image resize is not yet implemented on this platform (Apple-only for now)")
        }
    }
#endif
