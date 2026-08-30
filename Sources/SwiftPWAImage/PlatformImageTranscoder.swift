import Foundation
import SwiftPWACore
import SwiftPWAImageIO

/// The shipped ``ImageTranscoder``: decodes with whatever codec the platform
/// provides and re-encodes as PNG or JPEG.
///
/// It adds no codec of its own. All it does is expose one an app's build
/// already contains — ImageIO on Apple, `BitmapFactory` over the JNI RPC on
/// Android, the vendored stb_image on Linux/Windows — because the webview in
/// front of it is frequently the least capable decoder on the device.
///
/// ```swift
/// ctx.use(ImagePlugin(PlatformImageTranscoder()))
/// ```
///
/// **What it can convert is not uniform, and is not guessed.** Apple enumerates
/// ImageIO's actual type list, Android asks the device (HEIF needs API 28, AVIF
/// API 31), and desktop reports the two formats stb is compiled for. `image.info`
/// returns that answer; a page that needs HEIC should check rather than assume.
public struct PlatformImageTranscoder: ImageTranscoder {
    /// Bounds the decode when a request names no `maxSide`. A camera image is
    /// ~72 MB of RGB at full size and on Android that has to cross a JNI RPC as
    /// base64, which is what made `LaMaBackend` adopt the same guard — so an
    /// unbounded default is a crash waiting for the first real photo. Pass a
    /// larger value if you genuinely want full resolution.
    public var defaultMaxSide: Int

    public init(defaultMaxSide: Int = 4096) {
        self.defaultMaxSide = defaultMaxSide
    }

    public func capabilities() async -> ImageCodecCapabilities {
        #if os(Android)
            let caps = await ImageCodec.capabilities()
        #else
            let caps = ImageCodec.capabilities()
        #endif
        return ImageCodecCapabilities(decode: caps.decode, encode: caps.encode)
    }

    public func transcode(_ request: ImageTranscodeRequest) async throws -> ImageTranscodeResult {
        let hasPath = request.path?.isEmpty == false
        let hasData = request.dataBase64?.isEmpty == false
        guard hasPath != hasData else {
            throw ImageTranscodeError.invalidRequest("supply exactly one of path or dataBase64")
        }

        // Reject an undecodable extension up front, so the caller gets
        // "this build has no HEIC decoder" rather than a codec's own error
        // about malformed data — the difference between a fixable answer and a
        // confusing one.
        if let path = request.path, hasPath {
            let ext = (path as NSString).pathExtension.lowercased()
            let decodable = await capabilities().decode
            if !ext.isEmpty, !decodable.isEmpty, !decodable.contains(ext) {
                throw ImageTranscodeError.unsupportedSource(
                    "\(ext) — this build decodes \(decodable.joined(separator: ", "))"
                )
            }
        }
        let encodable = await capabilities().encode
        guard encodable.contains(request.format.rawValue) else {
            throw ImageTranscodeError.unsupportedOutput(
                "\(request.format.rawValue) — this build encodes \(encodable.joined(separator: ", "))"
            )
        }

        let raw: RawImage
        do {
            raw = try await ImageCodec.decodeRGBFit(
                path: hasPath ? request.path : nil,
                dataBase64: hasData ? request.dataBase64 : nil,
                maxSide: request.maxSide ?? defaultMaxSide
            )
        } catch {
            throw ImageTranscodeError.unsupportedSource("\(error)")
        }

        let bytes: Data
        do {
            bytes = try await ImageCodec.encode(
                raw,
                format: request.format == .jpeg ? .jpeg : .png,
                quality: request.quality
            )
        } catch {
            throw ImageTranscodeError.failed("\(error)")
        }

        if let outputPath = request.outputPath, !outputPath.isEmpty {
            do {
                let url = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try bytes.write(to: url)
            } catch {
                throw ImageTranscodeError.failed("could not write \(outputPath): \(error)")
            }
            return ImageTranscodeResult(
                path: outputPath, dataBase64: nil,
                width: raw.width, height: raw.height, bytes: bytes.count
            )
        }
        return ImageTranscodeResult(
            path: nil, dataBase64: bytes.base64EncodedString(),
            width: raw.width, height: raw.height, bytes: bytes.count
        )
    }
}
