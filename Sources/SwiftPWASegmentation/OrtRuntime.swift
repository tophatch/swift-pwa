#if canImport(ONNXRuntime)
    import ONNXRuntime
#elseif canImport(ONNXRuntimeAndroid)
    import ONNXRuntimeAndroid
#endif
import Foundation

/// Thin, minimal Swift wrapper over the ONNX Runtime C API — the shared
/// "ONNX Runtime backend tier" investment the 0.8 maintainer evaluation
/// calls out (reusable later for `gemma-onnx` / `stable-diffusion-onnx`,
/// not just segmentation). Deliberately narrow: only the primitives a
/// two-graph (encoder/decoder) SAM-style backend needs — load a model,
/// run it against named float32 tensors, read results back. Not a
/// general-purpose binding.
public enum OrtError: Error, CustomStringConvertible, Equatable {
    /// `OrtGetApiBase()`/`GetApi` returned nothing usable — no ONNX Runtime
    /// linked in, or a version mismatch against `ORT_API_VERSION`.
    case apiUnavailable
    /// An ONNX Runtime call returned a non-null `OrtStatus`; the message is
    /// `GetErrorMessage`'s text.
    case failed(String)

    public var description: String {
        switch self {
        case .apiUnavailable: "ONNX Runtime C API unavailable"
        case let .failed(message): message
        }
    }
}

/// Process-wide ONNX Runtime handle: the function table plus one shared
/// `OrtEnv`. ONNX Runtime documents `CreateEnv` as returning the same
/// environment instance on every call (arguments after the first are
/// ignored on repeat calls), so this is created once, lazily, and reused —
/// `OrtSession` is the per-model unit, not `OrtEnv`. `@unchecked Sendable`:
/// the wrapped `api`/`env` pointers are set once at init and never mutated
/// afterward, and ONNX Runtime documents `OrtEnv` + running sessions as
/// thread-safe for concurrent use.
final class OrtRuntime: @unchecked Sendable {
    /// `nil` when no usable ONNX Runtime is linked (e.g. the
    /// `SWIFT_PWA_ONNXRUNTIME` gate is off, or on a platform/host with no
    /// linked artifact). Callers translate that into `.unavailable` at the
    /// `SegmentationBackend` boundary — this type doesn't know about
    /// `VisionError`.
    static let shared: OrtRuntime? = OrtRuntime()

    let api: UnsafePointer<OrtApi>
    let env: OpaquePointer

    private init?() {
        #if canImport(ONNXRuntime) || canImport(ONNXRuntimeAndroid)
            guard let base = OrtGetApiBase(), let getApi = base.pointee.GetApi,
                  let apiPtr = getApi(UInt32(ORT_API_VERSION))
            else { return nil }
            api = apiPtr

            var envPtr: OpaquePointer?
            let status = "swift-pwa".withCString { logID in
                apiPtr.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, logID, &envPtr)
            }
            guard status == nil, let envPtr else { return nil }
            env = envPtr
        #else
            return nil
        #endif
    }

    /// Convert a non-null `OrtStatus*` into a thrown `OrtError`, releasing
    /// it either way — every ONNX Runtime call that can fail returns a
    /// status the caller must release regardless of outcome.
    func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        defer { api.pointee.ReleaseStatus(status) }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) }
        throw OrtError.failed(message ?? "unknown ONNX Runtime error")
    }
}
