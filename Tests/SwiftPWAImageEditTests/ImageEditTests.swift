import Foundation
import SwiftPWACore
@testable import SwiftPWAImageEdit
import Testing

@Suite("LaMaModelSpec working-size geometry")
struct LaMaModelSpecTests {
    @Test("working size caps the longest side and rounds to a multiple of 8")
    func working() {
        let spec = LaMaModelSpec(maxWorkingSide: 1024, sizeMultiple: 8)
        // No downscale: 500x300 rounds to nearest /8 (504x304... rounded).
        let small = spec.workingSize(forWidth: 500, height: 300)
        #expect(small.width % 8 == 0)
        #expect(small.height % 8 == 0)
        // Downscale: 4000x2000 → longest capped at 1024, still /8.
        let big = spec.workingSize(forWidth: 4000, height: 2000)
        #expect(max(big.width, big.height) <= 1024)
        #expect(big.width % 8 == 0 && big.height % 8 == 0)
    }
}

#if canImport(CoreGraphics) && canImport(ImageIO)
    @Suite("ImageCodec (Apple) round-trip")
    struct ImageCodecTests {
        @Test("RGB → PNG → RGB round-trips losslessly at the same size")
        func rgbRoundTrip() throws {
            // A 4x3 image with distinct per-pixel colors.
            let width = 4, height = 3
            var pixels = [UInt8](repeating: 0, count: width * height * 3)
            for i in 0 ..< (width * height) {
                pixels[i * 3] = UInt8((i * 20) % 256)
                pixels[i * 3 + 1] = UInt8((i * 37) % 256)
                pixels[i * 3 + 2] = UInt8((i * 53) % 256)
            }
            let source = RawImage(pixels: pixels, width: width, height: height, channels: 3)

            let png = try ImageCodec.encodePNG(source)
            let decoded = try ImageCodec.decodeRGB(
                path: nil, dataBase64: png.base64EncodedString(), size: nil
            )
            #expect(decoded.width == width)
            #expect(decoded.height == height)
            #expect(decoded.channels == 3)
            #expect(decoded.pixels == pixels) // PNG is lossless, opaque alpha
        }

        @Test("mask decodes to a single luminance channel")
        func maskGray() throws {
            // A 2x1 image: one white pixel, one black.
            let png = try ImageCodec.encodePNG(RawImage(
                pixels: [255, 255, 255, 0, 0, 0],
                width: 2,
                height: 1,
                channels: 3
            ))
            let gray = try ImageCodec.decodeGray(path: nil, dataBase64: png.base64EncodedString(), size: nil)
            #expect(gray.channels == 1)
            #expect(gray.pixels.count == 2)
            #expect(gray.pixels[0] >= 250) // white
            #expect(gray.pixels[1] <= 5) // black
        }

        @Test("decode resizes to the requested working size")
        func resize() throws {
            let png = try ImageCodec.encodePNG(RawImage(
                pixels: [UInt8](repeating: 128, count: 10 * 10 * 3), width: 10, height: 10, channels: 3
            ))
            let decoded = try ImageCodec.decodeRGB(
                path: nil, dataBase64: png.base64EncodedString(), size: (width: 8, height: 8)
            )
            #expect(decoded.width == 8 && decoded.height == 8)
        }
    }
#endif

@Suite("LaMaBackend contract")
struct LaMaBackendTests {
    @Test("reports imageEditing, not text/imageGeneration")
    func info() async {
        let caps = await LaMaBackend(modelPath: "/does/not/matter.onnx").info()
        #expect(caps.backend == AIBackendID.lamaONNX)
        #expect(caps.imageEditing == true)
        #expect(caps.imageGeneration == false)
        #expect(caps.vision == false)
    }

    @Test("text generation is unsupported (this backend edits images)")
    func textUnsupported() async {
        let backend = LaMaBackend(modelPath: "/does/not/matter.onnx")
        await #expect(throws: AIError.self) {
            _ = try await backend.generate(AIGenerateRequest(prompt: "hi"))
        }
    }

    @Test("generateImage without an input image fails before loading anything")
    func missingImage() async {
        let backend = LaMaBackend(modelPath: "/does/not/matter.onnx")
        await #expect(throws: AIError.self) {
            _ = try await backend.generateImage(AIGenerateImageRequest(prompt: "fill it"))
        }
    }

    @Test("generateImage with an image but no mask fails")
    func missingMask() async {
        let backend = LaMaBackend(modelPath: "/does/not/matter.onnx")
        await #expect(throws: AIError.self) {
            _ = try await backend.generateImage(AIGenerateImageRequest(image: .file("/x.png")))
        }
    }

    @Test("the fixed-path tier does not support ensureModel")
    func ensureModelUnsupported() async {
        let backend = LaMaBackend(modelPath: "/does/not/matter.onnx")
        await #expect(throws: (any Error).self) {
            for try await _ in backend.ensureModel(AIEnsureModelRequest()) {}
        }
    }
}
