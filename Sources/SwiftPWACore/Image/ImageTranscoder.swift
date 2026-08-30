import Foundation

/// What an image transcoder can read and write on *this* build, on *this*
/// machine. Both lists are lowercase file extensions.
///
/// This is reported rather than assumed because the honest answer varies by
/// platform and, on some platforms, by machine: Apple's ImageIO reads HEIC and
/// AVIF, the desktop `stb_image` decoder reads neither, and a Windows box only
/// decodes HEIC when the (paid/OEM-supplied) HEVC codec extension is installed.
/// A page that needs a format should ask before relying on it.
public struct ImageCodecCapabilities: Sendable, Codable, Equatable {
    /// Extensions this build can decode, lowercase and without a dot.
    public var decode: [String]
    /// Extensions this build can encode to.
    public var encode: [String]

    public init(decode: [String], encode: [String]) {
        self.decode = decode
        self.encode = encode
    }
}

/// The format a transcode writes. Deliberately short: these are the two every
/// webview this project ships on renders, which is the entire point of the
/// conversion.
public enum ImageOutputFormat: String, Sendable, Codable, CaseIterable {
    case png
    case jpeg
}

/// One conversion. Exactly one of ``path`` and ``dataBase64`` supplies the
/// source, mirroring `AIImage`.
public struct ImageTranscodeRequest: Sendable, Equatable {
    /// A filesystem path, or on Android a SAF `content://` URI.
    public var path: String?
    /// The source bytes inline, base64-encoded.
    public var dataBase64: String?
    public var format: ImageOutputFormat
    /// Bound the longest edge, preserving aspect ratio. Strongly recommended
    /// for camera images: a 24-megapixel photo is ~72 MB of RGB per buffer, and
    /// decoding one at full size is what made `LaMaBackend` need the same
    /// limit. `nil` keeps the source dimensions.
    public var maxSide: Int?
    /// JPEG quality, `0...1`. Ignored for PNG.
    public var quality: Double?
    /// Where to write the result. When `nil`, the bytes come back inline —
    /// convenient, but a large photo crosses the bridge as base64, so prefer a
    /// path for anything camera-sized.
    public var outputPath: String?

    public init(
        path: String? = nil,
        dataBase64: String? = nil,
        format: ImageOutputFormat = .png,
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
}

/// The converted image: written to ``path`` when the request named one,
/// otherwise inline in ``dataBase64``. ``width`` / ``height`` are the *output*
/// dimensions, so a caller that passed `maxSide` learns what it actually got.
public struct ImageTranscodeResult: Sendable, Codable, Equatable {
    public var path: String?
    public var dataBase64: String?
    public var width: Int
    public var height: Int
    public var bytes: Int

    public init(path: String? = nil, dataBase64: String? = nil, width: Int, height: Int, bytes: Int) {
        self.path = path
        self.dataBase64 = dataBase64
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// Decodes an image with the platform's own codec and re-encodes it as
/// something a webview will render.
///
/// The seam exists because the platform underneath a webview is routinely more
/// capable than the webview itself — measured, HEIC decodes on Apple's ImageIO,
/// on Android's `BitmapFactory` and in Windows WIC, while only Apple's WebKit
/// will *render* it. `PlatformImageTranscoder` in `SwiftPWAImage` is the
/// shipped conformance; injecting your own is how you'd substitute a codec.
public protocol ImageTranscoder: Sendable {
    /// What this build can actually read and write. Cheap to call.
    func capabilities() async -> ImageCodecCapabilities
    /// Convert one image. Throws ``ImageTranscodeError`` on a source this build
    /// cannot decode or an output format it cannot write.
    func transcode(_ request: ImageTranscodeRequest) async throws -> ImageTranscodeResult
}

public enum ImageTranscodeError: Error, Equatable, CustomStringConvertible {
    /// The build has no decoder for this source.
    case unsupportedSource(String)
    /// The build cannot write this output format.
    case unsupportedOutput(String)
    /// Neither, or both, of `path` and `dataBase64` were supplied.
    case invalidRequest(String)
    case failed(String)

    public var description: String {
        switch self {
        case let .unsupportedSource(m): "cannot decode this image: \(m)"
        case let .unsupportedOutput(m): "cannot encode to this format: \(m)"
        case let .invalidRequest(m): "invalid transcode request: \(m)"
        case let .failed(m): "transcode failed: \(m)"
        }
    }
}

/// The default when ``ImagePlugin`` is registered without a transcoder: the JS
/// contract still exists, `image.info` honestly reports nothing, and every
/// conversion throws rather than pretending.
public struct UnsupportedImageTranscoder: ImageTranscoder {
    public init() {}

    public func capabilities() async -> ImageCodecCapabilities {
        ImageCodecCapabilities(decode: [], encode: [])
    }

    public func transcode(_: ImageTranscodeRequest) async throws -> ImageTranscodeResult {
        throw ImageTranscodeError.failed(
            "no image transcoder configured — register ImagePlugin(PlatformImageTranscoder()) "
                + "and add the SwiftPWAImage product"
        )
    }
}
