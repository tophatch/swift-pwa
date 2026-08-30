import Foundation

/// Plugin exposing the `image.*` command set: decode an image with the
/// platform's codec and hand the page back one it can actually display.
///
/// **Why this exists.** The webview is often the least capable image decoder on
/// the device. Measured across the four engines this project ships on, HEIC —
/// what every photo an iPhone writes to iCloud Drive actually is — renders in
/// exactly one of them, Apple's; WebKitGTK links no HEIF or AVIF decoder at
/// all, and Chromium (WebView2 and Android's `WebView`) has AVIF but not HEIC.
/// The platform underneath is another matter: Apple's ImageIO and Android's
/// `BitmapFactory` both decode HEIC *and* AVIF. So an app that accepts photos
/// from a user's filesystem can convert on import instead of refusing the
/// format, and this is the seam that lets it.
///
/// **Opt-in**, the same way as `net.*` / `secrets.*`:
/// `ctx.use(ImagePlugin(PlatformImageTranscoder()))` (add the `SwiftPWAImage`
/// product). Registered without a transcoder it defaults to
/// ``UnsupportedImageTranscoder``, so the contract exists and every call fails
/// loudly rather than silently producing a broken image.
///
/// ## Commands
/// - `image.info()` → ``ImageCodecCapabilities``. What this build can read and
///   write, as lowercase extensions. **Ask before relying on a format** — the
///   answer differs per platform, and on Windows per machine.
/// - `image.transcode(ImageTranscodeRequest)` → ``ImageTranscodeResult``.
///
/// A source this build can't decode, or an output format it can't write, throws
/// `E_IMAGE_UNSUPPORTED`; anything else that goes wrong throws `E_IMAGE`. The
/// two are distinct because the first is a question the page could have asked
/// via `image.info` and the second isn't.
public struct ImagePlugin: Plugin {
    public static let pluginName = "image"

    private let transcoder: any ImageTranscoder

    public init(_ transcoder: any ImageTranscoder = UnsupportedImageTranscoder()) {
        self.transcoder = transcoder
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let transcoder = transcoder

        registry.register("image.info", typed: { (_: EmptyArgs, _) async throws -> ImageCodecCapabilities in
            await transcoder.capabilities()
        })

        registry.register(
            "image.transcode",
            typed: { (args: ImageTranscodeArgs, _) async throws -> ImageTranscodeResult in
                do {
                    return try await transcoder.transcode(args.request())
                } catch let error as ImageTranscodeError {
                    switch error {
                    case .unsupportedSource, .unsupportedOutput:
                        throw BridgeError(code: BridgeError.imageUnsupported, message: error.description)
                    case .invalidRequest, .failed:
                        throw BridgeError(code: BridgeError.image, message: error.description)
                    }
                }
            }
        )
    }
}

// MARK: - Wire types (JS-facing)

/// The JS shape of a transcode request. Separate from ``ImageTranscodeRequest``
/// so the wire can validate `format` as a string and reject an unknown one with
/// a message naming the valid values, rather than failing as an opaque decode
/// error on an enum.
public struct ImageTranscodeArgs: Sendable, Codable, Equatable {
    public var path: String?
    public var dataBase64: String?
    public var format: String?
    public var maxSide: Int?
    public var quality: Double?
    public var outputPath: String?

    public init(
        path: String? = nil,
        dataBase64: String? = nil,
        format: String? = nil,
        maxSide: Int? = nil,
        quality: Double? = nil,
        outputPath: String? = nil
    ) {
        self.path = path
        self.dataBase64 = dataBase64
        self.format = format
        self.maxSide = maxSide
        self.quality = quality
        self.outputPath = outputPath
    }

    func request() throws -> ImageTranscodeRequest {
        let resolved: ImageOutputFormat
        if let format {
            guard let parsed = ImageOutputFormat(rawValue: format.lowercased()) else {
                throw ImageTranscodeError.unsupportedOutput(
                    "\(format) — valid formats are \(ImageOutputFormat.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            resolved = parsed
        } else {
            resolved = .png
        }
        return ImageTranscodeRequest(
            path: path,
            dataBase64: dataBase64,
            format: resolved,
            maxSide: maxSide,
            quality: quality,
            outputPath: outputPath
        )
    }
}
