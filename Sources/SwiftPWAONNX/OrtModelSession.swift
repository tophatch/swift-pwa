#if canImport(ONNXRuntime)
    import ONNXRuntime
#elseif canImport(ONNXRuntimeAndroid)
    import ONNXRuntimeAndroid
#elseif canImport(ONNXRuntimeDirectML)
    import ONNXRuntimeDirectML
#elseif canImport(ONNXRuntimeDesktop)
    import ONNXRuntimeDesktop
#endif
import Foundation
import SwiftPWACore // FileHandle.writeQuietly (log-once EP fallback)

// See the matching comment in OrtRuntime.swift — this type references ONNX
// Runtime C API types unconditionally, so the whole body is gated to
// destinations where one of the ONNX Runtime imports above actually succeeded.
// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)

    /// Which ONNX Runtime execution provider a session actually ran on. On
    /// desktop GPU builds (`ai.onnx_gpu`) `OrtModelSession` tries the platform
    /// GPU provider first and falls back to CPU; on Apple a backend may opt into
    /// `.coreml` per session. This records the outcome so `ai.vision.info` can
    /// surface it (see `MobileSAMBackend`). Android's NNAPI/XNNPACK choice isn't
    /// modeled here.
    public enum OrtExecutionProvider: String {
        case cpu, cuda, directml, coreml
    }

    /// Opt-in CoreML execution-provider configuration for a session (Apple only;
    /// ignored elsewhere). CoreML is **not** a free win: the EP partitions the
    /// graph and hands everything it can't take back to the CPU EP, it compiles
    /// its partitions at `CreateSession` (seconds, on every launch, unless
    /// `modelCacheDirectory` is set), and per-`Run` handoff costs are paid on
    /// every call — so a graph invoked hundreds of times in an autoregressive
    /// loop can come out *slower* than plain CPU. Measure before enabling; see
    /// `docs/on-device-ai-performance.md`.
    public struct OrtCoreMLOptions: Sendable, Equatable {
        /// Which hardware CoreML may schedule onto (`MLComputeUnits`).
        ///
        /// > The values here are the ones ONNX Runtime's CoreML EP actually
        /// > accepts (`CPUAndNeuralEngine` / `CPUAndGPU` / `CPUOnly`), *not* the
        /// > `MLComputeUnitsAll`-style spellings the vendored
        /// > `coreml_provider_factory.h` comment documents — those are rejected
        /// > at session creation with "Invalid value for option
        /// > `MLComputeUnits`", which (absent a check) reads as a silent CPU
        /// > fallback. "All" isn't a settable name at all: it's what you get by
        /// > omitting the option, which is what `.all` does.
        public enum ComputeUnits: Sendable {
            /// CPU + GPU + Neural Engine — CoreML's own default.
            case all
            case cpuAndGPU
            case cpuAndNeuralEngine
            /// Reference path — useful to isolate a precision difference from a
            /// scheduling one, not for speed.
            case cpuOnly

            /// The provider-option value, or `nil` to leave the option unset.
            var optionValue: String? {
                switch self {
                case .all: nil
                case .cpuAndGPU: "CPUAndGPU"
                case .cpuAndNeuralEngine: "CPUAndNeuralEngine"
                case .cpuOnly: "CPUOnly"
                }
            }
        }

        /// Which CoreML model format the EP compiles its partitions into.
        /// `MLProgram` is the modern one (Core ML 5+) and the default here.
        ///
        /// > Neither is a safe bet for a graph with dynamic shapes: measured
        /// > against the Qwen3-TTS talker, `MLProgram` fails at session creation
        /// > and `NeuralNetwork` loads but fails on the first `Run` (a
        /// > zero-element KV cache). See `docs/on-device-ai-performance.md`.
        public enum ModelFormat: String, Sendable {
            case mlProgram = "MLProgram"
            case neuralNetwork = "NeuralNetwork"
        }

        public var computeUnits: ComputeUnits
        public var modelFormat: ModelFormat
        /// Refuse nodes whose inputs have dynamic shapes. A decoder KV cache is
        /// dynamic by construction, so leaving this `false` lets CoreML take
        /// those nodes — which is often *worse*, because it reshapes and
        /// recompiles as the sequence grows.
        public var requireStaticInputShapes: Bool
        /// Where CoreML caches the models it compiles from ONNX subgraphs.
        /// Unset ⇒ a temp directory discarded when the session closes, i.e. the
        /// compile cost is paid again on every launch.
        public var modelCacheDirectory: String?

        public init(
            computeUnits: ComputeUnits = .all,
            modelFormat: ModelFormat = .mlProgram,
            requireStaticInputShapes: Bool = false,
            modelCacheDirectory: String? = nil
        ) {
            self.computeUnits = computeUnits
            self.modelFormat = modelFormat
            self.requireStaticInputShapes = requireStaticInputShapes
            self.modelCacheDirectory = modelCacheDirectory
        }
    }

    /// ONNX Runtime graph-optimization level for a session. The default,
    /// `.all`, matches ONNX Runtime's own default (all fusions). Lower it to
    /// `.basic` to skip the **extended** fusions — the ones that rewrite
    /// standard ops into `com.microsoft.*` contrib ops (e.g. an Erf-gelu
    /// pattern → `com.microsoft.Gelu`). That matters on the **Android** ONNX
    /// Runtime package, whose contrib-op kernels don't cover **float16**: a
    /// fused fp16 `com.microsoft.Gelu` has no kernel there and the session
    /// fails to run, while the un-fused standard ops do run. Apple/desktop
    /// packages carry the fp16 contrib kernels, so they keep `.all`.
    public enum OrtGraphOptimizationLevel: Sendable {
        case disableAll, basic, extended, all

        fileprivate var ortValue: GraphOptimizationLevel {
            switch self {
            case .disableAll: ORT_DISABLE_ALL
            case .basic: ORT_ENABLE_BASIC
            case .extended: ORT_ENABLE_EXTENDED
            case .all: ORT_ENABLE_ALL
            }
        }
    }

    /// Log-once sink for the "accelerated EP unavailable → CPU fallback" notice,
    /// so a machine without a usable GPU (or CoreML) doesn't print the line for
    /// every model (encoder + two decoders) on every session. Keyed by provider
    /// name, so a CoreML notice doesn't suppress a later CUDA one.
    enum OrtProviderFallback {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var logged: Set<String> = []

        static func note(_ provider: String, _ error: any Error) {
            lock.lock()
            defer { lock.unlock() }
            guard logged.insert(provider).inserted else { return }
            FileHandle.standardError.writeQuietly(Data(
                "[swift-pwa] ONNX Runtime \(provider) execution provider unavailable — running on CPU (\(error))\n"
                    .utf8
            ))
        }
    }

    /// A loaded ONNX model, runnable against named tensors. Inputs may be
    /// float32, **float16** (fp16 exports), or **int32 / int64** (a
    /// Stable-Diffusion text encoder's `input_ids`) — see `OrtInput`; outputs
    /// are returned as float32 (`Tensor`), fp16 outputs converted up. Kept
    /// deliberately narrow (no arbitrary element types) — this is what the
    /// ONNX-Runtime-tier backends actually need.
    public final class OrtModelSession: @unchecked Sendable {
        private let runtime: OrtRuntime
        private let session: OpaquePointer
        private let cpuMemoryInfo: OpaquePointer
        /// The execution provider this session actually loaded on — the GPU
        /// provider on an `ai.onnx_gpu` build where the GPU EP initialized,
        /// `.cpu` otherwise (including a transparent fallback).
        public let provider: OrtExecutionProvider

        /// A stable non-null pointer handed to ORT for zero-element input
        /// tensors (empty KV caches), which it never dereferences. Allocated
        /// once for the process; the 1-byte leak is intentional.
        private nonisolated(unsafe) static let zeroSizeScratch = UnsafeRawPointer(
            UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        )

        /// Loads `path` under `runtime`'s shared environment. Throws
        /// `OrtError.apiUnavailable` if `runtime` itself failed to initialize
        /// (no usable ONNX Runtime linked), or `.failed` if the model fails to
        /// load (bad path, corrupt/incompatible graph).
        ///
        /// On a desktop GPU build (`SWIFT_PWA_ONNXRUNTIME_GPU`) the platform GPU
        /// execution provider (DirectML on Windows, CUDA on Linux) is appended
        /// before the default CPU EP; on Apple, passing `coreML` appends the
        /// CoreML EP the same way. If the provider can't be appended or the
        /// session fails to create with it — no capable GPU, no driver, (Linux)
        /// no CUDA/cuDNN runtime, or a graph CoreML rejects outright — we log
        /// once and retry on CPU. Inference is never broken by the absence of a
        /// usable accelerator.
        public init(
            modelPath: String,
            runtime: OrtRuntime,
            graphOptimizationLevel: OrtGraphOptimizationLevel = .all,
            coreML: OrtCoreMLOptions? = nil
        ) throws {
            self.runtime = runtime
            let api = runtime.api

            var made: (session: OpaquePointer, provider: OrtExecutionProvider)?
            #if SWIFT_PWA_ONNXRUNTIME_GPU
                do {
                    made = try Self.createSession(
                        modelPath: modelPath, runtime: runtime, gpu: true, coreML: nil,
                        optimization: graphOptimizationLevel
                    )
                } catch {
                    OrtProviderFallback.note("GPU", error)
                }
            #endif
            if made == nil, let coreML {
                do {
                    made = try Self.createSession(
                        modelPath: modelPath, runtime: runtime, gpu: false, coreML: coreML,
                        optimization: graphOptimizationLevel
                    )
                } catch {
                    OrtProviderFallback.note("CoreML", error)
                }
            }
            if made == nil {
                made = try Self.createSession(
                    modelPath: modelPath, runtime: runtime, gpu: false, coreML: nil,
                    optimization: graphOptimizationLevel
                )
            }
            guard let made else { throw OrtError.failed("CreateSession returned no session") }
            session = made.session
            provider = made.provider

            var memInfo: OpaquePointer?
            try runtime.check(api.pointee.CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &memInfo))
            guard let memInfo else { throw OrtError.failed("CreateCpuMemoryInfo returned no info") }
            cpuMemoryInfo = memInfo
        }

        /// Create the ONNX Runtime session, optionally appending the platform
        /// GPU execution provider first. Returns the session plus the provider
        /// that was configured (`.cpu` when `gpu` is false or no GPU EP is
        /// compiled in). Throws if session options / the GPU EP / `CreateSession`
        /// fail — the GPU attempt's throw is what drives the CPU fallback above.
        private static func createSession(
            modelPath: String, runtime: OrtRuntime, gpu: Bool, coreML: OrtCoreMLOptions?,
            optimization: OrtGraphOptimizationLevel
        ) throws -> (OpaquePointer, OrtExecutionProvider) {
            let api = runtime.api

            var options: OpaquePointer?
            try runtime.check(api.pointee.CreateSessionOptions(&options))
            guard let options else { throw OrtError.failed("CreateSessionOptions returned no options") }
            defer { api.pointee.ReleaseSessionOptions(options) }

            try runtime.check(api.pointee.SetSessionGraphOptimizationLevel(options, optimization.ortValue))

            var provider: OrtExecutionProvider = .cpu
            #if SWIFT_PWA_ONNXRUNTIME_GPU
                if gpu { provider = try appendGpuProvider(options: options, runtime: runtime) }
            #endif
            #if canImport(ONNXRuntime) && (os(macOS) || os(iOS))
                if let coreML {
                    try appendCoreMLProvider(coreML, options: options, runtime: runtime)
                    provider = .coreml
                }
            #endif

            var sessionPtr: OpaquePointer?
            // ONNX Runtime's model-path argument is `ORTCHAR_T*` — `wchar_t`
            // (UTF-16) on Windows, `char` (UTF-8) elsewhere. So the C API
            // imports `CreateSession` as taking `UnsafePointer<UInt16>` on
            // Windows and `UnsafePointer<CChar>` on Linux/Apple; hand it the
            // matching encoding. (Only this call takes a path; input/output
            // tensor names are plain `char*` on every platform.)
            #if os(Windows)
                try modelPath.withCString(encodedAs: UTF16.self) { widePath in
                    try runtime.check(api.pointee.CreateSession(runtime.env, widePath, options, &sessionPtr))
                }
            #else
                try modelPath.withCString { cPath in
                    try runtime.check(api.pointee.CreateSession(runtime.env, cPath, options, &sessionPtr))
                }
            #endif
            guard let sessionPtr else { throw OrtError.failed("CreateSession returned no session") }
            return (sessionPtr, provider)
        }

        #if canImport(ONNXRuntime) && (os(macOS) || os(iOS))
            /// Append the CoreML execution provider to `options`. Uses ONNX
            /// Runtime's string-keyed provider-options API rather than the older
            /// `OrtSessionOptionsAppendExecutionProvider_CoreML` bit flags — the
            /// flags enum can't express `MLComputeUnits` or a model cache
            /// directory, and the header marks it as superseded.
            private static func appendCoreMLProvider(
                _ coreML: OrtCoreMLOptions, options: OpaquePointer, runtime: OrtRuntime
            ) throws {
                var pairs: [(String, String)] = [
                    (String(cString: kCoremlProviderOption_ModelFormat), coreML.modelFormat.rawValue),
                    (
                        String(cString: kCoremlProviderOption_RequireStaticInputShapes),
                        coreML.requireStaticInputShapes ? "1" : "0"
                    )
                ]
                if let units = coreML.computeUnits.optionValue {
                    pairs.append((String(cString: kCoremlProviderOption_MLComputeUnits), units))
                }
                if let dir = coreML.modelCacheDirectory {
                    // CoreML only writes here if the directory exists.
                    try? FileManager.default.createDirectory(
                        atPath: dir, withIntermediateDirectories: true
                    )
                    pairs.append((String(cString: kCoremlProviderOption_ModelCacheDirectory), dir))
                }

                // ORT copies the strings out of these arrays, so freeing them
                // right after the call is safe.
                let keyBuffers = pairs.map { strdup($0.0) }
                let valueBuffers = pairs.map { strdup($0.1) }
                defer { (keyBuffers + valueBuffers).forEach { free($0) } }
                let keys = keyBuffers.map { UnsafePointer($0) }
                let values = valueBuffers.map { UnsafePointer($0) }

                try keys.withUnsafeBufferPointer { k in
                    try values.withUnsafeBufferPointer { v in
                        try runtime.check(runtime.api.pointee.SessionOptionsAppendExecutionProvider(
                            options, "CoreML", k.baseAddress, v.baseAddress, pairs.count
                        ))
                    }
                }
            }
        #endif

        #if SWIFT_PWA_ONNXRUNTIME_GPU
            /// Append the platform GPU execution provider to `options`, returning
            /// which one. Compiled only on a GPU build — the append symbols
            /// (`OrtSessionOptionsAppendExecutionProvider_{CUDA,DML}`) exist only
            /// in the GPU-enabled ONNX Runtime we link there.
            private static func appendGpuProvider(
                options: OpaquePointer, runtime: OrtRuntime
            ) throws -> OrtExecutionProvider {
                let api = runtime.api
                #if os(Windows)
                    // DirectML requires sequential execution and no memory-pattern
                    // optimization (ONNX Runtime's documented DML constraint).
                    try runtime.check(api.pointee.DisableMemPattern(options))
                    try runtime.check(api.pointee.SetSessionExecutionMode(options, ORT_SEQUENTIAL))
                    try runtime.check(OrtSessionOptionsAppendExecutionProvider_DML(options, 0))
                    return .directml
                #elseif os(Linux)
                    try runtime.check(OrtSessionOptionsAppendExecutionProvider_CUDA(options, 0))
                    return .cuda
                #else
                    return .cpu
                #endif
            }
        #endif

        deinit {
            runtime.api.pointee.ReleaseMemoryInfo(cpuMemoryInfo)
            runtime.api.pointee.ReleaseSession(session)
        }

        /// One named float32 input/output tensor: its flat row-major values plus
        /// shape (e.g. `[1, 3, 1024, 1024]` for an NCHW image). Outputs are
        /// always read back as float32; float inputs use this, non-float inputs
        /// use `OrtInput` (see `run`).
        public struct Tensor: Sendable {
            public var values: [Float]
            public var shape: [Int64]

            public init(values: [Float], shape: [Int64]) {
                self.values = values
                self.shape = shape
            }
        }

        /// A typed graph **input**. Most graphs (SAM, LaMa) are float32-only and
        /// use `.float`, but exports vary: a Stable-Diffusion text encoder wants
        /// `input_ids` as **int32** or **int64**, and an **fp16** export (e.g.
        /// the ONNX Runtime team's SD-Turbo) takes half-precision float tensors.
        /// Each case carries its flat row-major values plus shape.
        ///
        /// `.float16` carries `[Float]` (float32) for a uniform caller API — the
        /// values are converted to IEEE half at tensor creation, and fp16
        /// outputs are read back and converted to `[Float]` (see `readTensor`),
        /// so the rest of a pipeline stays in float32 regardless of the model's
        /// precision.
        public enum OrtInput: Sendable {
            case float([Float], shape: [Int64])
            case float16([Float], shape: [Int64])
            case int32([Int32], shape: [Int64])
            case int64([Int64], shape: [Int64])

            public var shape: [Int64] {
                switch self {
                case let .float(_, shape), let .float16(_, shape),
                     let .int32(_, shape), let .int64(_, shape): shape
                }
            }
        }

        /// Runs the model with float32 inputs — the common case (SAM, LaMa).
        /// A thin wrapper over the typed `run` below.
        public func run(inputs: [String: Tensor], outputNames: [String]) throws -> [String: Tensor] {
            try run(
                inputs: inputs.mapValues { OrtInput.float($0.values, shape: $0.shape) },
                outputNames: outputNames
            )
        }

        /// Runs the model with typed inputs (float32 / int32 / int64), for
        /// graphs that declare integer inputs — a Stable-Diffusion text encoder
        /// (`input_ids` int32) / UNet (`timestep` int64). `inputs` and
        /// `outputNames` must match the graph's declared names exactly (ONNX
        /// Runtime doesn't validate name typos beyond "not found"). Returns one
        /// float32 `Tensor` per requested output name, each carrying the shape
        /// ONNX Runtime reports for it.
        public func run(inputs: [String: OrtInput], outputNames: [String]) throws -> [String: Tensor] {
            let api = runtime.api

            // Build input OrtValues. Each wraps the input array's own storage
            // directly (CreateTensorWithDataAsOrtValue doesn't copy) — the
            // arrays must outlive the call, which `withExtendedLifetime(inputs)`
            // below guarantees through `Run`. ORT treats input data as
            // read-only, so an immutable buffer pointer (cast to a mutable raw
            // pointer for the C signature) is safe and avoids a COW mutation.
            var inputValues: [OpaquePointer?] = []
            var inputNamesOwned: [UnsafeMutablePointer<CChar>?] = []
            // `.float16` inputs are converted float32→half into fresh buffers
            // that ORT's tensor points into; they must outlive `Run`, so they're
            // held here (kept alive by `withExtendedLifetime` below). Inner
            // `[Float16]` storage is stable across appends to the outer array.
            var float16Scratch: [[Float16]] = []
            defer {
                for value in inputValues { if let value { api.pointee.ReleaseValue(value) } }
                for name in inputNamesOwned { if let name { free(name) } }
            }

            for (name, input) in inputs {
                var value: OpaquePointer?
                try input.shape.withUnsafeBufferPointer { shapePtr in
                    func makeTensor(
                        _ base: UnsafeRawPointer?, byteCount: Int, type: ONNXTensorElementDataType
                    ) throws {
                        // A zero-element input (a shape with a 0 dim — e.g. an
                        // empty KV cache on an autoregressive model's first
                        // step) has a nil `baseAddress`. ORT still wants a
                        // non-null data pointer, but never dereferences it when
                        // the byte count is 0, so a stable dummy is safe.
                        let dataPtr = base ?? (byteCount == 0 ? Self.zeroSizeScratch : nil)
                        guard let dataPtr else { throw OrtError.failed("empty input tensor \"\(name)\"") }
                        try runtime.check(api.pointee.CreateTensorWithDataAsOrtValue(
                            cpuMemoryInfo,
                            UnsafeMutableRawPointer(mutating: dataPtr),
                            byteCount,
                            shapePtr.baseAddress,
                            shapePtr.count,
                            type,
                            &value
                        ))
                    }
                    switch input {
                    case let .float(values, _):
                        try values.withUnsafeBufferPointer {
                            try makeTensor(
                                $0.baseAddress, byteCount: $0.count * MemoryLayout<Float>.size,
                                type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
                            )
                        }
                    case let .float16(values, _):
                        float16Scratch.append(values.map { Float16($0) })
                        try float16Scratch[float16Scratch.count - 1].withUnsafeBufferPointer {
                            try makeTensor(
                                $0.baseAddress, byteCount: $0.count * MemoryLayout<Float16>.size,
                                type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16
                            )
                        }
                    case let .int32(values, _):
                        try values.withUnsafeBufferPointer {
                            try makeTensor(
                                $0.baseAddress, byteCount: $0.count * MemoryLayout<Int32>.size,
                                type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32
                            )
                        }
                    case let .int64(values, _):
                        try values.withUnsafeBufferPointer {
                            try makeTensor(
                                $0.baseAddress, byteCount: $0.count * MemoryLayout<Int64>.size,
                                type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
                            )
                        }
                    }
                }
                guard let value else { throw OrtError.failed("CreateTensorWithDataAsOrtValue returned no value") }
                inputValues.append(value)
                inputNamesOwned.append(strdup(name))
            }
            let inputNamesC: [UnsafePointer<CChar>?] = inputNamesOwned.map { $0.map { UnsafePointer($0) } }

            let outputNamesOwned = outputNames.map { strdup($0) as UnsafeMutablePointer<CChar>? }
            defer { for name in outputNamesOwned { if let name { free(name) } } }
            let outputNamesC: [UnsafePointer<CChar>?] = outputNamesOwned.map { $0.map { UnsafePointer($0) } }
            var outputValues = [OpaquePointer?](repeating: nil, count: outputNames.count)
            defer {
                for value in outputValues { if let value { api.pointee.ReleaseValue(value) } }
            }

            try withExtendedLifetime((inputs, float16Scratch)) {
                try inputNamesC.withUnsafeBufferPointer { inNames in
                    try inputValues.withUnsafeBufferPointer { inValues in
                        try outputNamesC.withUnsafeBufferPointer { outNames in
                            try outputValues.withUnsafeMutableBufferPointer { outValues in
                                try runtime.check(api.pointee.Run(
                                    session, nil,
                                    inNames.baseAddress, inValues.baseAddress, inValues.count,
                                    outNames.baseAddress, outNames.count,
                                    outValues.baseAddress
                                ))
                            }
                        }
                    }
                }
            }

            var results: [String: Tensor] = [:]
            for (name, value) in zip(outputNames, outputValues) {
                guard let value else { throw OrtError.failed("Run produced no value for output \"\(name)\"") }
                results[name] = try readTensor(value)
            }
            return results
        }

        private func readTensor(_ value: OpaquePointer) throws -> Tensor {
            let api = runtime.api

            var typeAndShape: OpaquePointer?
            try runtime.check(api.pointee.GetTensorTypeAndShape(value, &typeAndShape))
            guard let typeAndShape else { throw OrtError.failed("GetTensorTypeAndShape returned nothing") }
            defer { api.pointee.ReleaseTensorTypeAndShapeInfo(typeAndShape) }

            // Outputs are returned as float32 in `Tensor.values`. float32 is
            // read directly; **float16** (fp16 exports) is read as half and
            // converted up — so a pipeline stays in float32 regardless of the
            // model's precision. Any other element type errors loudly rather
            // than silently misreading bytes.
            var elementType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            try runtime.check(api.pointee.GetTensorElementType(typeAndShape, &elementType))

            var dimCount = 0
            try runtime.check(api.pointee.GetDimensionsCount(typeAndShape, &dimCount))
            var shape = [Int64](repeating: 0, count: dimCount)
            try shape.withUnsafeMutableBufferPointer { buffer in
                try runtime.check(api.pointee.GetDimensions(typeAndShape, buffer.baseAddress, dimCount))
            }

            var elementCount = 0
            try runtime.check(api.pointee.GetTensorShapeElementCount(typeAndShape, &elementCount))

            var dataPtr: UnsafeMutableRawPointer?
            try runtime.check(api.pointee.GetTensorMutableData(value, &dataPtr))
            guard let dataPtr else { throw OrtError.failed("GetTensorMutableData returned no pointer") }

            let values: [Float]
            switch elementType {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
                values = Array(UnsafeBufferPointer(
                    start: dataPtr.assumingMemoryBound(to: Float.self),
                    count: elementCount
                ))
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16:
                let halfs = UnsafeBufferPointer(
                    start: dataPtr.assumingMemoryBound(to: Float16.self),
                    count: elementCount
                )
                values = halfs.map { Float($0) }
            default:
                throw OrtError
                    .failed("output tensor is not float32/float16 (ONNX element type \(elementType.rawValue))")
            }
            return Tensor(values: values, shape: shape)
        }
    }
#endif
