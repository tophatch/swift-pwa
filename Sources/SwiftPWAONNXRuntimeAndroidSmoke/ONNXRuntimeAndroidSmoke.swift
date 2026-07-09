#if canImport(ONNXRuntimeAndroid)
    import ONNXRuntimeAndroid

    /// Spike-only smoke test for the ONNX Runtime **Android** linking story
    /// (see `docs/proposals/segmentation-plugin.md`). Proves the vendored
    /// `libonnxruntime.so` (from `Scripts/vendor-onnxruntime-android.sh`)
    /// actually links via `.systemLibrary` + `LIBRARY_PATH` and its C API is
    /// callable from Swift — nothing more. The Apple counterpart is
    /// `SwiftPWAONNXRuntimeSmoke`; not part of any shipped plugin, deleted
    /// or promoted once a real `SwiftPWASegmentation` backend lands.
    public enum ONNXRuntimeAndroidSmoke {
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
    public enum ONNXRuntimeAndroidSmoke {
        public static func linked() -> Bool { false }
        public static func versionString() -> String? { nil }
    }
#endif
