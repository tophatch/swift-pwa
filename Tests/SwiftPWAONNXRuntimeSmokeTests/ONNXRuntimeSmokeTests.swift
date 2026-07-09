import SwiftPWAONNXRuntimeSmoke
import Testing

@Suite("ONNXRuntimeSmoke (packaging spike)")
struct ONNXRuntimeSmokeTests {
    @Test("the vendored xcframework links and its C API is callable")
    func linksAndCallable() {
        #expect(ONNXRuntimeSmoke.linked() == true)
        #expect(ONNXRuntimeSmoke.versionString() == "1.27.0")
    }
}
