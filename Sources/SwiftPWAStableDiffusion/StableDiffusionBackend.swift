// Gated exactly like SwiftPWAImageEdit's LaMaBackend / SwiftPWASegmentation's
// MobileSAMBackend: the body references the shared ONNX Runtime wrapper types
// (OrtRuntime / OrtModelSession from SwiftPWAONNX), which only exist where an
// ONNX Runtime is linked. On any other destination the whole backend compiles
// to an empty stub; the CLIPTokenizer / StableDiffusionModelSpec /
// StableDiffusionSampling pieces stay available regardless (they need no
// runtime).
// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)
    import Foundation
    import SwiftPWACore
    import SwiftPWAImageIO // ImageCodec / RawImage (shared image decode/encode)
    import SwiftPWAModelStore
    import SwiftPWAONNX
    #if os(Android)
        import SwiftPWAAndroid // AndroidRPC — model download routes through Kotlin's HTTP stack
    #endif

    /// An `AIBackend` that generates images from a text prompt via a
    /// Stable-Diffusion ONNX pipeline (text encoder + UNet + VAE decoder +
    /// CLIP tokenizer + scheduler) on the shared `SwiftPWAONNX` tier — the
    /// text→image consumer of `ai.generateImage` (a `prompt`, no input
    /// `image`; see `docs/proposals/stable-diffusion.md`). It reports
    /// `imageGeneration: true`.
    ///
    /// **Status.** `ai.generateImage` works end-to-end (prompt → PNG): the
    /// pipeline (`runTxt2Img`: tokenize → text-encode → Euler denoise →
    /// VAE-decode) is **verified against a diffusers SD-Turbo reference** —
    /// every stage matches to within float noise (text embedding / latent /
    /// image correlation > 0.9999999; the decoded image is pixel-identical to
    /// diffusers). The graph contract (tensor names, `input_ids` int64,
    /// float-scalar `timestep`, 1024-dim embedding, `epsilon`/`trailing`
    /// scheduler, VAE scaling) was confirmed against the real export; see
    /// `docs/proposals/stable-diffusion.md`. Image encode/decode is the shared
    /// `SwiftPWAImageIO` `ImageCodec`. The remaining follow-up is the
    /// **LCM** (OpenRAIL-M) commercial default + `sd-vendor` packaging.
    public actor StableDiffusionBackend: AIBackend {
        private let textEncoderPath: String
        private let unetPath: String
        private let vaeDecoderPath: String
        private let tokenizerVocabPath: String
        private let tokenizerMergesPath: String
        private let spec: StableDiffusionModelSpec
        /// Set only for the downloadable tier — drives `ensureModel`. `nil`
        /// for the fixed-path tier, whose `ensureModel` throws. `files` is in
        /// download order (see `StableDiffusionModelSource.files`).
        private let download: (downloader: ModelDownloader, files: [StableDiffusionModelSource.File])?

        /// Loaded lazily on first use and reused (graph parse is the
        /// expensive step). Kept for the real-weights pass.
        private var textEncoder: OrtModelSession?
        private var unet: OrtModelSession?
        private var vaeDecoder: OrtModelSession?
        private var tokenizer: CLIPTokenizer?

        /// Back a pipeline already present on disk (bundled, or fetched by
        /// the caller). `ensureModel` throws `.unsupportedPlatform`.
        public init(
            textEncoderPath: String,
            unetPath: String,
            vaeDecoderPath: String,
            tokenizerVocabPath: String,
            tokenizerMergesPath: String,
            spec: StableDiffusionModelSpec = .sdTurbo
        ) {
            self.textEncoderPath = textEncoderPath
            self.unetPath = unetPath
            self.vaeDecoderPath = vaeDecoderPath
            self.tokenizerVocabPath = tokenizerVocabPath
            self.tokenizerMergesPath = tokenizerMergesPath
            self.spec = spec
            download = nil
        }

        /// Back a downloadable pipeline: `ai.ensureModel` fetches the five
        /// files described by `source` into `cacheDirectory` (resumable,
        /// checksum-pinned), and generation loads them from there. Mirrors
        /// `MobileSAMBackend(cacheDirectory:source:)`.
        public init(
            cacheDirectory: URL,
            source: StableDiffusionModelSource = .sdTurbo,
            spec: StableDiffusionModelSpec = .sdTurbo
        ) {
            let downloader = ModelDownloader(directory: cacheDirectory)
            func path(_ file: StableDiffusionModelSource.File) -> String {
                downloader.localURL(for: ModelSpec(url: file.url, sha256: file.sha256, fileName: file.fileName)).path
            }
            textEncoderPath = path(source.textEncoder)
            unetPath = path(source.unet)
            vaeDecoderPath = path(source.vaeDecoder)
            tokenizerVocabPath = path(source.tokenizerVocab)
            tokenizerMergesPath = path(source.tokenizerMerges)
            self.spec = spec
            download = (downloader, source.files)
        }

        // MARK: AIBackend

        public func info() async -> AICapabilities {
            guard OrtRuntime.shared != nil else { return .none }
            return AICapabilities(
                available: true,
                backend: AIBackendID.stableDiffusionONNX,
                model: spec == .sdTurbo ? "sd-turbo" : "stable-diffusion",
                streaming: true,
                imageGeneration: true
            )
        }

        /// Text generation is not this backend's job — it generates images.
        public func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
            throw AIError.unsupportedPlatform(
                "the Stable Diffusion backend generates images (ai.generateImage), it does not generate text"
            )
        }

        public func generateImage(_ request: AIGenerateImageRequest) async throws -> AIGenerateImageResult {
            let images = try await generateAll(request)
            return AIGenerateImageResult(images: images, backend: AIBackendID.stableDiffusionONNX)
        }

        public nonisolated func generateImageStream(_ request: AIGenerateImageRequest)
            -> AsyncThrowingStream<AIImageEvent, any Error>
        {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let images = try await generateAll(request) { step, total in
                            continuation.yield(.progress(step: step, totalSteps: total))
                        }
                        continuation.yield(.done(images: images, backend: AIBackendID.stableDiffusionONNX))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Generate `request.count` (default 1) images, encoding each decoded
        /// result to PNG. `onStep` reports cumulative denoising progress across
        /// all images (`total = count × steps`) for the streaming path.
        private func generateAll(
            _ request: AIGenerateImageRequest,
            onStep: (@Sendable (Int, Int) -> Void)? = nil
        ) async throws -> [AIGeneratedImage] {
            let count = max(1, request.count ?? 1)
            let steps = max(1, request.steps ?? spec.defaultSteps)
            let total = count * steps
            var images: [AIGeneratedImage] = []
            for index in 0 ..< count {
                var perImage = request
                perImage.seed = (request.seed ?? 0) + index
                let base = index * steps
                let out = try await runTxt2Img(perImage) { step, _ in onStep?(base + step, total) }
                try await images.append(encode(out.image, outputDirectory: request.outputDirectory, seed: out.seedUsed))
            }
            return images
        }

        /// Encode a VAE output tensor (`[1,3,H,W]` in `[-1,1]`) to PNG and wrap
        /// it as an `AIGeneratedImage` — a written file `path` when the request
        /// supplied an `outputDirectory`, else inline base64.
        private func encode(
            _ image: OrtModelSession.Tensor, outputDirectory: String?, seed: Int
        ) async throws -> AIGeneratedImage {
            let raw = Self.rawImage(from: image)
            let png = try await mapCodec { try await ImageCodec.encodePNG(raw) }
            if let outputDirectory {
                let path = try writeImage(png, toDirectory: outputDirectory, seed: seed)
                return AIGeneratedImage(path: path, mimeType: "image/png", seed: seed)
            }
            return AIGeneratedImage(dataBase64: png.base64EncodedString(), mimeType: "image/png", seed: seed)
        }

        /// `[1,3,H,W]` float32 `[-1,1]` (channel-planar) → tightly-packed RGB
        /// bytes `[0,255]`, the `RawImage` `ImageCodec.encodePNG` consumes.
        private static func rawImage(from image: OrtModelSession.Tensor) -> RawImage {
            let height = Int(image.shape[2]), width = Int(image.shape[3])
            let plane = height * width
            var pixels = [UInt8](repeating: 0, count: plane * 3)
            for pixel in 0 ..< plane {
                for channel in 0 ..< 3 {
                    let value = (image.values[channel * plane + pixel] / 2 + 0.5) * 255
                    pixels[pixel * 3 + channel] = UInt8(max(0, min(255, value.rounded())))
                }
            }
            return RawImage(pixels: pixels, width: width, height: height, channels: 3)
        }

        private func writeImage(_ png: Data, toDirectory directory: String, seed: Int) throws -> String {
            let dir = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Deterministic, collision-resistant name without a clock/RNG: seed
            // + content size (mirrors LaMaBackend.writeImage).
            let url = dir.appendingPathComponent("sd-\(seed)-\(png.count).png")
            try png.write(to: url)
            return url.path
        }

        private func mapCodec<T>(_ body: () async throws -> T) async throws -> T {
            do { return try await body() } catch let error as ImageCodecError {
                throw AIError.generationFailed("\(error)")
            }
        }

        // MARK: - txt2img pipeline

        /// Every tensor a txt2img run produces, for the result path and for the
        /// stage-by-stage diffusers-reference verification.
        struct Txt2ImgIntermediates {
            var inputIds: [Int32]
            var textEmbedding: OrtModelSession.Tensor
            var latent: [Float] // final [1, C, h/8, w/8]
            var latentShape: [Int64]
            var image: OrtModelSession.Tensor // VAE output [1, 3, H, W] in [-1, 1]
            var seedUsed: Int
        }

        /// The text→image pipeline: tokenize the prompt, text-encode it, seed
        /// (or inject) the initial latent, run the Euler denoising loop against
        /// the UNet, then VAE-decode. `injectedLatent` (raw standard-normal
        /// noise, pre-`initNoiseSigma`) overrides the seeded latent — used by
        /// the verification harness to compare against the diffusers reference
        /// independent of RNG. Returns every intermediate.
        func runTxt2Img(
            _ request: AIGenerateImageRequest,
            injectedLatent: [Float]? = nil,
            onStep: (@Sendable (Int, Int) -> Void)? = nil
        ) async throws -> Txt2ImgIntermediates {
            guard let runtime = OrtRuntime.shared else {
                throw AIError.unavailable("no usable ONNX Runtime is linked")
            }
            guard let prompt = request.prompt, !prompt.isEmpty else {
                throw AIError.generationFailed("this backend generates from a text `prompt` — supply one")
            }
            let width = request.width ?? spec.defaultWidth
            let height = request.height ?? spec.defaultHeight
            let steps = request.steps ?? spec.defaultSteps
            let seed = request.seed ?? 0
            let (latentW, latentH) = spec.latentSize(forWidth: width, height: height)
            let latentCount = spec.latentChannels * latentH * latentW

            // 1. Tokenize → input_ids (int64 or int32 per the export).
            let tokenizer = try loadedTokenizer()
            let ids = tokenizer.encode(prompt)
            let seqLen = Int64(ids.count)
            let idsInput: OrtModelSession.OrtInput = spec.inputIdsInt64
                ? .int64(ids.map(Int64.init), shape: [1, seqLen])
                : .int32(ids, shape: [1, seqLen])

            // 2. Text-encode → cross-attention context.
            let te = try loadedTextEncoder(runtime)
            let teOut = try mapOrt {
                try te.run(inputs: [spec.inputIdsName: idsInput], outputNames: [spec.textEmbeddingName])
            }
            guard let embedding = teOut[spec.textEmbeddingName] else {
                throw AIError.generationFailed("text encoder produced no \"\(spec.textEmbeddingName)\" output")
            }

            // 3. Initial latent: seeded (or injected) Gaussian × initNoiseSigma.
            var scheduler = EulerDiscreteScheduler(config: spec.scheduler)
            scheduler.setTimesteps(steps)
            let noise = injectedLatent
                ?? StableDiffusionSampling.seededLatents(count: latentCount, seed: UInt64(bitPattern: Int64(seed)))
            guard noise.count == latentCount else {
                throw AIError.generationFailed("latent noise count \(noise.count) != expected \(latentCount)")
            }
            let sigma0 = Float(scheduler.initNoiseSigma)
            var latent = noise.map { $0 * sigma0 }
            let latentShape: [Int64] = [1, Int64(spec.latentChannels), Int64(latentH), Int64(latentW)]

            // 4. Denoise loop (guidance-free: one UNet pass per step).
            let unet = try loadedUnet(runtime)
            for (index, timestep) in scheduler.timesteps.enumerated() {
                let scaled = scheduler.scaleModelInput(latent, stepIndex: index)
                let timestepInput: OrtModelSession.OrtInput = spec.timestepIsFloatScalar
                    ? .float([Float(timestep)], shape: [])
                    : .int64([Int64(timestep)], shape: [])
                let unetOut = try mapOrt {
                    try unet.run(
                        inputs: [
                            spec.unetSampleName: .float(scaled, shape: latentShape),
                            spec.unetTimestepName: timestepInput,
                            spec.unetEncoderHiddenStatesName: .float(embedding.values, shape: embedding.shape)
                        ],
                        outputNames: [spec.unetOutputName]
                    )
                }
                guard let noisePred = unetOut[spec.unetOutputName] else {
                    throw AIError.generationFailed("UNet produced no \"\(spec.unetOutputName)\" output")
                }
                latent = try scheduler.step(modelOutput: noisePred.values, stepIndex: index, sample: latent)
                onStep?(index + 1, scheduler.timesteps.count)
            }

            // 5. VAE-decode (latent / scaling_factor → image in [-1, 1]).
            let vae = try loadedVAEDecoder(runtime)
            let vaeScale = Float(spec.vaeScalingFactor)
            let scaledLatent = latent.map { $0 / vaeScale }
            let vaeOut = try mapOrt {
                try vae.run(
                    inputs: [spec.vaeLatentName: .float(scaledLatent, shape: latentShape)],
                    outputNames: [spec.vaeImageName]
                )
            }
            guard let image = vaeOut[spec.vaeImageName] else {
                throw AIError.generationFailed("VAE decoder produced no \"\(spec.vaeImageName)\" output")
            }

            return Txt2ImgIntermediates(
                inputIds: ids, textEmbedding: embedding,
                latent: latent, latentShape: latentShape, image: image, seedUsed: seed
            )
        }

        public nonisolated func ensureModel(_: AIEnsureModelRequest)
            -> AsyncThrowingStream<AIDownloadEvent, any Error>
        {
            guard let download else {
                return AsyncThrowingStream {
                    $0.finish(throwing: AIError
                        .unsupportedPlatform("this backend was constructed with fixed model paths"))
                }
            }
            let (downloader, files) = download
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // One aggregate progress bar across all five files.
                        let grandTotal = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
                        var completed: Int64 = 0
                        for file in files {
                            let spec = ModelSpec(url: file.url, sha256: file.sha256, fileName: file.fileName)
                            let base = completed
                            #if os(Android)
                                // Swift's URLSession has no injectable CA store
                                // on Android; download through Android's HTTP
                                // stack via the Kotlin `net.downloadFile` RPC
                                // (system TLS, checksum-verified) — same as
                                // MobileSAM/LaMa. Progress is per-file.
                                continuation.yield(.progress(bytesDone: base, totalBytes: grandTotal))
                                _ = try await AndroidRPC.call(
                                    "net.downloadFile",
                                    DownloadFileArgs(
                                        url: file.url.absoluteString,
                                        destPath: downloader.localURL(for: spec).path,
                                        sha256: file.sha256
                                    ),
                                    as: DownloadFileResult.self
                                )
                            #else
                                _ = try await downloader.ensure(spec) { bytesDone, _ in
                                    continuation.yield(.progress(bytesDone: base + bytesDone, totalBytes: grandTotal))
                                }
                            #endif
                            completed += file.sizeBytes
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

        // MARK: - Loading

        private func loadedTextEncoder(_ runtime: OrtRuntime) throws -> OrtModelSession {
            if let textEncoder { return textEncoder }
            let session = try mapOrt { try OrtModelSession(modelPath: textEncoderPath, runtime: runtime) }
            textEncoder = session
            return session
        }

        private func loadedUnet(_ runtime: OrtRuntime) throws -> OrtModelSession {
            if let unet { return unet }
            let session = try mapOrt { try OrtModelSession(modelPath: unetPath, runtime: runtime) }
            unet = session
            return session
        }

        private func loadedVAEDecoder(_ runtime: OrtRuntime) throws -> OrtModelSession {
            if let vaeDecoder { return vaeDecoder }
            let session = try mapOrt { try OrtModelSession(modelPath: vaeDecoderPath, runtime: runtime) }
            vaeDecoder = session
            return session
        }

        private func mapOrt<T>(_ body: () throws -> T) throws -> T {
            do { return try body() } catch let error as OrtError {
                throw AIError.generationFailed("\(error)")
            }
        }

        private func loadedTokenizer() throws -> CLIPTokenizer {
            if let tokenizer { return tokenizer }
            do {
                let loaded = try CLIPTokenizer(
                    vocabURL: URL(fileURLWithPath: tokenizerVocabPath),
                    mergesURL: URL(fileURLWithPath: tokenizerMergesPath),
                    bosToken: spec.bosTokenID,
                    eosToken: spec.eosTokenID,
                    padToken: spec.padTokenID,
                    maxLength: spec.tokenizerMaxLength
                )
                tokenizer = loaded
                return loaded
            } catch {
                throw AIError.generationFailed("failed to load CLIP tokenizer: \(error)")
            }
        }

        #if os(Android)
            private struct DownloadFileArgs: Encodable {
                let url: String
                let destPath: String
                let sha256: String?
            }

            private struct DownloadFileResult: Decodable {
                let bytesWritten: Int64
            }
        #endif
    }
#endif
