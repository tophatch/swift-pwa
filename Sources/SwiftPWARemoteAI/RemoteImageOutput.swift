import Foundation
import SwiftPWACore

/// Shared output plumbing for remote providers: turn raw image bytes into an
/// `AIGeneratedImage`, honoring the request's `outputDirectory` (write a file
/// and return its `path` — bridge-efficient for multi-MB images) vs. inline
/// base64 when none was given. Mirrors the on-device backends and `fs`'s
/// path-first stance for large binaries.
enum RemoteImageOutput {
    static func make(
        bytes: Data,
        mimeType: String,
        seed: Int?,
        outputDirectory: String?,
        index: Int
    ) throws -> AIGeneratedImage {
        guard let directory = outputDirectory else {
            return AIGeneratedImage(dataBase64: bytes.base64EncodedString(), mimeType: mimeType, seed: seed)
        }
        let ext = fileExtension(for: mimeType)
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("image-\(index).\(ext)")
        try bytes.write(to: url)
        return AIGeneratedImage(path: url.path, mimeType: mimeType, seed: seed)
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/webp": "webp"
        default: "png"
        }
    }
}
