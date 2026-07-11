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
import SwiftPWACore // FileHandle.writeQuietly (log-once GPU fallback)

// See the matching comment in OrtRuntime.swift — this type references ONNX
// Runtime C API types unconditionally, so the whole body is gated to
// destinations where one of the ONNX Runtime imports above actually succeeded.
// swiftformat:disable:next wrap wrapArguments
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop) || canImport(ONNXRuntimeDirectML)

    /// Which ONNX Runtime execution provider a session actually ran on. On
    /// desktop GPU builds (`ai.onnx_gpu`) `OrtModelSession` tries the platform
    /// GPU provider first and falls back to CPU; this records the outcome so
    /// `ai.vision.info` can surface it (see `MobileSAMBackend`). On Apple /
    /// Android / desktop-CPU builds it is always `.cpu` — the OS-level EP choice
    /// (CoreML/NNAPI) isn't modeled here.
    public enum OrtExecutionProvider: String {
        case cpu, cuda, directml
    }

    /// Log-once sink for the "GPU EP unavailable → CPU fallback" notice, so a
    /// machine without a usable GPU doesn't print the line for every model
    /// (encoder + two decoders) on every session.
    enum OrtGpuFallback {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var logged = false

        static func note(_ error: any Error) {
            lock.lock()
            defer { lock.unlock() }
            guard !logged else { return }
            logged = true
            FileHandle.standardError.writeQuietly(Data(
                "[swift-pwa] ONNX Runtime GPU execution provider unavailable — running on CPU (\(error))\n".utf8
            ))
        }
    }

    /// A loaded ONNX model, runnable against named float32 tensors. Deliberately
    /// narrow — SAM's encoder/decoder graphs (and the other ONNX-Runtime-tier
    /// backends the 0.8 evaluation anticipates) only need float32 in/out; a
    /// backend that needs another element type extends this, not the contract.
    public final class OrtModelSession: @unchecked Sendable {
        private let runtime: OrtRuntime
        private let session: OpaquePointer
        private let cpuMemoryInfo: OpaquePointer
        /// The execution provider this session actually loaded on — the GPU
        /// provider on an `ai.onnx_gpu` build where the GPU EP initialized,
        /// `.cpu` otherwise (including a transparent fallback).
        public let provider: OrtExecutionProvider

        /// Loads `path` under `runtime`'s shared environment. Throws
        /// `OrtError.apiUnavailable` if `runtime` itself failed to initialize
        /// (no usable ONNX Runtime linked), or `.failed` if the model fails to
        /// load (bad path, corrupt/incompatible graph).
        ///
        /// On a desktop GPU build (`SWIFT_PWA_ONNXRUNTIME_GPU`) the platform GPU
        /// execution provider (DirectML on Windows, CUDA on Linux) is appended
        /// before the default CPU EP. If it can't be appended or the session
        /// fails to create with it — no capable GPU, no driver, or (Linux) no
        /// CUDA/cuDNN runtime present — we log once and retry on CPU. Inference
        /// is never broken by the absence of a usable GPU.
        public init(modelPath: String, runtime: OrtRuntime) throws {
            self.runtime = runtime
            let api = runtime.api

            var made: (session: OpaquePointer, provider: OrtExecutionProvider)?
            #if SWIFT_PWA_ONNXRUNTIME_GPU
                do {
                    made = try Self.createSession(modelPath: modelPath, runtime: runtime, gpu: true)
                } catch {
                    OrtGpuFallback.note(error)
                }
            #endif
            if made == nil {
                made = try Self.createSession(modelPath: modelPath, runtime: runtime, gpu: false)
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
            modelPath: String, runtime: OrtRuntime, gpu: Bool
        ) throws -> (OpaquePointer, OrtExecutionProvider) {
            let api = runtime.api

            var options: OpaquePointer?
            try runtime.check(api.pointee.CreateSessionOptions(&options))
            guard let options else { throw OrtError.failed("CreateSessionOptions returned no options") }
            defer { api.pointee.ReleaseSessionOptions(options) }

            var provider: OrtExecutionProvider = .cpu
            #if SWIFT_PWA_ONNXRUNTIME_GPU
                if gpu { provider = try appendGpuProvider(options: options, runtime: runtime) }
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
        public struct Tensor {
            public var values: [Float]
            public var shape: [Int64]

            public init(values: [Float], shape: [Int64]) {
                self.values = values
                self.shape = shape
            }
        }

        /// A typed graph **input**. Most graphs (SAM, LaMa) are float32-only and
        /// use `.float`, but some declare integer inputs — a Stable-Diffusion
        /// text encoder wants `input_ids` as **int32** and the UNet `timestep`
        /// as **int64**. Each case carries its flat row-major values plus shape.
        /// (Outputs stay float32 — the SD graphs' embedding / noise / image
        /// outputs all are — so there is no integer output variant.)
        public enum OrtInput {
            case float([Float], shape: [Int64])
            case int32([Int32], shape: [Int64])
            case int64([Int64], shape: [Int64])

            public var shape: [Int64] {
                switch self {
                case let .float(_, shape), let .int32(_, shape), let .int64(_, shape): shape
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
                        guard let base else { throw OrtError.failed("empty input tensor \"\(name)\"") }
                        try runtime.check(api.pointee.CreateTensorWithDataAsOrtValue(
                            cpuMemoryInfo,
                            UnsafeMutableRawPointer(mutating: base),
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

            try withExtendedLifetime(inputs) {
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

            // Outputs are read back as float32 (the `values: [Float]` buffer is
            // reinterpreted from raw bytes below). Guard the element type so a
            // non-float output errors loudly instead of silently misreading —
            // matters now that integer inputs are supported.
            var elementType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            try runtime.check(api.pointee.GetTensorElementType(typeAndShape, &elementType))
            guard elementType == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT else {
                throw OrtError.failed("output tensor is not float32 (ONNX element type \(elementType.rawValue))")
            }

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

            let typed = dataPtr.assumingMemoryBound(to: Float.self)
            let values = Array(UnsafeBufferPointer(start: typed, count: elementCount))
            return Tensor(values: values, shape: shape)
        }
    }
#endif
