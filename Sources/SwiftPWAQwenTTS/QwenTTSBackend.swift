// Gated exactly like SwiftPWAStableDiffusion's backend: the body references the
// shared ONNX Runtime wrapper (OrtRuntime / OrtModelSession from SwiftPWAONNX),
// which only exists where an ONNX Runtime is linked. On any other destination
// the whole backend compiles to an empty stub; the pure pieces (QwenTokenizer /
// QwenNumpyArray / QwenTTSEmbeddings / QwenSampler / QwenWAV / spec) stay
// available regardless (they need no runtime).
// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)
    import Foundation
    import SwiftPWACore
    import SwiftPWAModelStore
    import SwiftPWAONNX
    #if os(Android)
        import SwiftPWAAndroid // AndroidFileDownload — model download routes through Kotlin's HTTP stack
    #endif

    /// An `AIBackend` that synthesizes speech from text on-device via the
    /// Qwen3-TTS ONNX pipeline on the shared `SwiftPWAONNX` tier — the
    /// text→audio (TTS) consumer of `ai.generateAudio`. Reports
    /// `audioGeneration: true`.
    ///
    /// **Pipeline** (verified end-to-end against the reference — see
    /// `docs/proposals/v0.9-plan.md` §"Phase B.1–B.3"): tokenize the chat
    /// template (Qwen2 byte-level BPE) → build the **non-streaming** prefill
    /// (full text in the prompt, constant `tts_pad` trailing) → warm up the
    /// talker token-by-token through the **decode** graph (the redundant
    /// `talker_prefill` graph is not shipped) → the nested autoregressive loop:
    /// sample codebook-0 from the talker, fill codebooks 1-15 with the
    /// code-predictor (reading its logits from the **last** sequence position),
    /// sum the 16 codebook embeddings + `tts_pad`, feed the next talker step;
    /// stop on `codec_eos` → assemble `(1,16,T)` → vocoder → 24 kHz PCM → WAV.
    ///
    /// Shipping precision (device-verified): **fp16 talker + fp32
    /// code_predictor + fp32 vocoder** (`QwenTTSModelSpec.customVoice0_6B`).
    /// Sessions load lazily and are cached; `unload()` frees them.
    public actor QwenTTSBackend: AIBackend {
        private let modelDirectory: URL
        private let spec: QwenTTSModelSpec

        private var talker: OrtModelSession?
        private var codePredictor: OrtModelSession?
        private var vocoder: OrtModelSession?
        private var embeddings: QwenTTSEmbeddings?
        private var tokenizer: QwenTokenizer?

        /// Set only for the downloadable tier — drives `ensureModel`. `nil` for
        /// the fixed-path tier, whose `ensureModel` throws. `files` is in
        /// download order (large weights first).
        private let download: (downloader: ModelDownloader, files: [QwenTTSModelSource.File])?

        /// Back a pipeline present on disk under `modelDirectory` (the export
        /// layout: the three graphs at the root, `embeddings/` + `tokenizer/`
        /// subdirs). `ai.ensureModel` throws `.unsupportedPlatform`. The default
        /// `spec` is the device-verified fp16-talker config.
        public init(modelDirectory: URL, spec: QwenTTSModelSpec = .customVoice0_6B) {
            self.modelDirectory = modelDirectory
            self.spec = spec
            download = nil
        }

        /// Back a **downloadable** pipeline: `ai.ensureModel` fetches the files
        /// described by `source` into `cacheDirectory` (resumable,
        /// checksum-pinned, subdir-qualified so it lands in the expected
        /// layout), and generation loads them from there. Mirrors
        /// `StableDiffusionBackend(cacheDirectory:source:)`. Defaults to the
        /// `qwen-tts-vendor`-published 0.6B CustomVoice pipeline; `source` and
        /// `spec` must match.
        public init(
            cacheDirectory: URL,
            source: QwenTTSModelSource = .customVoice0_6B,
            spec: QwenTTSModelSpec = .customVoice0_6B
        ) {
            modelDirectory = cacheDirectory
            self.spec = spec
            download = (ModelDownloader(directory: cacheDirectory), source.files)
        }

        /// The model id this backend advertises in `info().models` — the id a
        /// page (or a composite router) passes to `ai.ensureModel` to fetch the
        /// downloadable pipeline.
        public static let modelID = "qwen-tts"

        // MARK: AIBackend

        public func info() async -> AICapabilities {
            guard OrtRuntime.shared != nil else { return .none }
            return AICapabilities(
                available: true,
                backend: AIBackendID.qwenTTS,
                model: "qwen3-tts-12hz-0.6b-customvoice",
                audioGeneration: true,
                models: [modelInfo()]
            )
        }

        /// A single-entry catalog describing the TTS model + its availability, so
        /// a page can show a download bar (`.downloadable`) and flip to enabled
        /// once present (`.ready`) — mirrors `MultiModelImageBackend`. On the
        /// download tier, availability is derived from whether every source file
        /// is already on disk (a cheap existence check, not a re-hash); the
        /// fixed-path init is always `.ready`.
        private func modelInfo() -> AIModelInfo {
            let availability: AIModelAvailability
            if let download {
                let present = download.files.allSatisfy {
                    FileManager.default.fileExists(
                        atPath: modelDirectory.appendingPathComponent($0.fileName).path
                    )
                }
                availability = present ? .ready : .downloadable(bytes: download.files.reduce(0) { $0 + $1.sizeBytes })
            } else {
                availability = .ready
            }
            return AIModelInfo(
                id: Self.modelID,
                label: "Qwen3-TTS (0.6B CustomVoice)",
                capabilities: [.textToSpeech],
                availability: availability,
                offlineCapable: true,
                license: "Apache-2.0"
            )
        }

        /// Text generation is not this backend's job — it synthesizes speech.
        public func generate(_: AIGenerateRequest) async throws -> AIGenerateResult {
            throw AIError.unsupportedPlatform(
                "the Qwen3-TTS backend synthesizes speech (ai.generateAudio), it does not generate text"
            )
        }

        public func generateAudio(_ request: AIGenerateAudioRequest) async throws -> AIGenerateAudioResult {
            let synth = try synthesize(request)
            let wav = QwenWAV.encode(samples: synth.samples, sampleRate: spec.sampleRate)
            let durationMs = Int(Double(synth.samples.count) / Double(spec.sampleRate) * 1000)
            let audio: AIGeneratedAudio
            if let dir = request.outputDirectory {
                let path = try write(wav, toDirectory: dir, frames: synth.frames)
                audio = AIGeneratedAudio(path: path, mimeType: "audio/wav", durationMs: durationMs)
            } else {
                audio = AIGeneratedAudio(
                    dataBase64: wav.base64EncodedString(), mimeType: "audio/wav", durationMs: durationMs
                )
            }
            return AIGenerateAudioResult(audio: audio, backend: AIBackendID.qwenTTS)
        }

        /// Fetch the downloadable pipeline (resumable, checksum-pinned) into the
        /// cache directory, streaming one aggregate progress bar across every
        /// file. Throws `.unsupportedPlatform` on the fixed-path init. Mirrors
        /// `StableDiffusionBackend.ensureModel`.
        public nonisolated func ensureModel(_: AIEnsureModelRequest)
            -> AsyncThrowingStream<AIDownloadEvent, any Error>
        {
            guard let download else {
                return AsyncThrowingStream {
                    $0.finish(throwing: AIError
                        .unsupportedPlatform("this backend was constructed with a fixed model directory"))
                }
            }
            let (downloader, files) = download
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let grandTotal = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
                        var completed: Int64 = 0
                        for file in files {
                            let spec = ModelSpec(url: file.url, sha256: file.sha256, fileName: file.fileName)
                            let base = completed
                            #if os(Android)
                                // Swift's URLSession has no injectable CA store on
                                // Android; fetch through Android's HTTP stack via
                                // the Kotlin `net.downloadFile` RPC (system TLS,
                                // checksum-verified), as SD/LaMa/MobileSAM do. The
                                // destination path carries the subdir, and the
                                // downloader's parent-dir creation applies there too
                                // — but the RPC writes the raw path, so ensure the
                                // parent exists first.
                                let dest = downloader.localURL(for: spec)
                                try FileManager.default.createDirectory(
                                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
                                )
                                continuation.yield(.progress(bytesDone: base, totalBytes: grandTotal))
                                _ = try await AndroidFileDownload.download(
                                    url: file.url.absoluteString, destPath: dest.path, sha256: file.sha256
                                ) { bytesDone, _ in
                                    continuation.yield(.progress(bytesDone: base + bytesDone, totalBytes: grandTotal))
                                }
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

        /// Free the cached ONNX sessions + tables (several GB): dropping the
        /// `OrtModelSession` references frees the runtime sessions via `deinit`;
        /// the next generate reloads lazily.
        public func unload() async {
            talker = nil
            codePredictor = nil
            vocoder = nil
            embeddings = nil
            tokenizer = nil
        }

        // MARK: - Pipeline

        private struct Synthesis {
            var samples: [Float]
            var frames: Int
        }

        private func synthesize(_ request: AIGenerateAudioRequest) throws -> Synthesis {
            guard let runtime = OrtRuntime.shared else {
                throw AIError.unavailable("no usable ONNX Runtime is linked")
            }
            let text = request.prompt
            guard !text.isEmpty else {
                throw AIError.generationFailed("this backend synthesizes from `prompt` text — supply some")
            }
            let emb = try loadedEmbeddings()
            let cfg = emb.config
            let t = cfg.talker

            // Resolve voice + language against the config's tables.
            let speaker = (request.voice ?? "ryan").lowercased()
            guard let spk = emb.speakerIds[speaker] else {
                throw AIError.generationFailed(
                    "unknown voice \"\(speaker)\" — available: \(emb.speakerIds.keys.sorted().joined(separator: ", "))"
                )
            }
            let languageKey = (request.language ?? "english").lowercased()
            guard let lang = cfg.language_ids[languageKey] else {
                throw AIError.generationFailed("unknown language \"\(languageKey)\"")
            }

            // 1. Tokenize the chat template.
            let tokenizer = try loadedTokenizer(config: cfg)
            let template = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
            let ids = tokenizer.encode(template)
            guard ids.count >= 9 else {
                throw AIError.generationFailed("prompt tokenized to too few tokens (\(ids.count))")
            }

            // 2. Non-streaming prefill embeddings (see the pipeline doc).
            //    tts_pad / tts_bos / tts_eos projected once; tts_pad doubles as
            //    the constant trailing hidden during generation.
            let ttsPad = emb.textProj(cfg.tts.tts_pad_token_id)
            let bosP = emb.textProj(cfg.tts.tts_bos_token_id)
            let eosP = emb.textProj(cfg.tts.tts_eos_token_id)
            var prefill: [[Float]] = []
            for i in 0 ..< 3 { prefill.append(emb.textProj(ids[i])) } // role
            let pfx = [
                t.codec_think_id,
                t.codec_think_bos_id,
                lang,
                t.codec_think_eos_id,
                spk,
                t.codec_pad_id,
                t.codec_bos_id
            ]
            for i in 0 ..< (pfx.count - 2) { prefill.append(qwenVectorAdd(ttsPad, emb.talkerCodec(pfx[i]))) }
            prefill.append(qwenVectorAdd(bosP, emb.talkerCodec(pfx[pfx.count - 2]))) // bosP + codec_pad
            let textTokens = Array(ids[3 ..< (ids.count - 5)])
            for tok in textTokens { prefill.append(qwenVectorAdd(emb.textProj(tok), emb.talkerCodec(t.codec_pad_id))) }
            prefill.append(qwenVectorAdd(eosP, emb.talkerCodec(t.codec_pad_id))) // tts_eos + codec_pad
            prefill.append(qwenVectorAdd(ttsPad, emb.talkerCodec(t.codec_bos_id))) // tts_pad + codec_bos
            let prefillLength = prefill.count

            // 3. Warm up the talker token-by-token through the decode graph.
            let talker = try loadedTalker(runtime)
            var pastKeys = OrtModelSession.Tensor(
                values: [],
                shape: talkerKVShape(
                    layers: t.num_hidden_layers,
                    kv: t.num_key_value_heads,
                    headDim: t.head_dim,
                    seq: 0
                )
            )
            var pastValues = pastKeys
            var logits = [Float]()
            var lastHidden = [Float]()
            for step in 0 ..< prefillLength {
                let out = try runTalker(
                    talker, embed: prefill[step], position: step, seqLen: step + 1,
                    pastKeys: pastKeys, pastValues: pastValues
                )
                logits = out.logits; lastHidden = out.hidden; pastKeys = out.presentKeys; pastValues = out.presentValues
            }

            // 4. Autoregressive generation.
            let cp = try loadedCodePredictor(runtime)
            var rng = QwenSeededGenerator(seed: 0)
            var codes: [[Int]] = []
            var previous = Set<Int>()
            let numGroups = t.num_code_groups // 16
            for step in 0 ..< spec.maxFrames {
                let g0 = QwenSampler.sampleG0(
                    logits: logits, previous: previous, step: step,
                    talkerVocab: t.vocab_size, cpVocab: cfg.code_predictor.vocab_size, eos: t.codec_eos_token_id,
                    temperature: spec.temperature, topK: spec.topK,
                    repetitionPenalty: spec.repetitionPenalty, minNewTokens: spec.minNewTokens,
                    rng: &rng
                )
                if g0 == t.codec_eos_token_id { break }
                previous.insert(g0)
                var row = [g0]

                // Code-predictor: fill codebooks 1..15 for this frame.
                var cpKeys = OrtModelSession.Tensor(
                    values: [],
                    shape: cpKVShape(
                        layers: cfg.code_predictor.num_hidden_layers,
                        kv: cfg.code_predictor.num_key_value_heads,
                        headDim: cfg.code_predictor.head_dim,
                        seq: 0
                    )
                )
                var cpValues = cpKeys
                var next = lastHidden + emb.talkerCodec(g0) // [1,2,hidden] for the first cp step
                var nextSeq = 2
                for group in 1 ..< numGroups {
                    let cpOut = try runCodePredictor(
                        cp, embed: next, seq: nextSeq, generationStep: group - 1, pastKeys: cpKeys, pastValues: cpValues
                    )
                    // Read the codebook logits from the LAST sequence position
                    // (the first cp call feeds 2 tokens — the B.3 fix).
                    let cpVocab = cfg.code_predictor.vocab_size
                    let cpLogits = Array(cpOut.logits.suffix(cpVocab))
                    let ct = QwenSampler.sampleCP(
                        logits: cpLogits, temperature: spec.temperature, topK: spec.topK, rng: &rng
                    )
                    row.append(ct)
                    cpKeys = cpOut.presentKeys; cpValues = cpOut.presentValues
                    if group < numGroups - 1 { next = emb.cpCodec(group - 1, ct); nextSeq = 1 }
                }
                codes.append(row)

                // Build the next talker input: sum of the 16 codebook embeddings
                // + the constant tts_pad trailing (non-streaming).
                var ni = emb.talkerCodec(row[0])
                for g in 1 ..< numGroups { ni = qwenVectorAdd(ni, emb.cpCodec(g - 1, row[g])) }
                ni = qwenVectorAdd(ni, ttsPad)
                let out = try runTalker(
                    talker, embed: ni, position: prefillLength + step, seqLen: prefillLength + step + 1,
                    pastKeys: pastKeys, pastValues: pastValues
                )
                logits = out.logits; lastHidden = out.hidden; pastKeys = out.presentKeys; pastValues = out.presentValues
            }

            guard !codes.isEmpty else {
                throw AIError.generationFailed("no audio frames were generated")
            }

            // 5. Vocoder: assemble (1, 16, T) channel-major int64 codes → waveform.
            let frames = codes.count
            var vocCodes = [Int64](); vocCodes.reserveCapacity(numGroups * frames)
            for group in 0 ..< numGroups {
                for frame in 0 ..< frames { vocCodes.append(Int64(codes[frame][group])) }
            }
            let voc = try loadedVocoder(runtime)
            let vocOut = try mapOrt {
                try voc.run(
                    inputs: [spec.vocoderCodesName: .int64(vocCodes, shape: [1, Int64(numGroups), Int64(frames)])],
                    outputNames: [spec.vocoderWaveformName]
                )
            }
            guard let waveform = vocOut[spec.vocoderWaveformName] else {
                throw AIError.generationFailed("vocoder produced no \"\(spec.vocoderWaveformName)\" output")
            }
            return Synthesis(samples: waveform.values, frames: frames)
        }

        // MARK: - Graph calls

        private struct TalkerStep {
            var logits: [Float]; var hidden: [Float]; var presentKeys: OrtModelSession
                .Tensor; var presentValues: OrtModelSession.Tensor
        }

        private func runTalker(
            _ session: OrtModelSession, embed: [Float], position: Int, seqLen: Int,
            pastKeys: OrtModelSession.Tensor, pastValues: OrtModelSession.Tensor
        ) throws -> TalkerStep {
            let hidden = Int64(embed.count)
            let inputs: [String: OrtModelSession.OrtInput] = [
                spec.talkerInputsEmbedsName: .float16(embed, shape: [1, 1, hidden]),
                spec.talkerAttentionMaskName: .int64([Int64](repeating: 1, count: seqLen), shape: [1, Int64(seqLen)]),
                spec.talkerPositionIdsName: .int64(
                    [Int64(position), Int64(position), Int64(position)],
                    shape: [3, 1, 1]
                ),
                spec.talkerPastKeysName: .float16(pastKeys.values, shape: pastKeys.shape),
                spec.talkerPastValuesName: .float16(pastValues.values, shape: pastValues.shape)
            ]
            let out = try mapOrt {
                try session.run(inputs: inputs, outputNames: [
                    spec.talkerLogitsName, spec.talkerHiddenStatesName,
                    spec.talkerPresentKeysName, spec.talkerPresentValuesName
                ])
            }
            guard let logits = out[spec.talkerLogitsName], let hs = out[spec.talkerHiddenStatesName],
                  let pk = out[spec.talkerPresentKeysName], let pv = out[spec.talkerPresentValuesName]
            else { throw AIError.generationFailed("talker produced incomplete outputs") }
            return TalkerStep(logits: logits.values, hidden: hs.values, presentKeys: pk, presentValues: pv)
        }

        private struct CPStep {
            var logits: [Float]; var presentKeys: OrtModelSession.Tensor; var presentValues: OrtModelSession.Tensor
        }

        private func runCodePredictor(
            _ session: OrtModelSession, embed: [Float], seq: Int, generationStep: Int,
            pastKeys: OrtModelSession.Tensor, pastValues: OrtModelSession.Tensor
        ) throws -> CPStep {
            let hidden = Int64(embed.count / seq)
            let inputs: [String: OrtModelSession.OrtInput] = [
                spec.cpInputsEmbedsName: .float(embed, shape: [1, Int64(seq), hidden]),
                spec.cpGenerationStepsName: .int64([Int64(generationStep)], shape: [1]),
                spec.cpPastKeysName: .float(pastKeys.values, shape: pastKeys.shape),
                spec.cpPastValuesName: .float(pastValues.values, shape: pastValues.shape)
            ]
            let out = try mapOrt {
                try session.run(inputs: inputs, outputNames: [
                    spec.cpLogitsName, spec.cpPresentKeysName, spec.cpPresentValuesName
                ])
            }
            guard let logits = out[spec.cpLogitsName],
                  let pk = out[spec.cpPresentKeysName], let pv = out[spec.cpPresentValuesName]
            else { throw AIError.generationFailed("code predictor produced incomplete outputs") }
            return CPStep(logits: logits.values, presentKeys: pk, presentValues: pv)
        }

        private func talkerKVShape(layers: Int, kv: Int, headDim: Int, seq: Int) -> [Int64] {
            [Int64(layers), 1, Int64(kv), Int64(seq), Int64(headDim)]
        }

        private func cpKVShape(layers: Int, kv: Int, headDim: Int, seq: Int) -> [Int64] {
            [Int64(layers), 1, Int64(kv), Int64(seq), Int64(headDim)]
        }

        // MARK: - Loading

        /// Graph-optimization level: `.basic` everywhere. The pipeline was
        /// verified under `ORT_ENABLE_BASIC`, and it avoids the extended
        /// transformer fusions that rewrite standard ops into fused
        /// `com.microsoft.*` contrib ops — which the **Android** ONNX Runtime
        /// package has no fp16 kernels for (the SD Gelu-fusion gotcha).
        private var graphOptimizationLevel: OrtGraphOptimizationLevel {
            .basic
        }

        private func session(_ file: String, _ runtime: OrtRuntime) throws -> OrtModelSession {
            try mapOrt {
                try OrtModelSession(
                    modelPath: modelDirectory.appendingPathComponent(file).path,
                    runtime: runtime, graphOptimizationLevel: graphOptimizationLevel
                )
            }
        }

        private func loadedTalker(_ runtime: OrtRuntime) throws -> OrtModelSession {
            if let talker { return talker }
            let s = try session(spec.talkerDecodeFile, runtime); talker = s; return s
        }

        private func loadedCodePredictor(_ runtime: OrtRuntime) throws -> OrtModelSession {
            if let codePredictor { return codePredictor }
            let s = try session(spec.codePredictorFile, runtime); codePredictor = s; return s
        }

        private func loadedVocoder(_ runtime: OrtRuntime) throws -> OrtModelSession {
            if let vocoder { return vocoder }
            let s = try session(spec.vocoderFile, runtime); vocoder = s; return s
        }

        private func loadedEmbeddings() throws -> QwenTTSEmbeddings {
            if let embeddings { return embeddings }
            do {
                let e = try QwenTTSEmbeddings(
                    directory: modelDirectory.appendingPathComponent(spec.embeddingsSubdir), spec: spec
                )
                embeddings = e
                return e
            } catch {
                throw AIError.generationFailed("failed to load embedding tables: \(error)")
            }
        }

        private func loadedTokenizer(config: QwenTTSConfig) throws -> QwenTokenizer {
            if let tokenizer { return tokenizer }
            do {
                let t = try QwenTokenizer(
                    vocabURL: modelDirectory.appendingPathComponent(spec.tokenizerVocabFile),
                    mergesURL: modelDirectory.appendingPathComponent(spec.tokenizerMergesFile),
                    specialTokens: [
                        "<|im_start|>": config.tts.im_start_token_id,
                        "<|im_end|>": config.tts.im_end_token_id
                    ]
                )
                tokenizer = t
                return t
            } catch {
                throw AIError.generationFailed("failed to load Qwen tokenizer: \(error)")
            }
        }

        private func write(_ wav: Data, toDirectory directory: String, frames: Int) throws -> String {
            let dir = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("tts-\(frames)-\(wav.count).wav")
            try wav.write(to: url)
            return url.path
        }

        private func mapOrt<T>(_ body: () throws -> T) throws -> T {
            do { return try body() } catch let error as OrtError {
                throw AIError.generationFailed("\(error)")
            }
        }
    }
#endif
