// Gated exactly like SwiftPWASegmentation's MobileSAMBackend: the body
// references the shared ONNX Runtime wrapper types (OrtRuntime /
// OrtModelSession from SwiftPWAONNX), which themselves only exist on a
// destination where an ONNX Runtime is linked. On any other destination the
// whole backend compiles to an empty stub; ImageCodec / LaMaModelSpec stay
// available regardless (they need no runtime).
// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)
    import Foundation
    import SwiftPWACore
    import SwiftPWAModelStore
    import SwiftPWAONNX

    /// An `AIBackend` that inpaints via a LaMa-family ONNX model — the first
    /// consumer of the generalized `ai.generateImage` **editing** path (an
    /// `image` + `mask`, no prompt; see
    /// `docs/proposals/image-generation-editing.md`). It reports
    /// `imageEditing: true` / `imageGeneration: false`: it fills the masked
    /// region and does not do text→image, so `ai.generate` (text) throws
    /// `.unsupportedPlatform`.
    ///
    /// Reuses the shared `SwiftPWAONNX` tier — the same `OrtModelSession`
    /// MobileSAM runs on, including the desktop CUDA/DirectML GPU providers
    /// (`ai.onnx_gpu`) with transparent CPU fallback. The graph contract +
    /// pre/post-processing live in `LaMaModelSpec` (configurable, defaulting to
    /// the big-lama fp32 export); image decode/encode lives in `ImageCodec`.
    ///
    /// It pairs with `ai.vision.*` segmentation: a SAM mask (decoded to a
    /// white-on-black PNG) is exactly the `mask` this consumes — "tap to erase".
    public actor LaMaBackend: AIBackend {
        private let modelPath: String
        private let spec: LaMaModelSpec
        /// Set only for the downloadable tier. `nil` for the fixed-path
        /// (bring-your-own / bundled weights) tier, whose `ensureModel` throws.
        private let download: (downloader: ModelDownloader, source: LaMaModelSource)?

        /// Loaded lazily on first use and reused (loading the graph is the
        /// expensive step; inference is one forward pass).
        private var session: OrtModelSession?
        private var activeProvider: OrtExecutionProvider?

        /// Back a LaMa ONNX graph already present on disk (bundled, or fetched
        /// by the caller). `ensureModel` throws `.unsupportedPlatform` — there
        /// is nothing to download.
        public init(modelPath: String, spec: LaMaModelSpec = .bigLama) {
            self.modelPath = modelPath
            self.spec = spec
            download = nil
        }

        /// Back a downloadable LaMa model: `ai.ensureModel` fetches `source`
        /// into `cacheDirectory` (resumable, checksum-pinned), and
        /// `ai.generateImage` loads it from there once present. Mirrors
        /// `MobileSAMBackend(cacheDirectory:source:)`.
        public init(cacheDirectory: URL, source: LaMaModelSource = .bigLama, spec: LaMaModelSpec = .bigLama) {
            let downloader = ModelDownloader(directory: cacheDirectory)
            modelPath = downloader.localURL(for: ModelSpec(
                url: source.url, sha256: source.sha256, fileName: source.fileName
            )).path
            self.spec = spec
            download = (downloader, source)
        }

        // MARK: AIBackend

        public func info() async -> AICapabilities {
            guard OrtRuntime.shared != nil else { return .none }
            return AICapabilities(
                available: true,
                backend: AIBackendID.lamaONNX,
                model: spec == .bigLama ? "big-lama" : "lama",
                imageEditing: true
            )
        }

        /// Text generation is not this backend's job — it edits images.
        public func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
            throw AIError
                .unsupportedPlatform("the LaMa backend edits images (ai.generateImage), it does not generate text")
        }

        public func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
            guard OrtRuntime.shared != nil else {
                throw AIError.unavailable("no usable ONNX Runtime is linked")
            }
            guard let image = request.image else {
                throw AIError.generationFailed("this backend inpaints — supply an input `image` (and a `mask`)")
            }
            guard let mask = request.mask else {
                throw AIError.generationFailed("this backend inpaints — supply a `mask` marking the region to fill")
            }

            let output = try runInpaint(image: image, mask: mask)
            let png = try mapCodec { try ImageCodec.encodePNG(output) }

            let generated: AIGeneratedImage
            if let directory = request.outputDirectory {
                let path = try writeImage(png, toDirectory: directory, seed: request.seed)
                generated = AIGeneratedImage(path: path, mimeType: "image/png", seed: request.seed)
            } else {
                generated = AIGeneratedImage(
                    dataBase64: png.base64EncodedString(), mimeType: "image/png", seed: request.seed
                )
            }
            return AIGenerateImageResult(images: [generated], backend: AIBackendID.lamaONNX)
        }

        public nonisolated func ensureModel(_: AIEnsureModelRequest)
            -> AsyncThrowingStream<AIDownloadEvent, any Error>
        {
            guard let download else {
                return AsyncThrowingStream {
                    $0
                        .finish(throwing: AIError
                            .unsupportedPlatform("this backend was constructed with a fixed model path"))
                }
            }
            let (downloader, source) = download
            let spec = ModelSpec(url: source.url, sha256: source.sha256, fileName: source.fileName)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        _ = try await downloader.ensure(spec) { bytesDone, total in
                            continuation.yield(.progress(bytesDone: bytesDone, totalBytes: total ?? source.sizeBytes))
                        }
                        continuation.yield(.done)
                        continuation.finish()
                    } catch let error as AIError {
                        continuation.finish(throwing: AIError.modelDownloadFailed(error.bridgeError.message))
                    } catch {
                        continuation.finish(throwing: AIError.modelDownloadFailed("\(error)"))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // MARK: - Inference

        /// Decode → tensors → run the graph → decode the output to an RGB
        /// `RawImage` at the working resolution.
        private func runInpaint(image: AIImage, mask: AIImage) throws -> RawImage {
            // Probe the source dimensions, then pick a working size (capped,
            // multiple-of-8) and decode image + mask at it.
            let probe = try mapCodec { try ImageCodec.decodeRGB(
                path: image.path,
                dataBase64: image.dataBase64,
                size: nil
            ) }
            let working = spec.workingSize(forWidth: probe.width, height: probe.height)
            let rgb = probe.width == working.width && probe.height == working.height
                ? probe
                :
                try mapCodec {
                    try ImageCodec.decodeRGB(path: image.path, dataBase64: image.dataBase64, size: working)
                }
            let gray = try mapCodec {
                try ImageCodec.decodeGray(path: mask.path, dataBase64: mask.dataBase64, size: working)
            }

            let width = working.width, height = working.height
            let pixelCount = width * height

            // Image → NCHW float32 (channel-planar), optionally /255.
            var imageValues = [Float](repeating: 0, count: 3 * pixelCount)
            let imageScale: Float = spec.normalizeImageTo01 ? 255 : 1
            for pixel in 0 ..< pixelCount {
                for channel in 0 ..< 3 {
                    imageValues[channel * pixelCount + pixel] = Float(rgb.pixels[pixel * 3 + channel]) / imageScale
                }
            }
            // Mask → NCHW float32 [1,1,H,W], binarized (white = fill).
            var maskValues = [Float](repeating: 0, count: pixelCount)
            for pixel in 0 ..< pixelCount {
                maskValues[pixel] = gray.pixels[pixel] >= spec.maskThreshold ? 1 : 0
            }

            let session = try loadedSession()
            let outputs = try mapOrt {
                try session.run(
                    inputs: [
                        spec.imageInputName: .init(values: imageValues, shape: [1, 3, Int64(height), Int64(width)]),
                        spec.maskInputName: .init(values: maskValues, shape: [1, 1, Int64(height), Int64(width)])
                    ],
                    outputNames: [spec.outputName]
                )
            }
            guard let out = outputs[spec.outputName] else {
                throw AIError.generationFailed("LaMa graph produced no \"\(spec.outputName)\" output")
            }

            // Output NCHW [1,3,H,W] → packed RGB bytes.
            let outScale: Float = spec.outputIs0To255 ? 1 : 255
            var pixels = [UInt8](repeating: 0, count: 3 * pixelCount)
            for pixel in 0 ..< pixelCount {
                for channel in 0 ..< 3 {
                    let value = out.values[channel * pixelCount + pixel] * outScale
                    pixels[pixel * 3 + channel] = UInt8(max(0, min(255, value.rounded())))
                }
            }
            return RawImage(pixels: pixels, width: width, height: height, channels: 3)
        }

        private func loadedSession() throws -> OrtModelSession {
            if let session { return session }
            guard let runtime = OrtRuntime.shared else {
                throw AIError.unavailable("no usable ONNX Runtime is linked")
            }
            let loaded = try mapOrt { try OrtModelSession(modelPath: modelPath, runtime: runtime) }
            session = loaded
            activeProvider = loaded.provider
            return loaded
        }

        private func writeImage(_ png: Data, toDirectory directory: String, seed: Int?) throws -> String {
            let dir = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Deterministic-ish, collision-resistant name without needing a
            // clock/RNG (both unavailable in some sandboxes): seed + content hash.
            let stem = "inpaint-\(seed.map(String.init) ?? "n")-\(png.count)"
            let url = dir.appendingPathComponent("\(stem).png")
            try png.write(to: url)
            return url.path
        }

        private func mapOrt<T>(_ body: () throws -> T) throws -> T {
            do { return try body() } catch let error as OrtError {
                throw AIError.generationFailed("\(error)")
            }
        }

        private func mapCodec<T>(_ body: () throws -> T) throws -> T {
            do { return try body() } catch let error as ImageCodecError {
                throw AIError.generationFailed("\(error)")
            }
        }
    }
#endif
