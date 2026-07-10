#if canImport(ONNXRuntime)
    import ONNXRuntime
#elseif canImport(ONNXRuntimeAndroid)
    import ONNXRuntimeAndroid
#elseif canImport(ONNXRuntimeDesktop)
    import ONNXRuntimeDesktop
#endif
import Foundation

// See the matching comment in OrtRuntime.swift — this type references ONNX
// Runtime C API types unconditionally, so the whole body is gated to
// destinations where one of the three imports above actually succeeded.
#if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid) || canImport(ONNXRuntimeDesktop)

    /// A loaded ONNX model, runnable against named float32 tensors. Deliberately
    /// narrow — SAM's encoder/decoder graphs (and the other ONNX-Runtime-tier
    /// backends the 0.8 evaluation anticipates) only need float32 in/out; a
    /// backend that needs another element type extends this, not the contract.
    final class OrtModelSession: @unchecked Sendable {
        private let runtime: OrtRuntime
        private let session: OpaquePointer
        private let cpuMemoryInfo: OpaquePointer

        /// Loads `path` under `runtime`'s shared environment. Throws
        /// `OrtError.apiUnavailable` if `runtime` itself failed to initialize
        /// (no usable ONNX Runtime linked), or `.failed` if the model fails to
        /// load (bad path, corrupt/incompatible graph).
        init(modelPath: String, runtime: OrtRuntime) throws {
            self.runtime = runtime
            let api = runtime.api

            var options: OpaquePointer?
            try runtime.check(api.pointee.CreateSessionOptions(&options))
            guard let options else { throw OrtError.failed("CreateSessionOptions returned no options") }
            defer { api.pointee.ReleaseSessionOptions(options) }

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
            session = sessionPtr

            var memInfo: OpaquePointer?
            try runtime.check(api.pointee.CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &memInfo))
            guard let memInfo else { throw OrtError.failed("CreateCpuMemoryInfo returned no info") }
            cpuMemoryInfo = memInfo
        }

        deinit {
            runtime.api.pointee.ReleaseMemoryInfo(cpuMemoryInfo)
            runtime.api.pointee.ReleaseSession(session)
        }

        /// One named float32 input/output tensor: its flat row-major values plus
        /// shape (e.g. `[1, 3, 1024, 1024]` for an NCHW image).
        struct Tensor {
            var values: [Float]
            var shape: [Int64]

            init(values: [Float], shape: [Int64]) {
                self.values = values
                self.shape = shape
            }
        }

        /// Runs the model. `inputs` and `outputNames` must match the graph's
        /// declared names exactly (ONNX Runtime doesn't validate name typos
        /// beyond "not found"). Returns one `Tensor` per requested output name,
        /// each carrying the shape ONNX Runtime reports for it.
        func run(inputs: [String: Tensor], outputNames: [String]) throws -> [String: Tensor] {
            let api = runtime.api

            // Build input OrtValues. Each wraps `values`' own storage directly
            // (CreateTensorWithDataAsOrtValue doesn't copy) — the arrays must
            // outlive the call, which `withExtendedLifetime` below guarantees
            // through `Run`.
            var inputValues: [OpaquePointer?] = []
            var inputNamesOwned: [UnsafeMutablePointer<CChar>?] = []
            defer {
                for value in inputValues { if let value { api.pointee.ReleaseValue(value) } }
                for name in inputNamesOwned { if let name { free(name) } }
            }

            var mutableInputs = inputs
            for (name, tensor) in mutableInputs {
                var value: OpaquePointer?
                try mutableInputs[name]!.values.withUnsafeMutableBufferPointer { buffer in
                    try tensor.shape.withUnsafeBufferPointer { shapePtr in
                        try runtime.check(api.pointee.CreateTensorWithDataAsOrtValue(
                            cpuMemoryInfo,
                            buffer.baseAddress,
                            buffer.count * MemoryLayout<Float>.size,
                            shapePtr.baseAddress,
                            shapePtr.count,
                            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                            &value
                        ))
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

            try withExtendedLifetime(mutableInputs) {
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
