import Foundation
@testable import SwiftPWASegmentation
import Testing

@Suite("OrtModelSession (packaging + plumbing proof, no real model)")
struct OrtModelSessionTests {
    /// `add_one.onnx`: `y = x + 1` over a float32[3] input — deliberately
    /// tiny. Exists to prove the ONNX Runtime Swift wrapper's plumbing
    /// (session create, tensor in, `Run`, tensor out) end-to-end, not to
    /// resemble MobileSAM's real graph shape.
    private func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "add_one", withExtension: "onnx", subdirectory: "Fixtures"))
    }

    @Test("the runtime links and reports a usable env")
    func runtimeAvailable() {
        #expect(OrtRuntime.shared != nil)
    }

    @Test("running add_one.onnx returns x + 1")
    func runsSyntheticGraph() throws {
        let runtime = try #require(OrtRuntime.shared)
        let session = try OrtModelSession(modelPath: fixtureURL().path, runtime: runtime)

        let input = OrtModelSession.Tensor(values: [1, 2, 3], shape: [3])
        let outputs = try session.run(inputs: ["x": input], outputNames: ["y"])

        let y = try #require(outputs["y"])
        #expect(y.values == [2, 3, 4])
        #expect(y.shape == [3])
    }

    @Test("an unknown output name fails with a stable error, not a crash")
    func unknownOutputName() throws {
        let runtime = try #require(OrtRuntime.shared)
        let session = try OrtModelSession(modelPath: fixtureURL().path, runtime: runtime)
        let input = OrtModelSession.Tensor(values: [1, 2, 3], shape: [3])

        #expect(throws: OrtError.self) {
            _ = try session.run(inputs: ["x": input], outputNames: ["not_a_real_output"])
        }
    }

    @Test("loading a nonexistent model path fails with a stable error, not a crash")
    func missingModel() throws {
        let runtime = try #require(OrtRuntime.shared)
        #expect(throws: OrtError.self) {
            _ = try OrtModelSession(modelPath: "/nonexistent/path/model.onnx", runtime: runtime)
        }
    }
}
