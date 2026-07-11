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
    /// **Increment status — skeleton.** This lands the design, the
    /// downloadable-model wiring, and the fully-working, weight-free
    /// `CLIPTokenizer`. The denoising loop itself is **not yet run**:
    /// `generateImage` tokenizes the prompt (real) and then throws a clear
    /// "pending real-weights integration" error at the inference boundary.
    /// The integer-input support the graphs need (`input_ids` int32, UNet
    /// `timestep` int64) has since landed in `OrtModelSession` (`OrtInput`).
    /// What the real-weights pass still adds:
    ///
    /// - **Scheduler `step()` + tensor-name/scaling confirmation.** The
    ///   `StableDiffusionModelSpec` constants (tensor names, VAE scaling,
    ///   scheduler betas) are assumed from diffusers defaults and get
    ///   confirmed against the real checkpoint — the SAM/LaMa pattern —
    ///   then the real denoise loop + VAE-decode→PNG are wired.
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
            guard OrtRuntime.shared != nil else {
                throw AIError.unavailable("no usable ONNX Runtime is linked")
            }
            guard let prompt = request.prompt, !prompt.isEmpty else {
                throw AIError.generationFailed("this backend generates from a text `prompt` — supply one")
            }

            // Real, weight-free pipeline prefix: tokenize the prompt into the
            // fixed-length input_ids the text encoder consumes.
            let tokenizer = try loadedTokenizer()
            _ = tokenizer.encode(prompt)

            // The denoising loop is pending the real-weights integration pass
            // (int32/int64 input tensors + scheduler confirmation). Fail
            // clearly rather than silently returning nothing — see the type
            // doc and docs/proposals/stable-diffusion.md.
            throw AIError.unsupportedPlatform(
                "stable-diffusion-onnx inference is pending the real-weights integration pass "
                    + "(scheduler step() + tensor-name/scaling confirmation against a real checkpoint); "
                    + "the prompt tokenizer, integer input tensors, and model download are wired"
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

        private func loadedTokenizer() throws -> CLIPTokenizer {
            if let tokenizer { return tokenizer }
            do {
                let loaded = try CLIPTokenizer(
                    vocabURL: URL(fileURLWithPath: tokenizerVocabPath),
                    mergesURL: URL(fileURLWithPath: tokenizerMergesPath),
                    bosToken: spec.bosTokenID,
                    eosToken: spec.eosTokenID,
                    padToken: spec.eosTokenID,
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
