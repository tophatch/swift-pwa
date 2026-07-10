// Preprocessing is platform-specific — Apple (CoreGraphics/ImageIO), Android
// (RPC to Kotlin BitmapFactory, see AndroidImagePreprocessing.swift), or
// desktop Linux/Windows (vendored stb_image, see DesktopImagePreprocessing.swift)
// — but gated together wherever an ONNX Runtime is actually linked (see
// OrtRuntime.swift).
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop)
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
                pointPrompts: true, boxPrompts: true, multimask: true, autoMask: true,
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

            let decoderPath = request.multimask ? decoderMultiPath : decoderSinglePath
            let decoder = try await mapping { try OrtModelSession(modelPath: decoderPath, runtime: runtime) }
            let (masksTensor, iouTensor) = try await mapping {
                try Self.runDecoder(
                    session: decoder, embedding: cached.embedding, coords: coords, labels: labels,
                    origHeight: Float(cached.preprocessed.originalHeight),
                    origWidth: Float(cached.preprocessed.originalWidth)
                )
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

        /// Automatic mask generation — a `pointsPerSide × pointsPerSide` grid
        /// of positive-point prompts through the (multi-mask) decoder, then
        /// NMS to dedup overlapping masks. The unary form drains the streaming
        /// form with a no-op progress sink; both share one AMG pass.
        public func segmentAll(_ request: SegmentAllRequest) async throws -> SegmentResult {
            try await SegmentResult(masks: runAutomaticMaskGeneration(request) { _, _ in })
        }

        /// Streaming AMG: yields a `progress(done, total)` frame per grid cell
        /// as it sweeps, then a terminal `done` carrying every deduped mask
        /// (best-score-first). Cancelling the subscription cancels the sweep.
        public nonisolated func segmentAllStream(_ request: SegmentAllRequest)
            -> AsyncThrowingStream<VisionProgress, any Error>
        {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let masks = try await runAutomaticMaskGeneration(request) { done, total in
                            continuation.yield(.progress(done: done, total: total))
                        }
                        continuation.yield(.done(masks: masks))
                        continuation.finish()
                    } catch let error as VisionError {
                        continuation.finish(throwing: error)
                    } catch {
                        continuation.finish(throwing: VisionError.segmentationFailed("\(error)"))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// The shared AMG pass behind `segmentAll` / `segmentAllStream`.
        ///
        /// SAM's mask decoder is cheap relative to the encoder (which ran once
        /// in `openSession` and is cached), so AMG is "prompt at every grid
        /// point, keep the good masks, dedup." Two efficiency choices keep a
        /// full sweep tractable on a phone:
        ///
        /// - **One decoder session, reused for the whole grid** — the graph is
        ///   parsed once, not per point.
        /// - **Discover at a reduced working resolution** — the decoder
        ///   upsamples masks to whatever `orig_im_size` we hand it, so passing
        ///   a capped working size (``amgWorkingSize``) yields small masks that
        ///   are fast to threshold/NMS. Surviving masks are then nearest-
        ///   upsampled to source pixels for the returned `bounds`/`rle`. AMG
        ///   masks are inherently approximate (a hover-highlight / pre-segment
        ///   affordance), so the coarse upsample is an accepted trade.
        private func runAutomaticMaskGeneration(
            _ request: SegmentAllRequest,
            onProgress: @Sendable (Int, Int) -> Void
        ) async throws -> [VisionMask] {
            guard let cached = sessions[request.sessionID] else {
                throw VisionError.session("unknown or evicted session \(request.sessionID)")
            }
            guard let runtime = OrtRuntime.shared else {
                throw VisionError.unavailable("no ONNX Runtime linked (SWIFT_PWA_ONNXRUNTIME is off)")
            }

            // Clamp the grid so a pathological request can't spin up an
            // unbounded number of decoder passes (pointsPerSide² of them).
            let pointsPerSide = min(
                Self.amgMaxPointsPerSide,
                max(1, request.pointsPerSide ?? Self.amgDefaultPointsPerSide)
            )
            return try await automaticMasks(
                cached: cached, runtime: runtime, pointsPerSide: pointsPerSide,
                nmsThreshold: request.iouThreshold ?? Self.amgDefaultNMSThreshold,
                minAreaPx: max(0, request.minAreaPx ?? 0), onProgress: onProgress
            )
        }

        /// The AMG algorithm proper, over an already-resolved session + params.
        /// Split from `runAutomaticMaskGeneration` so `benchmark` can time a
        /// grid sweep against a synthetic session without touching `sessions`.
        private func automaticMasks(
            cached: CachedSession, runtime: OrtRuntime, pointsPerSide: Int,
            nmsThreshold: Double, minAreaPx: Int,
            onProgress: @Sendable (Int, Int) -> Void
        ) async throws -> [VisionMask] {
            let originalWidth = cached.preprocessed.originalWidth
            let originalHeight = cached.preprocessed.originalHeight

            let longSide = Double(max(originalWidth, originalHeight, 1))
            let workScale = min(1.0, Double(Self.amgWorkingSize) / longSide) // never upscale small images
            let workWidth = max(1, Int((Double(originalWidth) * workScale).rounded()))
            let workHeight = max(1, Int((Double(originalHeight) * workScale).rounded()))
            let minAreaWork = Double(minAreaPx) * workScale * workScale

            let decoder = try await mapping { try OrtModelSession(modelPath: decoderMultiPath, runtime: runtime) }

            var candidates: [AMGCandidate] = []
            let total = pointsPerSide * pointsPerSide
            var done = 0
            for row in 0 ..< pointsPerSide {
                for col in 0 ..< pointsPerSide {
                    try Task.checkCancellation()
                    // Cell-centered grid point in source pixels → resized frame.
                    let sx = (Double(col) + 0.5) / Double(pointsPerSide) * Double(originalWidth)
                    let sy = (Double(row) + 0.5) / Double(pointsPerSide) * Double(originalHeight)
                    let mapped = cached.preprocessed.mapPoint(x: sx, y: sy)
                    let (masksTensor, iouTensor) = try await mapping {
                        try Self.runDecoder(
                            session: decoder, embedding: cached.embedding,
                            coords: [Float(mapped.x), Float(mapped.y)], labels: [1],
                            origHeight: Float(workHeight), origWidth: Float(workWidth)
                        )
                    }
                    candidates.append(
                        contentsOf: Self.extractCandidates(
                            masks: masksTensor, iou: iouTensor,
                            qualityFloor: Self.amgQualityFloor, minAreaWork: minAreaWork
                        )
                    )
                    done += 1
                    onProgress(done, total)
                    await Task.yield() // stay a good citizen across a long sweep
                }
            }

            // Greedy NMS: best score first, drop any later mask overlapping a
            // kept one by more than `nmsThreshold` (mask IoU on the work grid).
            candidates.sort { $0.score > $1.score }
            var kept: [AMGCandidate] = []
            for candidate in candidates where !kept.contains(where: { Self.maskIoU($0, candidate) > nmsThreshold }) {
                kept.append(candidate)
            }

            return kept.compactMap { candidate in
                guard let encoded = MaskPostprocessing.encodeUpsampledRLE(
                    workMask: candidate.mask, workWidth: workWidth, workHeight: workHeight,
                    workBounds: candidate.bounds, scale: workScale,
                    sourceWidth: originalWidth, sourceHeight: originalHeight
                ) else { return nil }
                return VisionMask(bounds: encoded.bounds, rle: encoded.rle, score: candidate.score)
            }
        }

        /// Real synthetic timing for the consumer's device-capability gate.
        /// Times a single encode, a single decode, and a small AMG sweep on a
        /// synthetic 1024² image (image content doesn't affect timing — only
        /// tensor shape does — so a cheap gradient stands in, keeping the probe
        /// free of any image-codec/platform-decode dependency). Session
        /// creation (graph parse) is done outside the timed regions so the
        /// numbers reflect steady-state per-call cost, not one-time load. The
        /// `deviceClass` bucket is a coarse convenience — the proposal's
        /// primary device-classing path is the app timing its own first real
        /// `openSession`/`segment`.
        public func benchmark() async throws -> VisionBenchmark {
            guard let runtime = OrtRuntime.shared else {
                throw VisionError.unavailable("no ONNX Runtime linked (SWIFT_PWA_ONNXRUNTIME is off)")
            }
            let side = Self.benchmarkImageSide
            var tensor = [Float](repeating: 0, count: side * side * 3)
            for index in 0 ..< (side * side) {
                let value = Float(index % 256)
                tensor[index * 3] = value
                tensor[index * 3 + 1] = value
                tensor[index * 3 + 2] = value
            }
            let preprocessed = PreprocessedImage(
                tensor: tensor, originalWidth: side, originalHeight: side,
                resizedWidth: side, resizedHeight: side, scale: 1.0
            )

            let clock = ContinuousClock()
            let encoder = try await mapping { try OrtModelSession(modelPath: encoderPath, runtime: runtime) }
            let decoder = try await mapping { try OrtModelSession(modelPath: decoderSinglePath, runtime: runtime) }

            let encodeStart = clock.now
            let outputs = try await mapping {
                try encoder.run(
                    inputs: ["input_image": .init(values: preprocessed.tensor, shape: [Int64(side), Int64(side), 3])],
                    outputNames: ["image_embeddings"]
                )
            }
            let encodeMs = Self.milliseconds(clock.now - encodeStart)
            guard let embedding = outputs["image_embeddings"] else {
                throw VisionError.segmentationFailed("benchmark encoder produced no embedding")
            }
            let cached = CachedSession(embedding: embedding, preprocessed: preprocessed)

            let decodeStart = clock.now
            _ = try await mapping {
                try Self.runDecoder(
                    session: decoder, embedding: embedding,
                    coords: [Float(side) / 2, Float(side) / 2], labels: [1],
                    origHeight: Float(side), origWidth: Float(side)
                )
            }
            let decodeMs = Self.milliseconds(clock.now - decodeStart)

            // A small AMG sweep (not the full default grid — a benchmark
            // shouldn't stall for seconds) times the "segment everything" path.
            let amgStart = clock.now
            _ = try await automaticMasks(
                cached: cached, runtime: runtime, pointsPerSide: Self.benchmarkPointsPerSide,
                nmsThreshold: Self.amgDefaultNMSThreshold, minAreaPx: 0
            ) { _, _ in }
            let segmentAllMs = Self.milliseconds(clock.now - amgStart)

            return VisionBenchmark(
                encodeMs: encodeMs, decodeMs: decodeMs, segmentAllMs: segmentAllMs,
                deviceClass: Self.deviceClass(encodeMs: encodeMs)
            )
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

        // MARK: - Automatic mask generation internals

        /// AMG grid density used when `pointsPerSide` is unset — matches the
        /// proposal's example. 16² = 256 decoder passes on the cached embedding.
        private static let amgDefaultPointsPerSide = 16
        /// Hard cap on `pointsPerSide` so a request can't fan out into an
        /// unbounded number of decoder passes.
        private static let amgMaxPointsPerSide = 32
        /// Default NMS dedup threshold (mask IoU) when `iouThreshold` is unset
        /// — matches the proposal's example. Masks overlapping a kept mask by
        /// more than this are treated as duplicates.
        private static let amgDefaultNMSThreshold = 0.88
        /// Drop candidate masks whose predicted IoU is below this before NMS —
        /// culls the low-confidence junk a single grid point often produces on
        /// background/ambiguous locations.
        private static let amgQualityFloor = 0.7
        /// Longest-side working resolution for the AMG discovery pass (see
        /// `runAutomaticMaskGeneration`). Small enough that a full grid of
        /// masks fits comfortably in memory; survivors are upsampled to source.
        private static let amgWorkingSize = 256

        // MARK: - Benchmark internals

        /// The encoder's native square input — a benchmark on a fixed 1024²
        /// image is representative since the encoder resizes any image to this.
        private static let benchmarkImageSide = 1024
        /// A modest AMG grid for the benchmark's `segmentAllMs` — enough to
        /// exercise the sweep + NMS without the multi-second cost of the full
        /// default grid.
        private static let benchmarkPointsPerSide = 8

        /// Coarse device-class bucket keyed on encode time — the dominant,
        /// most stable cost (a fixed 1024² ViT regardless of source image).
        /// Heuristic thresholds; calibrated so a modern desktop/phone GPU-class
        /// encode lands in `high` and a slow CPU-only path in `low`.
        private static func deviceClass(encodeMs: Int) -> String {
            switch encodeMs {
            case ..<400: "high"
            case ..<1500: "mid"
            default: "low"
            }
        }

        /// `Duration` → whole milliseconds (`components` is seconds +
        /// attoseconds; 1 ms = 1e15 as).
        private static func milliseconds(_ duration: Duration) -> Int {
            let components = duration.components
            return Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
        }

        /// One AMG mask candidate at working resolution, before NMS/upsample.
        private struct AMGCandidate {
            var mask: [Bool] // row-major, `width * height`
            var width: Int // working-grid row stride
            var bounds: [Int] // tight bbox in working px, `[x0, y0, x1, y1]`
            var area: Int // set pixels, for IoU
            var score: Double
        }

        /// Turns one decoder run's `masks`/`iou_predictions` into working-res
        /// candidates: threshold each mask's logits at 0, drop the ones below
        /// `qualityFloor` or `minAreaWork`, and record a tight bbox + area for
        /// the later NMS pass. Pure/static so the AMG loop calls it without an
        /// isolation hop.
        private static func extractCandidates(
            masks: OrtModelSession.Tensor, iou: OrtModelSession.Tensor,
            qualityFloor: Double, minAreaWork: Double
        ) -> [AMGCandidate] {
            let numMasks = Int(masks.shape[1])
            let height = Int(masks.shape[2])
            let width = Int(masks.shape[3])
            let plane = width * height
            var out: [AMGCandidate] = []
            for maskIndex in 0 ..< numMasks {
                let score = maskIndex < iou.values.count ? Double(iou.values[maskIndex]) : 0
                guard score >= qualityFloor else { continue }
                let offset = maskIndex * plane
                guard offset + plane <= masks.values.count else { continue }
                var mask = [Bool](repeating: false, count: plane)
                var area = 0
                var minX = width, minY = height, maxX = -1, maxY = -1
                for index in 0 ..< plane where masks.values[offset + index] > 0 {
                    mask[index] = true
                    area += 1
                    let x = index % width, y = index / width
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                guard maxX >= minX, Double(area) >= minAreaWork else { continue }
                out.append(
                    AMGCandidate(mask: mask, width: width, bounds: [minX, minY, maxX, maxY], area: area, score: score)
                )
            }
            return out
        }

        /// Mask IoU between two working-res candidates (which share a working
        /// grid, so `a.width == b.width`). Bounding boxes are checked first —
        /// disjoint bounds short-circuit to 0 without scanning any pixels.
        private static func maskIoU(_ a: AMGCandidate, _ b: AMGCandidate) -> Double {
            let ix0 = max(a.bounds[0], b.bounds[0]), iy0 = max(a.bounds[1], b.bounds[1])
            let ix1 = min(a.bounds[2], b.bounds[2]), iy1 = min(a.bounds[3], b.bounds[3])
            guard ix1 >= ix0, iy1 >= iy0 else { return 0 }
            var intersection = 0
            for y in iy0 ... iy1 {
                let base = y * a.width
                for x in ix0 ... ix1 where a.mask[base + x] && b.mask[base + x] { intersection += 1 }
            }
            let union = a.area + b.area - intersection
            return union > 0 ? Double(intersection) / Double(union) : 0
        }

        /// Runs the mask decoder once and returns the raw `masks` /
        /// `iou_predictions` tensors. Shared by `segment` (source-resolution
        /// `orig_im_size`) and the AMG grid sweep (a reduced working
        /// resolution). Static/pure — no actor state — so the AMG loop can call
        /// it hundreds of times against one reused session.
        private static func runDecoder(
            session: OrtModelSession, embedding: OrtModelSession.Tensor,
            coords: [Float], labels: [Float], origHeight: Float, origWidth: Float
        ) throws -> (masks: OrtModelSession.Tensor, iou: OrtModelSession.Tensor) {
            let numPoints = Int64(labels.count)
            let outputs = try session.run(
                inputs: [
                    "image_embeddings": embedding,
                    "point_coords": .init(values: coords, shape: [1, numPoints, 2]),
                    "point_labels": .init(values: labels, shape: [1, numPoints]),
                    "mask_input": .init(values: [Float](repeating: 0, count: 256 * 256), shape: [1, 1, 256, 256]),
                    "has_mask_input": .init(values: [0], shape: [1]),
                    "orig_im_size": .init(values: [origHeight, origWidth], shape: [2])
                ],
                outputNames: ["masks", "iou_predictions"]
            )
            guard let masks = outputs["masks"], let iou = outputs["iou_predictions"], masks.shape.count == 4 else {
                throw OrtError.failed("decoder produced no usable masks/iou_predictions output")
            }
            return (masks, iou)
        }

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
