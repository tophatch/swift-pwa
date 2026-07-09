// Apple (CoreGraphics/ImageIO-based preprocessing) or Android (RPC-based
// preprocessing, see AndroidImagePreprocessing.swift) — matches wherever an
// ONNX Runtime is actually linked (see OrtRuntime.swift). Linux/Windows have
// no ONNX Runtime story yet (see docs/proposals/segmentation-plugin.md).
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid)
    import Foundation
    import SwiftPWACore
    import SwiftPWAModelStore
    #if os(Android)
        import SwiftPWAAndroid // AndroidRPC — the model download routes through Kotlin's HTTP stack
    #endif

    /// The three ONNX files MobileSAM needs, as downloadable specs — encoder
    /// plus the two decoder variants. Backs `MobileSAMBackend`'s
    /// downloadable-model tier (`ai.vision.ensureModel`); each file carries
    /// its remote URL, pinned SHA-256, cache filename, and byte size (the
    /// size is used only to render a single aggregate progress bar across all
    /// three downloads).
    ///
    /// The default, ``mobileSAM``, points at this repo's canonical
    /// `mobilesam-vendor` GitHub Release — the verified `Acly/MobileSAM`
    /// re-export of the Apache-2.0 `ChaoningZhang/MobileSAM` checkpoint (see
    /// `docs/proposals/segmentation-plugin.md`). Supply a custom source to
    /// host the weights elsewhere; the graph contract must match (same three
    /// I/O shapes).
    public struct MobileSAMModelSource: Sendable, Equatable {
        /// One downloadable ONNX file.
        public struct File: Sendable, Equatable {
            public let url: URL
            public let sha256: String
            public let fileName: String
            public let sizeBytes: Int64

            public init(url: URL, sha256: String, fileName: String, sizeBytes: Int64) {
                self.url = url
                self.sha256 = sha256
                self.fileName = fileName
                self.sizeBytes = sizeBytes
            }

            var spec: ModelSpec {
                ModelSpec(url: url, sha256: sha256, fileName: fileName)
            }
        }

        public let encoder: File
        public let decoderSingle: File
        public let decoderMulti: File

        public init(encoder: File, decoderSingle: File, decoderMulti: File) {
            self.encoder = encoder
            self.decoderSingle = decoderSingle
            self.decoderMulti = decoderMulti
        }

        /// Canonical MobileSAM weights, hosted on this repo's stable
        /// `mobilesam-vendor` GitHub Release. Checksums + sizes are pinned
        /// against the published assets (verified byte-identical to the
        /// weights `Examples/CritterFacts` bundles).
        public static let mobileSAM = MobileSAMModelSource(
            encoder: File(
                url: URL(string: "https://github.com/tophatch/swift-pwa/releases/download/"
                    + "mobilesam-vendor/mobile_sam_image_encoder.onnx")!,
                sha256: "580f5fb648ea1062c0aabc26217aed56921985f03f0cbbd852bba81d760cc749",
                fileName: "mobile_sam_image_encoder.onnx",
                sizeBytes: 28_157_093
            ),
            decoderSingle: File(
                url: URL(string: "https://github.com/tophatch/swift-pwa/releases/download/"
                    + "mobilesam-vendor/sam_mask_decoder_single.onnx")!,
                sha256: "93915fc7c993ab9d59ab8c9ccd3bce37f7509c81ab4150a74abd4d2abbd8570d",
                fileName: "sam_mask_decoder_single.onnx",
                sizeBytes: 16_501_323
            ),
            decoderMulti: File(
                url: URL(string: "https://github.com/tophatch/swift-pwa/releases/download/"
                    + "mobilesam-vendor/sam_mask_decoder_multi.onnx")!,
                sha256: "8976b90a87ba50a6a72217a5ff994f7d25ce16f2229fcc1ed259e1294c622ffe",
                fileName: "sam_mask_decoder_multi.onnx",
                sizeBytes: 16_496_559
            )
        )
    }

    /// A `SegmentationBackend` running MobileSAM via three ONNX Runtime
    /// sessions — an encoder and two decoder variants — matching the
    /// **verified real contract** of `Acly/MobileSAM` on Hugging Face (a
    /// re-export of the official Apache-2.0 `ChaoningZhang/MobileSAM`
    /// checkpoint; see `docs/proposals/segmentation-plugin.md`):
    ///
    /// - **Encoder** — input `"input_image"` float32 `[height, width, 3]`
    ///   (raw pixel values `0...255`, RGB order, resized so the longer side
    ///   is 1024 — see `ImagePreprocessing` — but **not** padded, normalized,
    ///   or channel-transposed; the graph does all three internally) →
    ///   output `"image_embeddings"` float32 `[1,256,64,64]`.
    /// - **Decoder** (`sam_mask_decoder_single.onnx` when `multimask` is
    ///   false, `sam_mask_decoder_multi.onnx` when true — two separate
    ///   graphs, not one graph with a toggle) — inputs `"image_embeddings"`
    ///   (the encoder's output), `"point_coords"` float32 `[1,N,2]` (scaled
    ///   into the *resized* image's frame — see `PreprocessedImage.mapPoint`
    ///   — positive points labeled `1`, negative `0`, a box's two corners
    ///   labeled `2`/`3`), `"point_labels"` float32 `[1,N]`, `"mask_input"`
    ///   float32 `[1,1,256,256]` (zeros — no prior-mask refinement in v1),
    ///   `"has_mask_input"` float32 `[1]` (`0`), `"orig_im_size"` float32
    ///   `[2]` (`[height, width]`) → outputs `"masks"` float32
    ///   `[1,numMasks,origHeight,origWidth]` — **already upsampled to the
    ///   original image size by the graph itself** — and `"iou_predictions"`
    ///   float32 `[1,numMasks]`.
    ///
    /// Verified end-to-end against the real weights: a synthetic test image
    /// with a known shape at a known location round-trips through
    /// point/box/multi-point prompts with predicted mask bounding boxes
    /// matching the ground truth exactly.
    public actor MobileSAMBackend: SegmentationBackend {
        private let encoderPath: String
        private let decoderSinglePath: String
        private let decoderMultiPath: String
        private let maxSessions: Int
        /// Set only for the downloadable tier — drives `ensureModel`. `nil`
        /// for the fixed-path (bundled / bring-your-own-weights) tier, whose
        /// `ensureModel` throws `unsupportedPlatform`. `files` is ordered
        /// encoder, decoder-single, decoder-multi.
        private let download: (downloader: ModelDownloader, files: [MobileSAMModelSource.File])?

        private struct CachedSession {
            let embedding: OrtModelSession.Tensor
            let preprocessed: PreprocessedImage
        }

        private var sessions: [String: CachedSession] = [:]
        private var sessionOrder: [String] = [] // oldest-first, for LRU eviction

        /// Back three ONNX graphs already present on disk (bundled with the
        /// app, or otherwise fetched by the caller). `ensureModel` reports
        /// `unsupportedPlatform` in this mode — nothing to download.
        /// `maxSessions` caps concurrently cached embeddings (each is
        /// `256*64*64*4` bytes ≈ 4 MB; the proposal recommends 2–3).
        public init(encoderPath: String, decoderSinglePath: String, decoderMultiPath: String, maxSessions: Int = 3) {
            self.encoderPath = encoderPath
            self.decoderSinglePath = decoderSinglePath
            self.decoderMultiPath = decoderMultiPath
            self.maxSessions = maxSessions
            download = nil
        }

        /// Back a downloadable model: `ai.vision.ensureModel` fetches the
        /// three ONNX files described by `source` into `cacheDirectory`
        /// (resumable, checksum-pinned via `ModelDownloader`), and
        /// `openSession`/`segment` load them from there once present. The
        /// default `source` (`.mobileSAM`) points at this repo's
        /// `mobilesam-vendor` release. Mirrors `LlamaBackend`'s
        /// `init(model:cacheDirectory:)` downloadable tier — the same
        /// download machinery, three files instead of one.
        ///
        /// On Android this is the *preferred* path over bundling weights as
        /// APK assets: the downloader writes straight to a real filesystem
        /// path, sidestepping the "an APK asset isn't a file ONNX Runtime can
        /// open" problem (no `fs.writeBinary` materialization step needed).
        public init(cacheDirectory: URL, source: MobileSAMModelSource = .mobileSAM, maxSessions: Int = 3) {
            let downloader = ModelDownloader(directory: cacheDirectory)
            encoderPath = downloader.localURL(for: source.encoder.spec).path
            decoderSinglePath = downloader.localURL(for: source.decoderSingle.spec).path
            decoderMultiPath = downloader.localURL(for: source.decoderMulti.spec).path
            self.maxSessions = maxSessions
            download = (downloader, [source.encoder, source.decoderSingle, source.decoderMulti])
        }

        public func info() async -> VisionCapabilities {
            guard OrtRuntime.shared != nil else { return .none }
            return VisionCapabilities(
                available: true, backend: VisionBackendID.mobileSAMONNX, model: "mobile-sam",
                pointPrompts: true, boxPrompts: true, multimask: true, autoMask: false,
                maxImageSize: 1024, sessionCaching: true
            )
        }

        public func openSession(_ request: OpenSessionRequest) async throws -> VisionSession {
            guard let runtime = OrtRuntime.shared else {
                throw VisionError.unavailable("no ONNX Runtime linked (SWIFT_PWA_ONNXRUNTIME is off)")
            }
            let preprocessed = try await mapping { try await preprocess(request.image) }
            let encoder = try await mapping { try OrtModelSession(modelPath: encoderPath, runtime: runtime) }
            let outputs = try await mapping {
                try encoder.run(
                    inputs: [
                        "input_image": .init(
                            values: preprocessed.tensor,
                            shape: [Int64(preprocessed.resizedHeight), Int64(preprocessed.resizedWidth), 3]
                        )
                    ],
                    outputNames: ["image_embeddings"]
                )
            }
            guard let embedding = outputs["image_embeddings"] else {
                throw VisionError.segmentationFailed("encoder produced no image_embeddings output")
            }

            let sessionID = UUID().uuidString
            sessions[sessionID] = CachedSession(embedding: embedding, preprocessed: preprocessed)
            sessionOrder.append(sessionID)
            evictIfNeeded()

            return VisionSession(
                sessionID: sessionID, width: preprocessed.originalWidth, height: preprocessed.originalHeight
            )
        }

        public func segment(_ request: SegmentRequest) async throws -> SegmentResult {
            guard let cached = sessions[request.sessionID] else {
                throw VisionError.session("unknown or evicted session \(request.sessionID)")
            }
            guard let runtime = OrtRuntime.shared else {
                throw VisionError.unavailable("no ONNX Runtime linked (SWIFT_PWA_ONNXRUNTIME is off)")
            }

            var coords: [Float] = []
            var labels: [Float] = []
            for point in request.points ?? [] {
                let mapped = cached.preprocessed.mapPoint(x: point.x, y: point.y)
                coords.append(Float(mapped.x))
                coords.append(Float(mapped.y))
                labels.append(Float(point.label))
            }
            if let box = request.box, box.count == 4 {
                let topLeft = cached.preprocessed.mapPoint(x: box[0], y: box[1])
                let bottomRight = cached.preprocessed.mapPoint(x: box[2], y: box[3])
                coords.append(Float(topLeft.x))
                coords.append(Float(topLeft.y))
                labels.append(2) // SAM's box-corner point labels
                coords.append(Float(bottomRight.x))
                coords.append(Float(bottomRight.y))
                labels.append(3)
            }
            guard !labels.isEmpty else {
                throw VisionError.segmentationFailed("segment requires at least one point or a box prompt")
            }
            let numPoints = Int64(labels.count)

            let decoderPath = request.multimask ? decoderMultiPath : decoderSinglePath
            let decoder = try await mapping { try OrtModelSession(modelPath: decoderPath, runtime: runtime) }
            let outputs = try await mapping {
                try decoder.run(
                    inputs: [
                        "image_embeddings": cached.embedding,
                        "point_coords": .init(values: coords, shape: [1, numPoints, 2]),
                        "point_labels": .init(values: labels, shape: [1, numPoints]),
                        "mask_input": .init(values: [Float](repeating: 0, count: 256 * 256), shape: [1, 1, 256, 256]),
                        "has_mask_input": .init(values: [0], shape: [1]),
                        "orig_im_size": .init(
                            values: [
                                Float(cached.preprocessed.originalHeight),
                                Float(cached.preprocessed.originalWidth)
                            ],
                            shape: [2]
                        )
                    ],
                    outputNames: ["masks", "iou_predictions"]
                )
            }
            guard let masksTensor = outputs["masks"], let iouTensor = outputs["iou_predictions"],
                  masksTensor.shape.count == 4
            else {
                throw VisionError.segmentationFailed("decoder produced no usable masks/iou_predictions output")
            }

            let numMasks = Int(masksTensor.shape[1])
            let maskHeight = Int(masksTensor.shape[2])
            let maskWidth = Int(masksTensor.shape[3])
            var candidates: [VisionMask] = []
            for maskIndex in 0 ..< numMasks {
                let offset = maskIndex * maskHeight * maskWidth
                guard offset + maskHeight * maskWidth <= masksTensor.values.count else { continue }
                // The decoder graph already upsampled this to
                // `orig_im_size` — threshold at logit 0 (SAM's convention)
                // and encode directly, no client-side resampling needed.
                let logits = masksTensor.values[offset ..< offset + maskHeight * maskWidth]
                let binaryMask = logits.map { $0 > 0 }
                guard let encoded = MaskPostprocessing.encodeRLE(binaryMask, width: maskWidth, height: maskHeight)
                else { continue }
                let score = maskIndex < iouTensor.values.count ? Double(iouTensor.values[maskIndex]) : 0
                candidates.append(VisionMask(bounds: encoded.bounds, rle: encoded.rle, score: score))
            }
            candidates.sort { $0.score > $1.score }
            return SegmentResult(masks: candidates)
        }

        public func closeSession(_ sessionID: String) async {
            sessions.removeValue(forKey: sessionID)
            sessionOrder.removeAll { $0 == sessionID }
        }

        /// Downloadable-model tier: fetch the three ONNX files (encoder +
        /// both decoder variants) into the cache directory this backend was
        /// constructed with, streaming a single aggregate progress bar across
        /// all three. Resumable and checksum-pinned (each file is verified
        /// against its `sha256`; an already-present, intact file is skipped).
        /// Throws `unsupportedPlatform` when the backend was built from fixed
        /// on-disk paths (nothing to download).
        ///
        /// The `ModelDownloader` surfaces failures as `AIError`; we re-wrap
        /// them as `VisionError.modelDownloadFailed` so `VisionPlugin`'s
        /// error mapping emits the stable `E_VISION_MODEL` bridge code (its
        /// `mapping` only catches `VisionError`).
        public nonisolated func ensureModel(_: AIEnsureModelRequest)
            -> AsyncThrowingStream<AIDownloadEvent, any Error>
        {
            guard let download else {
                return AsyncThrowingStream {
                    $0.finish(
                        throwing: VisionError
                            .unsupportedPlatform("this backend was constructed with fixed on-disk model paths")
                    )
                }
            }
            let (downloader, files) = download
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // One bar across all three files: cumulative bytes
                        // over the known grand total, so the JS side sees a
                        // single 0→100% sweep rather than three resets.
                        let grandTotal = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
                        var completed: Int64 = 0
                        for file in files {
                            let base = completed
                            #if os(Android)
                                // Swift's URLSession (libcurl + BoringSSL) has
                                // no injectable CA trust store on Android, so
                                // HTTPS fails there; download through Android's
                                // own HTTP stack via the Kotlin `net.downloadFile`
                                // RPC instead (system TLS, checksum-verified,
                                // cache-reusing — see AndroidTemplates.swift).
                                // Progress is per-file (no byte callback across
                                // the RPC), so the bar advances in three steps.
                                continuation.yield(.progress(bytesDone: base, totalBytes: grandTotal))
                                _ = try await AndroidRPC.call(
                                    "net.downloadFile",
                                    DownloadFileArgs(
                                        url: file.url.absoluteString,
                                        destPath: downloader.localURL(for: file.spec).path,
                                        sha256: file.sha256
                                    ),
                                    as: DownloadFileResult.self
                                )
                            #else
                                _ = try await downloader.ensure(file.spec) { bytesDone, _ in
                                    continuation.yield(.progress(bytesDone: base + bytesDone, totalBytes: grandTotal))
                                }
                            #endif
                            completed += file.sizeBytes
                        }
                        continuation.yield(.done)
                        continuation.finish()
                    } catch let error as AIError {
                        continuation.finish(throwing: VisionError.modelDownloadFailed(error.bridgeError.message))
                    } catch {
                        continuation.finish(throwing: VisionError.modelDownloadFailed("\(error)"))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        #if os(Android)
            /// Args/result for the Kotlin `net.downloadFile` RPC (Android's
            /// HTTP stack does the TLS + write; see the `ensureModel` comment).
            private struct DownloadFileArgs: Encodable {
                let url: String
                let destPath: String
                let sha256: String?
            }

            private struct DownloadFileResult: Decodable {
                let bytesWritten: Int64
            }
        #endif

        private func evictIfNeeded() {
            while sessionOrder.count > maxSessions {
                let oldest = sessionOrder.removeFirst()
                sessions.removeValue(forKey: oldest)
            }
        }

        private func preprocess(_ image: AIImage) async throws -> PreprocessedImage {
            if let path = image.path {
                return try await ImagePreprocessing.load(path: path)
            }
            if let base64 = image.dataBase64 {
                return try await ImagePreprocessing.load(dataBase64: base64)
            }
            throw VisionError.segmentationFailed("image must supply exactly one of path/dataBase64")
        }

        /// Converts a thrown `OrtError`/`ImagePreprocessingError` into the
        /// contract's `VisionError`, so callers only ever see stable
        /// `E_VISION_*` codes — mirrors `AIPlugin`'s `AIError` mapping. An
        /// actor-isolated instance method, not `static` — the closures
        /// passed in capture actor-isolated state (e.g. calling
        /// `preprocess(_:)`), so `mapping` must share that isolation domain
        /// rather than being a `nonisolated static` boundary the closure
        /// would have to cross.
        private func mapping<T>(_ body: () async throws -> T) async throws -> T {
            do {
                return try await body()
            } catch let error as OrtError {
                throw VisionError.segmentationFailed(error.description)
            } catch let error as ImagePreprocessingError {
                switch error {
                case let .decodeFailed(detail): throw VisionError
                    .segmentationFailed("could not decode image: \(detail)")
                case let .unsupportedColorFormat(detail): throw VisionError.segmentationFailed(detail)
                }
            }
        }
    }
#endif
