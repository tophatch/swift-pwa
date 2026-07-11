// Runs wherever a real ImageCodec exists (Apple + Linux/Windows via stb);
// Android has only the throwing fallback codec, so it's excluded.
#if canImport(CoreGraphics) || os(Linux) || os(Windows)
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAImageEdit
    import SwiftPWAImageIO // ImageCodec / RawImage (shared, package-internal)
    import Testing

    /// End-to-end inpaint against the **real** big-lama weights. Opt-in: skips
    /// (passes trivially) unless the model is present at `Vendor/lama/
    /// big-lama.onnx` — it's 209 MB, not committed, produced by
    /// `Scripts/vendor-lama.sh`. This is the on-hardware real-weights check
    /// that confirms the assumed `LaMaModelSpec` (tensor names, normalization,
    /// output range, fixed 512² input) actually matches the graph.
    @Suite("LaMaBackend real weights (opt-in, needs Vendor/lama/big-lama.onnx)")
    struct LaMaRealWeightsTests {
        private var modelPath: String {
            FileManager.default.currentDirectoryPath + "/Vendor/lama/big-lama.onnx"
        }

        @Test("inpaint erases the masked region and leaves unmasked pixels pristine")
        func inpaint() async throws {
            guard FileManager.default.fileExists(atPath: modelPath) else {
                print("SKIP: \(modelPath) absent — run Scripts/vendor-lama.sh to enable this test")
                return
            }

            // A 200×160 mid-gray image with a bright-red 48×48 block to erase.
            let width = 200, height = 160
            let blockX = 76, blockY = 56, blockW = 48, blockH = 48
            var pixels = [UInt8](repeating: 128, count: width * height * 3)
            for y in blockY ..< (blockY + blockH) {
                for x in blockX ..< (blockX + blockW) {
                    let i = (y * width + x) * 3
                    pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 0
                }
            }
            // Mask: white over the red block, black elsewhere.
            var maskPixels = [UInt8](repeating: 0, count: width * height * 3)
            for y in blockY ..< (blockY + blockH) {
                for x in blockX ..< (blockX + blockW) {
                    let i = (y * width + x) * 3
                    maskPixels[i] = 255; maskPixels[i + 1] = 255; maskPixels[i + 2] = 255
                }
            }

            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lama-verify-\(width)x\(height)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let imagePath = dir.appendingPathComponent("image.png").path
            let maskPath = dir.appendingPathComponent("mask.png").path
            try await ImageCodec.encodePNG(RawImage(pixels: pixels, width: width, height: height, channels: 3))
                .write(to: URL(fileURLWithPath: imagePath))
            try await ImageCodec.encodePNG(RawImage(pixels: maskPixels, width: width, height: height, channels: 3))
                .write(to: URL(fileURLWithPath: maskPath))

            let backend = LaMaBackend(modelPath: modelPath)
            let result = try await backend.generateImage(AIGenerateImageRequest(
                outputDirectory: dir.path, image: .file(imagePath), mask: .file(maskPath)
            ))
            #expect(result.backend == AIBackendID.lamaONNX)
            let outPath = try #require(result.images.first.flatMap(\.path))
            let out = try await ImageCodec.decodeRGB(path: outPath, dataBase64: nil, size: nil)

            // Same size as the source (composited back).
            #expect(out.width == width)
            #expect(out.height == height)

            // The block's center is no longer the pure red it started as — it
            // was inpainted toward the gray surround. Kept interpolation-robust
            // (Apple's high-quality resize vs desktop's bilinear fill the block
            // slightly differently): red reduced from 255, and green/blue are
            // no longer 0. Verified on both Apple/CPU and Linux/CPU.
            let center = ((blockY + blockH / 2) * width + (blockX + blockW / 2)) * 3
            let red = Int(out.pixels[center])
            let green = Int(out.pixels[center + 1])
            let blue = Int(out.pixels[center + 2])
            #expect(red < 240) // was 255 (pure red)
            #expect(green > 20 || blue > 20) // was (0, 0) — the fill added non-red content

            // An unmasked corner pixel is pristine (composite left it alone).
            let cornerPristine = out.pixels[0] == 128 && out.pixels[1] == 128 && out.pixels[2] == 128
            #expect(cornerPristine)
        }
    }
#endif
