#if canImport(ONNXRuntime)
    import ONNXRuntime

    /// Spike-only smoke test for the ONNX Runtime Apple xcframework linking
    /// story (see `docs/proposals/segmentation-plugin.md`). Proves the
    /// vendored/checksummed `.binaryTarget` actually links and its C API is
    /// callable from Swift — nothing more. Not part of any shipped plugin;
    /// deleted or promoted once a real `SwiftPWASegmentation` backend lands.
    public enum ONNXRuntimeSmoke {
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
    public enum ONNXRuntimeSmoke {
        public static func linked() -> Bool { false }
        public static func versionString() -> String? { nil }
    }
#endif
