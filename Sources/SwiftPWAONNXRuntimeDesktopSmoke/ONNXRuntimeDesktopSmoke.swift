#if canImport(ONNXRuntimeDesktop)
    import ONNXRuntimeDesktop

    /// Smoke test for the ONNX Runtime **desktop** (Linux x86_64 / Windows x64)
    /// linking story (see `docs/proposals/segmentation-plugin.md`). Proves the
    /// vendored `libonnxruntime.so` / `onnxruntime.dll`+`.lib` (from
    /// `Scripts/vendor-onnxruntime-{linux,windows}.sh`) links via
    /// `.systemLibrary` + `LIBRARY_PATH`/`LIB` and its C API is callable from
    /// Swift. The Apple/Android counterparts are `SwiftPWAONNXRuntimeSmoke` /
    /// `SwiftPWAONNXRuntimeAndroidSmoke`.
    public enum ONNXRuntimeDesktopSmoke {
        /// `true` if `OrtGetApiBase()` returns a non-null API table.
        public static func linked() -> Bool {
            OrtGetApiBase() != nil
        }

        /// The API table's declared version (`OrtApiBase.GetVersionString`),
        /// e.g. `"1.27.0"`.
        public static func versionString() -> String? {
            guard let base = OrtGetApiBase(), let getVersion = base.pointee.GetVersionString,
                  let version = getVersion()
            else { return nil }
            return String(cString: version)
        }
    }
#else
    public enum ONNXRuntimeDesktopSmoke {
        public static func linked() -> Bool { false }
        public static func versionString() -> String? { nil }
    }
#endif
