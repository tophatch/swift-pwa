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
    import SwiftPWAImageIO // ImageCodec / RawImage (shared image decode/encode)
    import SwiftPWAModelStore
    import SwiftPWAONNX
    #if os(Android)
        import SwiftPWAAndroid // AndroidFileDownload — model download routes through Kotlin's HTTP stack
    #endif

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

        /// Release the cached inference session (dropping the `OrtModelSession`
        /// frees the ONNX Runtime session via its `deinit`); the next edit
        /// reloads lazily. Lets a host — or `MultiModelImageBackend` on a switch
        /// — free the model's memory.
        public func unload() async {
            session = nil
            activeProvider = nil
        }

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
                imageEditing: true,
                provider: activeProvider?.rawValue
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

            let output = try await runInpaint(image: image, mask: mask)
            let png = try await mapCodec { try await ImageCodec.encodePNG(output) }

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
                        #if os(Android)
                            // Swift's URLSession (libcurl + BoringSSL) has no
                            // injectable CA trust store on Android, so HTTPS
                            // fails ("unable to get local issuer certificate");
                            // download through Android's own HTTP stack via the
                            // Kotlin `net.downloadFile` RPC (system TLS,
                            // checksum-verified, cache-reusing) — same as
                            // MobileSAMBackend. `AndroidFileDownload` forwards
                            // byte-level progress off a host-event channel.
                            continuation.yield(.progress(bytesDone: 0, totalBytes: source.sizeBytes))
                            _ = try await AndroidFileDownload.download(
                                url: source.url.absoluteString,
                                destPath: downloader.localURL(for: spec).path,
                                sha256: source.sha256
                            ) { bytesDone, total in
                                continuation.yield(.progress(
                                    bytesDone: bytesDone,
                                    totalBytes: total ?? source.sizeBytes
                                ))
                            }
                        #else
                            _ = try await downloader.ensure(spec) { bytesDone, total in
                                continuation.yield(.progress(
                                    bytesDone: bytesDone,
                                    totalBytes: total ?? source.sizeBytes
                                ))
                            }
                        #endif
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

        /// The full inpaint. Decodes the image + mask at the capped working
        /// resolution, then — to give the model detail on a large photo with a
        /// small edit — crops a padded, squared region **around the mask**,
        /// resizes just that crop to the model's fixed square, runs the graph,
        /// resizes the result back to the crop, and composites it into the base
        /// **only within the masked region** (unmasked pixels stay pristine).
        /// Returns the base at working resolution (≤ `spec.maxWorkingSide`).
        private func runInpaint(image: AIImage, mask: AIImage) async throws -> RawImage {
            let base = try await mapCodec {
                try await ImageCodec.decodeRGBFit(
                    path: image.path, dataBase64: image.dataBase64, maxSide: spec.maxWorkingSide
                )
            }
            let width = base.width, height = base.height
            let baseMask = try await mapCodec {
                try await ImageCodec.decodeGray(path: mask.path, dataBase64: mask.dataBase64, size: (width, height))
            }

            // The region to actually run through the model. No masked pixels →
            // nothing to inpaint, return the image untouched.
            guard let bbox = maskBounds(baseMask, threshold: spec.maskThreshold) else { return base }
            let rect: (x: Int, y: Int, w: Int, h: Int) = spec.cropToMask
                ? cropRect(bbox: bbox, imageW: width, imageH: height, padding: spec.cropPadding)
                : (x: 0, y: 0, w: width, h: height)

            let cropImg = cropRawImage(base, rect)
            let cropMask = cropRawImage(baseMask, rect)

            // Model inputs at the fixed square (e.g. 512×512), from the crop.
            let n = spec.inputSize
            let modelImg = resample(cropImg, toWidth: n, height: n)
            let modelMask = resample(cropMask, toWidth: n, height: n)
            let squarePixels = n * n

            // Image → NCHW float32 (channel-planar), optionally /255.
            var imageValues = [Float](repeating: 0, count: 3 * squarePixels)
            let imageScale: Float = spec.normalizeImageTo01 ? 255 : 1
            for pixel in 0 ..< squarePixels {
                for channel in 0 ..< 3 {
                    imageValues[channel * squarePixels + pixel] = Float(modelImg.pixels[pixel * 3 + channel]) /
                        imageScale
                }
            }
            // Mask → NCHW float32 [1,1,n,n], binarized (white = fill).
            var maskValues = [Float](repeating: 0, count: squarePixels)
            for pixel in 0 ..< squarePixels {
                maskValues[pixel] = modelMask.pixels[pixel] >= spec.maskThreshold ? 1 : 0
            }

            let session = try loadedSession()
            let outputs = try mapOrt {
                try session.run(
                    inputs: [
                        spec.imageInputName: .init(values: imageValues, shape: [1, 3, Int64(n), Int64(n)]),
                        spec.maskInputName: .init(values: maskValues, shape: [1, 1, Int64(n), Int64(n)])
                    ],
                    outputNames: [spec.outputName]
                )
            }
            guard let out = outputs[spec.outputName], out.shape.count == 4 else {
                throw AIError.generationFailed("LaMa graph produced no 4-D \"\(spec.outputName)\" output")
            }
            let outH = Int(out.shape[2]), outW = Int(out.shape[3])
            let outPixels = outW * outH

            // Output NCHW [1,3,outH,outW] → packed RGB bytes.
            let outScale: Float = spec.outputIs0To255 ? 1 : 255
            var raw = [UInt8](repeating: 0, count: 3 * outPixels)
            for pixel in 0 ..< outPixels {
                for channel in 0 ..< 3 {
                    let value = out.values[channel * outPixels + pixel] * outScale
                    raw[pixel * 3 + channel] = UInt8(max(0, min(255, value.rounded())))
                }
            }

            // Fill → crop size, composited into the base within the crop, masked.
            let filledCrop = resample(
                RawImage(pixels: raw, width: outW, height: outH, channels: 3),
                toWidth: rect.w, height: rect.h
            )
            var composited = base.pixels
            for j in 0 ..< rect.h {
                for i in 0 ..< rect.w where cropMask.pixels[j * rect.w + i] >= spec.maskThreshold {
                    let baseIdx = ((rect.y + j) * width + (rect.x + i)) * 3
                    let cropIdx = (j * rect.w + i) * 3
                    composited[baseIdx] = filledCrop.pixels[cropIdx]
                    composited[baseIdx + 1] = filledCrop.pixels[cropIdx + 1]
                    composited[baseIdx + 2] = filledCrop.pixels[cropIdx + 2]
                }
            }
            return RawImage(pixels: composited, width: width, height: height, channels: 3)
        }

        // MARK: - Crop / resample helpers (pure Swift, no codec round-trip)

        /// Inclusive bounding box of pixels at/above `threshold`, or nil if none.
        private func maskBounds(_ mask: RawImage, threshold: UInt8) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
            var x0 = mask.width, y0 = mask.height, x1 = -1, y1 = -1
            for y in 0 ..< mask.height {
                let row = y * mask.width
                for x in 0 ..< mask.width where mask.pixels[row + x] >= threshold {
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                    if y < y0 { y0 = y }
                    if y > y1 { y1 = y }
                }
            }
            return x1 >= x0 && y1 >= y0 ? (x0, y0, x1, y1) : nil
        }

        /// A padded, square crop rect centered on `bbox`, clamped to the image.
        /// Falls back to the clamped padded (non-square) box only when the mask
        /// is larger than a square that fits the image.
        private func cropRect(
            bbox: (x0: Int, y0: Int, x1: Int, y1: Int), imageW: Int, imageH: Int, padding: Double
        ) -> (x: Int, y: Int, w: Int, h: Int) {
            let bw = bbox.x1 - bbox.x0 + 1, bh = bbox.y1 - bbox.y0 + 1
            let pad = Int((Double(max(bw, bh)) * max(0, padding)).rounded())
            let side = min(max(bw, bh) + 2 * pad, min(imageW, imageH))
            if side < bw || side < bh {
                let px0 = max(0, bbox.x0 - pad), py0 = max(0, bbox.y0 - pad)
                let px1 = min(imageW - 1, bbox.x1 + pad), py1 = min(imageH - 1, bbox.y1 + pad)
                return (px0, py0, px1 - px0 + 1, py1 - py0 + 1)
            }
            let cx = (bbox.x0 + bbox.x1) / 2, cy = (bbox.y0 + bbox.y1) / 2
            let x = max(0, min(imageW - side, cx - side / 2))
            let y = max(0, min(imageH - side, cy - side / 2))
            return (x, y, side, side)
        }

        /// Copy a sub-rect out of `img` into a tightly-packed `RawImage`.
        private func cropRawImage(_ img: RawImage, _ rect: (x: Int, y: Int, w: Int, h: Int)) -> RawImage {
            let c = img.channels
            var out = [UInt8](repeating: 0, count: rect.w * rect.h * c)
            for j in 0 ..< rect.h {
                let srcRow = ((rect.y + j) * img.width + rect.x) * c
                let dstRow = (j * rect.w) * c
                for i in 0 ..< (rect.w * c) { out[dstRow + i] = img.pixels[srcRow + i] }
            }
            return RawImage(pixels: out, width: rect.w, height: rect.h, channels: c)
        }

        /// Channel-agnostic bilinear resample (pixel-center mapping).
        private func resample(_ img: RawImage, toWidth dstW: Int, height dstH: Int) -> RawImage {
            if img.width == dstW, img.height == dstH { return img }
            let c = img.channels, srcW = img.width, srcH = img.height
            var out = [UInt8](repeating: 0, count: dstW * dstH * c)
            let sxScale = Double(srcW) / Double(dstW), syScale = Double(srcH) / Double(dstH)
            for dy in 0 ..< dstH {
                let syf = (Double(dy) + 0.5) * syScale - 0.5
                let sy0 = max(0, min(srcH - 1, Int(syf.rounded(.down)))), sy1 = min(srcH - 1, sy0 + 1)
                let wy = max(0.0, min(1.0, syf - Double(sy0)))
                for dx in 0 ..< dstW {
                    let sxf = (Double(dx) + 0.5) * sxScale - 0.5
                    let sx0 = max(0, min(srcW - 1, Int(sxf.rounded(.down)))), sx1 = min(srcW - 1, sx0 + 1)
                    let wx = max(0.0, min(1.0, sxf - Double(sx0)))
                    let r0 = sy0 * srcW, r1 = sy1 * srcW, dst = (dy * dstW + dx) * c
                    for ch in 0 ..< c {
                        let p00 = Double(img.pixels[(r0 + sx0) * c + ch]), p01 = Double(img.pixels[(r0 + sx1) * c + ch])
                        let p10 = Double(img.pixels[(r1 + sx0) * c + ch]), p11 = Double(img.pixels[(r1 + sx1) * c + ch])
                        let top = p00 + (p01 - p00) * wx, bot = p10 + (p11 - p10) * wx
                        out[dst + ch] = UInt8(max(0, min(255, (top + (bot - top) * wy).rounded())))
                    }
                }
            }
            return RawImage(pixels: out, width: dstW, height: dstH, channels: c)
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

        private func mapCodec<T>(_ body: () async throws -> T) async throws -> T {
            do { return try await body() } catch let error as ImageCodecError {
                throw AIError.generationFailed("\(error)")
            }
        }
    }
#endif
