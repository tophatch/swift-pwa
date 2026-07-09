#if canImport(CoreGraphics) && canImport(ImageIO)
    import Foundation
    import SwiftPWACore

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

        private struct CachedSession {
            let embedding: OrtModelSession.Tensor
            let preprocessed: PreprocessedImage
        }

        private var sessions: [String: CachedSession] = [:]
        private var sessionOrder: [String] = [] // oldest-first, for LRU eviction

        /// `encoderPath`/`decoderSinglePath`/`decoderMultiPath` are on-disk
        /// paths to the three ONNX graphs. No downloadable-model tier ships
        /// yet — see `ensureModel` below and the proposal doc's model-hosting
        /// section — so callers currently provide their own local weights.
        /// `maxSessions` caps concurrently cached embeddings (each is
        /// `256*64*64*4` bytes ≈ 4 MB; the proposal recommends 2–3).
        public init(encoderPath: String, decoderSinglePath: String, decoderMultiPath: String, maxSessions: Int = 3) {
            self.encoderPath = encoderPath
            self.decoderSinglePath = decoderSinglePath
            self.decoderMultiPath = decoderMultiPath
            self.maxSessions = maxSessions
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
            let preprocessed = try Self.mapping { try preprocess(request.image) }
            let encoder = try Self.mapping { try OrtModelSession(modelPath: encoderPath, runtime: runtime) }
            let outputs = try Self.mapping {
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
            let decoder = try Self.mapping { try OrtModelSession(modelPath: decoderPath, runtime: runtime) }
            let outputs = try Self.mapping {
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

        private func evictIfNeeded() {
            while sessionOrder.count > maxSessions {
                let oldest = sessionOrder.removeFirst()
                sessions.removeValue(forKey: oldest)
            }
        }

        private func preprocess(_ image: AIImage) throws -> PreprocessedImage {
            if let path = image.path {
                return try ImagePreprocessing.load(contentsOf: URL(fileURLWithPath: path))
            }
            if let base64 = image.dataBase64, let data = Data(base64Encoded: base64) {
                return try ImagePreprocessing.load(data: data)
            }
            throw VisionError.segmentationFailed("image must supply exactly one of path/dataBase64")
        }

        /// Converts a thrown `OrtError`/`ImagePreprocessingError` into the
        /// contract's `VisionError`, so callers only ever see stable
        /// `E_VISION_*` codes — mirrors `AIPlugin`'s `AIError` mapping.
        private static func mapping<T>(_ body: () throws -> T) throws -> T {
            do {
                return try body()
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
